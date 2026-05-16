import Foundation

actor QueueEngine {
    let jobStore: JobStore
    let dispatcher: JobDispatcher
    var onJobReady: (@Sendable (RunnerJob) async -> Void)?
    var onJobCompleted: (@Sendable (RunnerJob, JobResult) async -> Void)?

    private let github: GitHubEngine
    private let client: any GitHubClientProtocol
    private let sessionStore: PollingSessionStore
    private let retryPolicy: QueuePollingRetryPolicy
    private var pollers: [String: ScaleSetPoller] = [:]
    private var sessions: [String: String] = [:]  // org name → sessionId
    private var pollingTasks: [String: Task<Void, Never>] = [:]
    private var pollingStates: [String: QueuePollingState] = [:]
    private var processedMessageIdsByOrg: [String: Set<Int64>] = [:]

    init(
        github: GitHubEngine,
        client: any GitHubClientProtocol,
        jobStore: JobStore = JobStore(),
        dispatcher: JobDispatcher = JobDispatcher(),
        sessionStore: PollingSessionStore = PollingSessionStore(),
        retryPolicy: QueuePollingRetryPolicy = .default
    ) {
        self.github = github
        self.client = client
        self.jobStore = jobStore
        self.dispatcher = dispatcher
        self.sessionStore = sessionStore
        self.retryPolicy = retryPolicy
    }

    func setOnJobReady(_ callback: @escaping @Sendable (RunnerJob) async -> Void) {
        onJobReady = callback
    }

    func setOnJobCompleted(_ callback: @escaping @Sendable (RunnerJob, JobResult) async -> Void) {
        onJobCompleted = callback
    }

    // MARK: - Lifecycle

    func start(orgs: [Organization]) async {
        let enabledOrgs = orgs.filter { $0.isEnabled && $0.scaleSetId != nil }

        // Set org priority in dispatcher — array order = priority
        await dispatcher.setOrgPriority(orgs.filter(\.isEnabled).map(\.name))

        Log.queue.info("Starting queue engine for \(enabledOrgs.count) org(s)")

        for org in enabledOrgs {
            let poller = ScaleSetPoller(
                client: client,
                tokenProvider: { [github] org in
                    try await github.installationToken(for: org)
                }
            )
            pollers[org.name] = poller
            startPolling(org: org, poller: poller)
        }
    }

    func stop() async {
        Log.queue.info("Stopping queue engine")

        // Cancelling tasks triggers session cleanup in each polling loop
        for (name, task) in pollingTasks {
            task.cancel()
            Log.queue.debug("Cancelled polling for \(name)")
        }

        for (_, task) in pollingTasks {
            await task.value
        }

        pollingTasks.removeAll()
        pollers.removeAll()
        sessions.removeAll()
        pollingStates.removeAll()
    }

    func pollingState(orgName: String) -> QueuePollingState? {
        pollingStates[orgName]
    }

    // MARK: - Polling Loop

    private func startPolling(org: Organization, poller: ScaleSetPoller) {
        let task = Task {
            await self.pollingLoop(org: org, poller: poller)
        }
        pollingTasks[org.name] = task
    }

    private func pollingLoop(org: Organization, poller: ScaleSetPoller) async {
        pollingStates[org.name] = QueuePollingState(
            orgName: org.name,
            sessionId: nil,
            isRunning: true,
            lastFailure: nil,
            retryAttempt: 0,
            nextRetryDelay: nil
        )

        // Create session
        do {
            let token = try await github.installationToken(for: org)
            guard let scaleSetId = org.scaleSetId else {
                throw ScaleSetPollerError.missingScaleSetId(org: org.name)
            }

            if let staleSession = sessionStore.record(for: org.name), staleSession.scaleSetId == scaleSetId {
                try await poller.deleteSession(org: org, token: token, sessionId: staleSession.sessionId)
                sessionStore.remove(orgName: org.name)
                Log.queue.info("Deleted stale polling session \(staleSession.sessionId) for org \(org.name)")
            }

            let session = try await poller.createSession(org: org, token: token)
            guard let sessionId = session.sessionId else {
                Log.queue.error("No session ID returned for org \(org.name)")
                pollingStates[org.name]?.isRunning = false
                pollingStates[org.name]?.lastFailure = .malformedResponse
                return
            }
            sessions[org.name] = sessionId
            sessionStore.save(
                PollingSessionRecord(
                    orgName: org.name,
                    scaleSetId: scaleSetId,
                    sessionId: sessionId,
                    updatedAt: Date()
                )
            )
            pollingStates[org.name]?.sessionId = sessionId
        } catch {
            Log.queue.error("Failed to create session for org \(org.name): \(error.localizedDescription)")
            pollingStates[org.name]?.isRunning = false
            pollingStates[org.name]?.lastFailure = failureKind(for: error)
            return
        }

        guard let sessionId = sessions[org.name] else { return }

        Log.queue.info("Polling loop started for org \(org.name)")

        while !Task.isCancelled {
            do {
                let messages = try await poller.poll(org: org, sessionId: sessionId)
                pollingStates[org.name]?.lastFailure = nil
                pollingStates[org.name]?.retryAttempt = 0
                pollingStates[org.name]?.nextRetryDelay = nil
                await handleMessages(messages, org: org)
            } catch is CancellationError {
                break
            } catch {
                let failure = failureKind(for: error)
                let nextAttempt = (pollingStates[org.name]?.retryAttempt ?? 0) + 1
                let retryAfter = (error as? ScaleSetPollerError)?.retryAfter
                let delay = retryPolicy.delay(for: failure, attempt: nextAttempt, retryAfter: retryAfter)

                pollingStates[org.name]?.lastFailure = failure
                pollingStates[org.name]?.retryAttempt = nextAttempt
                pollingStates[org.name]?.nextRetryDelay = delay

                Log.queue.error(
                    "Poll error for \(org.name) [\(failure.rawValue)], retry \(nextAttempt) in \(delay)s: \(error.localizedDescription)"
                )

                do {
                    try await sleep(seconds: delay)
                } catch is CancellationError {
                    break
                } catch {
                    break
                }
            }
        }

        // Cleanup session on exit
        if let sessionId = sessions[org.name] {
            do {
                let token = try await github.installationToken(for: org)
                try await poller.deleteSession(org: org, token: token, sessionId: sessionId)
                sessionStore.remove(orgName: org.name)
            } catch {
                Log.queue.warning("Failed to delete session for \(org.name): \(error.localizedDescription)")
            }
        }

        pollingStates[org.name]?.isRunning = false
        Log.queue.info("Polling loop ended for org \(org.name)")
    }

    // MARK: - Message Handling

    func handleMessages(_ messages: [ScaleSetMessage], org: Organization) async {
        for message in messages {
            if processedMessageIdsByOrg[org.name, default: []].contains(message.messageId) {
                Log.queue.debug("Skipping duplicate GitHub message \(message.messageId) for org \(org.name)")
                continue
            }
            processedMessageIdsByOrg[org.name, default: []].insert(message.messageId)

            switch message.messageType {
            case "JobAvailable":
                await handleJobAvailable(message, org: org)
            case "JobCompleted":
                await handleJobCompleted(message)
            default:
                Log.queue.debug("Unhandled message type: \(message.messageType)")
            }
        }
    }

    private func handleJobAvailable(_ message: ScaleSetMessage, org: Organization) async {
        guard let data = message.body.data(using: .utf8),
            let jobMessage = try? JSONDecoder().decode(JobAvailableMessage.self, from: data)
        else {
            Log.queue.warning("Failed to decode JobAvailable body")
            return
        }

        let base = jobMessage.jobMessageBase

        // Check repository filter
        if !org.acceptsRepository(base.repositoryName) {
            Log.queue.info(
                "Job \(base.jobId) skipped — repo \(base.repositoryName ?? "unknown") filtered out for org \(org.name)"
            )
            return
        }

        let job = RunnerJob(
            id: base.jobId,
            organizationName: org.name,
            runnerRequestId: base.runnerRequestId,
            status: .pending,
            workflowName: base.workflowRunName,
            repositoryName: base.repositoryName,
            queuedAt: Date()
        )

        await jobStore.addJob(job)
        await tryDispatch()
    }

    private func handleJobCompleted(_ message: ScaleSetMessage) async {
        guard let data = message.body.data(using: .utf8),
            let completed = try? JSONDecoder().decode(JobCompletedMessage.self, from: data)
        else {
            Log.queue.warning("Failed to decode JobCompleted body")
            return
        }

        let result: JobResult = completed.result == "success" ? .success : .failure(completed.result ?? "unknown")
        await dispatcher.markCompleted(jobId: completed.jobId, in: jobStore, result: result)
        if let completedJob = await jobStore.job(byId: completed.jobId) {
            await onJobCompleted?(completedJob, result)
        }
        await tryDispatch()
    }

    // MARK: - Dispatch

    func tryDispatch() async {
        guard let job = await dispatcher.nextJob(from: jobStore) else {
            return
        }

        await dispatcher.markStarted(jobId: job.id, in: jobStore)

        if let callback = onJobReady {
            guard let current = await jobStore.job(byId: job.id) else { return }
            await callback(current)
        }
    }

    private func failureKind(for error: Error) -> QueuePollingFailureKind {
        guard let pollerError = error as? ScaleSetPollerError else {
            return .unknown
        }

        switch pollerError {
        case .missingScaleSetId:
            return .missingConfiguration
        case .tokenExpired:
            return .tokenExpired
        case .permissionDenied:
            return .permissionDenied
        case .rateLimited:
            return .rateLimited
        case .transientFailure:
            return .transientFailure
        case .malformedResponse:
            return .malformedResponse
        case .requestFailed:
            return .requestFailed
        }
    }

    private func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
