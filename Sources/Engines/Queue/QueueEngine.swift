import Foundation

actor QueueEngine {
    let jobStore: JobStore
    let dispatcher: JobDispatcher
    var onJobReady: (@Sendable (RunnerJob) async -> Void)?

    private let github: GitHubEngine
    private let client: any GitHubClientProtocol
    private var pollers: [String: ScaleSetPoller] = [:]
    private var sessions: [String: String] = [:]  // org name → sessionId
    private var pollingTasks: [String: Task<Void, Never>] = [:]

    init(
        github: GitHubEngine,
        client: any GitHubClientProtocol,
        jobStore: JobStore = JobStore(),
        dispatcher: JobDispatcher = JobDispatcher()
    ) {
        self.github = github
        self.client = client
        self.jobStore = jobStore
        self.dispatcher = dispatcher
    }

    func setOnJobReady(_ callback: @escaping @Sendable (RunnerJob) async -> Void) {
        onJobReady = callback
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

    func stop() {
        Log.queue.info("Stopping queue engine")

        // Cancelling tasks triggers session cleanup in each polling loop
        for (name, task) in pollingTasks {
            task.cancel()
            Log.queue.debug("Cancelled polling for \(name)")
        }

        pollingTasks.removeAll()
        pollers.removeAll()
        sessions.removeAll()
    }

    // MARK: - Polling Loop

    private func startPolling(org: Organization, poller: ScaleSetPoller) {
        let task = Task {
            await self.pollingLoop(org: org, poller: poller)
        }
        pollingTasks[org.name] = task
    }

    private func pollingLoop(org: Organization, poller: ScaleSetPoller) async {
        // Create session
        do {
            let token = try await github.installationToken(for: org)
            let session = try await poller.createSession(org: org, token: token)
            guard let sessionId = session.sessionId else {
                Log.queue.error("No session ID returned for org \(org.name)")
                return
            }
            sessions[org.name] = sessionId
        } catch {
            Log.queue.error("Failed to create session for org \(org.name): \(error.localizedDescription)")
            return
        }

        guard let sessionId = sessions[org.name] else { return }

        Log.queue.info("Polling loop started for org \(org.name)")

        while !Task.isCancelled {
            do {
                let messages = try await poller.poll(org: org, sessionId: sessionId)
                await handleMessages(messages, org: org)
            } catch is CancellationError {
                break
            } catch {
                Log.queue.error("Poll error for \(org.name): \(error.localizedDescription)")
                // Back off on errors before retrying
                try? await Task.sleep(for: .seconds(5))
            }
        }

        // Cleanup session on exit
        if let sessionId = sessions[org.name] {
            do {
                let token = try await github.installationToken(for: org)
                try await poller.deleteSession(org: org, token: token, sessionId: sessionId)
            } catch {
                Log.queue.warning("Failed to delete session for \(org.name): \(error.localizedDescription)")
            }
        }

        Log.queue.info("Polling loop ended for org \(org.name)")
    }

    // MARK: - Message Handling

    func handleMessages(_ messages: [ScaleSetMessage], org: Organization) async {
        for message in messages {
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
              let jobMessage = try? JSONDecoder().decode(JobAvailableMessage.self, from: data) else {
            Log.queue.warning("Failed to decode JobAvailable body")
            return
        }

        let base = jobMessage.jobMessageBase

        // Check repository filter
        if !org.acceptsRepository(base.repositoryName) {
            Log.queue.info("Job \(base.jobId) skipped — repo \(base.repositoryName ?? "unknown") filtered out for org \(org.name)")
            return
        }

        let job = RunnerJob(
            id: base.jobId,
            organizationName: org.name,
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
              let completed = try? JSONDecoder().decode(JobCompletedMessage.self, from: data) else {
            Log.queue.warning("Failed to decode JobCompleted body")
            return
        }

        let result: JobResult = completed.result == "success" ? .success : .failure(completed.result ?? "unknown")
        await dispatcher.markCompleted(jobId: completed.jobId, in: jobStore, result: result)
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
}
