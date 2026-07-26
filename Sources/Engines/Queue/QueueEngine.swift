import Foundation

actor QueueEngine {
    let jobStore: JobStore
    let dispatcher: JobDispatcher
    let runnerLeaseStore: RunnerLeaseStore
    var onJobReady: (@Sendable (RunnerJob) async -> Void)?
    var onJobCompleted: (@Sendable (RunnerJob, JobResult, JobCompletionSource) async -> Void)?

    private let github: GitHubEngine
    private let client: any GitHubClientProtocol
    private let sessionStore: PollingSessionStore
    private let retryPolicy: QueuePollingRetryPolicy
    private var pollers: [String: ScaleSetPoller] = [:]
    private var sessions: [String: String] = [:]  // account key → sessionId
    private var runnerGroupIds: [String: Int] = [:]  // account key → scale set's runner group id
    private var pollingTasks: [String: Task<Void, Never>] = [:]
    private var repositoryPollingTasks: [String: Task<Void, Never>] = [:]
    private var providerPollingTasks: [String: Task<Void, Never>] = [:]
    private var giteaProviders: [UUID: GiteaEngine] = [:]
    private var providerKeychainService: (any KeychainServiceProtocol)?
    private var providerStorage: StorageManager?
    private var pollingStates: [String: QueuePollingState] = [:]
    private var processedMessageIdsByOrg: [String: Set<Int64>] = [:]
    private let repositoryPollingInterval: TimeInterval = 10

    init(
        github: GitHubEngine,
        client: any GitHubClientProtocol,
        jobStore: JobStore = JobStore(),
        dispatcher: JobDispatcher = JobDispatcher(),
        runnerLeaseStore: RunnerLeaseStore = RunnerLeaseStore(),
        sessionStore: PollingSessionStore = PollingSessionStore(),
        retryPolicy: QueuePollingRetryPolicy = .default
    ) {
        self.github = github
        self.client = client
        self.jobStore = jobStore
        self.dispatcher = dispatcher
        self.runnerLeaseStore = runnerLeaseStore
        self.sessionStore = sessionStore
        self.retryPolicy = retryPolicy
    }

    func setOnJobReady(_ callback: @escaping @Sendable (RunnerJob) async -> Void) {
        onJobReady = callback
    }

    func setOnJobCompleted(_ callback: @escaping @Sendable (RunnerJob, JobResult, JobCompletionSource) async -> Void) {
        onJobCompleted = callback
    }

    func configureProviders(
        keychainService: any KeychainServiceProtocol,
        storage: StorageManager
    ) {
        providerKeychainService = keychainService
        providerStorage = storage
    }

    // MARK: - Lifecycle

    func start(orgs: [Organization]) async {
        let scaleSetTargets = orgs.flatMap { account in
            guard account.provider == .github, account.isEnabled else {
                return [(account: Organization, pool: RunnerPoolConfiguration)]()
            }
            return account.effectiveRunnerPools.compactMap { pool in
                guard pool.isEnabled, pool.scaleSetId != nil else { return nil }
                return (account: account.runtimeAccount(for: pool), pool: pool)
            }
        }
        let repositoryPollingOrgs = orgs.filter { $0.isEnabled && $0.usesRepositoryWorkflowPolling }
        let giteaAccounts = orgs.filter { $0.provider == .gitea && $0.isEnabled }

        // Set org priority in dispatcher — array order = priority
        await dispatcher.setOrgPriority(orgs.filter(\.isEnabled).map(\.name))

        Log.queue.info(
            "Starting queue engine for \(scaleSetTargets.count) GitHub scale-set pool(s), \(repositoryPollingOrgs.count) GitHub repository-polling account(s), and \(giteaAccounts.count) Gitea account(s)"
        )

        for target in scaleSetTargets {
            let poller = ScaleSetPoller(
                client: client,
                tokenProvider: { [github] org in
                    try await github.authorizationToken(for: org)
                }
            )
            pollers[accountKey(for: target.account, poolID: target.pool.id)] = poller
            startPolling(org: target.account, poolID: target.pool.id, poller: poller)
        }

        for org in repositoryPollingOrgs {
            startRepositoryPolling(org: org)
        }

        for account in giteaAccounts {
            do {
                let provider = try makeGiteaProvider(for: account)
                giteaProviders[account.id] = provider
                startGiteaPolling(account: account, provider: provider)
            } catch {
                pollingStates[accountKey(for: account)] = QueuePollingState(
                    orgName: account.name,
                    sessionId: nil,
                    isRunning: false,
                    lastFailure: .missingConfiguration,
                    lastFailureMessage: error.localizedDescription,
                    retryAttempt: 0,
                    nextRetryDelay: nil
                )
            }
        }
    }

    func reconcileInterruptedLeases(orgs: [Organization]) async -> RunnerReconciliationReport {
        let activeLeases = await runnerLeaseStore.activeLeases
        let enabledOrgs = orgs.filter(\.isEnabled)
        var report = RunnerReconciliationReport()

        for org in enabledOrgs {
            let orgReport: RunnerReconciliationReport
            if org.provider == .gitea {
                do {
                    let provider: GiteaEngine
                    if let existing = giteaProviders[org.id] {
                        provider = existing
                    } else {
                        provider = try makeGiteaProvider(for: org)
                    }
                    giteaProviders[org.id] = provider
                    orgReport = await provider.reconcileStaleRunners(for: org, leases: activeLeases)
                } catch {
                    orgReport = RunnerReconciliationReport(
                        failures: [RunnerReconciliationFailure(organizationName: org.name, message: error.localizedDescription)]
                    )
                }
            } else {
                orgReport = await github.reconcileStaleRunners(for: org, leases: activeLeases)
            }
            for removal in orgReport.removedRunners {
                _ = await runnerLeaseStore.completeAndRemove(jobId: removal.jobId, diagnosticsPath: nil)
                Log.queue.info("Removed stale Tarmac runner \(removal.runnerName) for job \(removal.jobId)")
            }
            report.merge(orgReport)
        }

        return report
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

        for (name, task) in repositoryPollingTasks {
            task.cancel()
            Log.queue.debug("Cancelled repository polling for \(name)")
        }

        for (_, task) in repositoryPollingTasks {
            await task.value
        }

        for (name, task) in providerPollingTasks {
            task.cancel()
            Log.queue.debug("Cancelled provider polling for \(name)")
        }
        for (_, task) in providerPollingTasks { await task.value }

        pollingTasks.removeAll()
        repositoryPollingTasks.removeAll()
        providerPollingTasks.removeAll()
        giteaProviders.removeAll()
        pollers.removeAll()
        sessions.removeAll()
        runnerGroupIds.removeAll()
        pollingStates.removeAll()
    }

    func pollingState(orgName: String) -> QueuePollingState? {
        pollingStates[orgName] ?? pollingStates.values.first { $0.orgName == orgName }
    }

    func pollingState(for account: RunnerAccount) -> QueuePollingState? {
        pollingStates[accountKey(for: account)]
            ?? pollingStates.values.first { $0.orgName == account.name }
    }

    // MARK: - Polling Loop

    private func startPolling(org: Organization, poolID: UUID, poller: ScaleSetPoller) {
        let key = accountKey(for: org, poolID: poolID)
        let task = Task {
            await self.pollingLoop(org: org, poolID: poolID, poller: poller)
        }
        pollingTasks[key] = task
    }

    private func startRepositoryPolling(org: Organization) {
        let key = accountKey(for: org)
        let task = Task {
            await self.repositoryPollingLoop(org: org)
        }
        repositoryPollingTasks[key] = task
    }

    private func startGiteaPolling(account: RunnerAccount, provider: GiteaEngine) {
        let key = accountKey(for: account)
        providerPollingTasks[key] = Task {
            await self.giteaPollingLoop(account: account, provider: provider)
        }
    }

    private func giteaPollingLoop(account: RunnerAccount, provider: GiteaEngine) async {
        let key = accountKey(for: account)
        pollingStates[key] = QueuePollingState(
            orgName: account.name,
            sessionId: nil,
            isRunning: true,
            lastFailure: nil,
            lastFailureMessage: nil,
            retryAttempt: 0,
            nextRetryDelay: nil
        )
        Log.gitea.info("Polling started provider=gitea account=\(account.id.uuidString, privacy: .public)")
        while !Task.isCancelled {
            do {
                let jobs = try await provider.queuedJobs(for: account)
                await handleProviderQueuedJobs(jobs, account: account)
                pollingStates[key]?.lastFailure = nil
                pollingStates[key]?.lastFailureMessage = nil
                pollingStates[key]?.retryAttempt = 0
                pollingStates[key]?.nextRetryDelay = nil
                pollingStates[key]?.lastSuccessfulPollAt = Date()
                try await sleep(seconds: repositoryPollingInterval)
            } catch is CancellationError {
                break
            } catch {
                let failure = giteaFailureKind(for: error)
                applyPollingFailure(orgName: key, failure: failure, message: error.localizedDescription)
                let attempt = pollingStates[key]?.retryAttempt ?? 1
                let delay = retryPolicy.delay(for: failure, attempt: attempt)
                pollingStates[key]?.nextRetryDelay = delay
                Log.gitea.error(
                    "Polling failed provider=gitea account=\(account.id.uuidString, privacy: .public) retry=\(attempt) delay=\(delay): \(error.localizedDescription)"
                )
                do { try await sleep(seconds: delay) } catch { break }
            }
        }
        pollingStates[key]?.isRunning = false
    }

    private func repositoryPollingLoop(org: Organization) async {
        let key = accountKey(for: org)
        pollingStates[key] = QueuePollingState(
            orgName: org.name,
            sessionId: nil,
            isRunning: true,
            lastFailure: nil,
            lastFailureMessage: nil,
            retryAttempt: 0,
            nextRetryDelay: nil
        )

        Log.queue.info("Repository polling loop started for org \(org.name)")

        while !Task.isCancelled {
            do {
                for repositoryName in org.filteredRepositories {
                    let jobs = try await github.queuedWorkflowJobs(for: org, repositoryName: repositoryName)
                    await handleQueuedWorkflowJobs(jobs, org: org)
                }
                pollingStates[key]?.lastFailure = nil
                pollingStates[key]?.lastFailureMessage = nil
                pollingStates[key]?.retryAttempt = 0
                pollingStates[key]?.nextRetryDelay = nil
                try await sleep(seconds: repositoryPollingInterval)
            } catch is CancellationError {
                break
            } catch {
                let failure = failureKind(for: error)
                applyPollingFailure(
                    orgName: key,
                    failure: failure,
                    message: pollingFailureMessage(for: error, failure: failure)
                        ?? "Failed to poll queued workflow jobs for \(org.name)."
                )

                let nextAttempt = pollingStates[key]?.retryAttempt ?? 0
                let delay = retryPolicy.delay(for: failure, attempt: nextAttempt)
                pollingStates[key]?.nextRetryDelay = delay

                Log.queue.error(
                    "Repository poll error for \(org.name) [\(failure.rawValue)], retry \(nextAttempt) in \(delay)s: \(error.localizedDescription)"
                )

                do {
                    try await sleep(seconds: delay)
                } catch {
                    break
                }
            }
        }

        pollingStates[key]?.isRunning = false
        Log.queue.info("Repository polling loop ended for org \(org.name)")
    }

    private func pollingLoop(org: Organization, poolID: UUID, poller: ScaleSetPoller) async {
        let key = accountKey(for: org, poolID: poolID)
        pollingStates[key] = QueuePollingState(
            orgName: org.name,
            sessionId: nil,
            isRunning: true,
            lastFailure: nil,
            lastFailureMessage: nil,
            retryAttempt: 0,
            nextRetryDelay: nil
        )

        // Create session
        do {
            let token = try await github.authorizationToken(for: org)
            guard let scaleSetId = org.scaleSetId else {
                throw ScaleSetPollerError.missingScaleSetId(org: org.name)
            }

            let legacyKey = accountKey(for: org)
            if let staleSession = sessionStore.record(for: key) ?? sessionStore.record(for: legacyKey),
                staleSession.scaleSetId == scaleSetId
            {
                try await poller.deleteSession(org: org, token: token, sessionId: staleSession.sessionId)
                sessionStore.remove(orgName: key)
                sessionStore.remove(orgName: legacyKey)
                Log.queue.info("Deleted stale polling session \(staleSession.sessionId) for org \(org.name)")
            }

            let session = try await poller.createSession(org: org, token: token)
            guard let sessionId = session.sessionId else {
                Log.queue.error("No session ID returned for org \(org.name)")
                applyPollingFailure(
                    orgName: key,
                    failure: .malformedResponse,
                    message: "GitHub did not return a scale-set session ID for \(org.name)."
                )
                pollingStates[key]?.isRunning = false
                return
            }
            sessions[key] = sessionId
            if let groupId = session.runnerScaleSet?.runnerGroupId {
                runnerGroupIds[key] = groupId
                Log.queue.debug("Scale set for org \(org.name) belongs to runner group \(groupId)")
            }
            sessionStore.save(
                PollingSessionRecord(
                    orgName: key,
                    scaleSetId: scaleSetId,
                    sessionId: sessionId,
                    updatedAt: Date()
                )
            )
            pollingStates[key]?.sessionId = sessionId
        } catch {
            Log.queue.error("Failed to create session for org \(org.name): \(error.localizedDescription)")
            let failure = failureKind(for: error)
            applyPollingFailure(
                orgName: key,
                failure: failure,
                message: pollingFailureMessage(for: error, failure: failure)
            )
            pollingStates[key]?.isRunning = false
            return
        }

        guard let sessionId = sessions[key] else { return }

        Log.queue.info("Polling loop started for org \(org.name)")

        while !Task.isCancelled {
            do {
                let messages = try await poller.poll(org: org, sessionId: sessionId)
                pollingStates[key]?.lastFailure = nil
                pollingStates[key]?.lastFailureMessage = nil
                pollingStates[key]?.retryAttempt = 0
                pollingStates[key]?.nextRetryDelay = nil
                await handleMessages(messages, org: org, poolID: poolID)
            } catch is CancellationError {
                break
            } catch {
                let failure = failureKind(for: error)
                applyPollingFailure(
                    orgName: key,
                    failure: failure,
                    message: pollingFailureMessage(for: error, failure: failure)
                )

                if failure.isTerminal {
                    Log.queue.error(
                        "Poll paused for \(org.name) [\(failure.rawValue)]: \(error.localizedDescription)"
                    )
                    break
                }

                let nextAttempt = pollingStates[key]?.retryAttempt ?? 0
                let retryAfter = (error as? ScaleSetPollerError)?.retryAfter
                let delay = retryPolicy.delay(for: failure, attempt: nextAttempt, retryAfter: retryAfter)
                pollingStates[key]?.nextRetryDelay = delay

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
        if let sessionId = sessions[key] {
            do {
                let token = try await github.authorizationToken(for: org)
                try await poller.deleteSession(org: org, token: token, sessionId: sessionId)
                sessionStore.remove(orgName: key)
            } catch {
                Log.queue.warning("Failed to delete session for \(org.name): \(error.localizedDescription)")
            }
        }

        pollingStates[key]?.isRunning = false
        Log.queue.info("Polling loop ended for org \(org.name)")
    }

    // MARK: - Message Handling

    func handleProviderQueuedJobs(_ jobs: [ProviderQueuedJob], account: RunnerAccount) async {
        let key = accountKey(for: account)
        var enqueued = false
        for queuedJob in jobs {
            guard !processedMessageIdsByOrg[key, default: []].contains(queuedJob.localID),
                await jobStore.job(byId: queuedJob.localID) == nil
            else { continue }
            guard let pool = account.runnerPool(matching: queuedJob.labels) else {
                Log.queue.warning(
                    "Queued provider job \(queuedJob.localID) has no enabled runner pool matching labels \(queuedJob.labels.joined(separator: ","), privacy: .public)"
                )
                continue
            }
            processedMessageIdsByOrg[key, default: []].insert(queuedJob.localID)
            let job = RunnerJob(
                id: queuedJob.localID,
                accountID: account.id,
                provider: account.provider,
                remoteJobID: queuedJob.key.remoteJobID,
                runnerPoolID: pool.id,
                requestedLabels: queuedJob.labels,
                organizationName: account.name,
                runnerRequestId: queuedJob.runID,
                status: .pending,
                workflowName: queuedJob.name,
                repositoryName: queuedJob.repositoryName,
                queuedAt: queuedJob.queuedAt
            )
            await jobStore.addJob(job)
            enqueued = true
            Log.queue.info(
                "Queued provider=gitea account=\(account.id.uuidString, privacy: .public) remote_job=\(queuedJob.key.remoteJobID, privacy: .public) local_job=\(queuedJob.localID)"
            )
        }
        if enqueued { await tryDispatch() }
    }

    func prepareRunner(
        for job: RunnerJob,
        account: RunnerAccount,
        runnerName: String
    ) async throws -> PreparedRunner {
        if account.provider == .gitea {
            let provider: GiteaEngine
            if let existing = giteaProviders[account.id] {
                provider = existing
            } else {
                provider = try makeGiteaProvider(for: account)
            }
            giteaProviders[account.id] = provider
            return try await provider.prepareRunner(for: account, runnerName: runnerName)
        }
        return PreparedRunner(
            runnerPath: try await github.ensureRunner(for: account),
            guestConfig: try await github.generateRunnerGuestConfig(
                for: account,
                runnerName: runnerName,
                runnerGroupId: job.runnerGroupId,
                repositoryName: job.repositoryName
            )
        )
    }

    func waitForProviderClaim(
        jobID: Int64,
        account: RunnerAccount,
        runnerName: String,
        timeout: TimeInterval = 120
    ) async throws -> ProviderQueuedJob? {
        guard account.provider == .gitea else { return nil }
        let provider: GiteaEngine
        if let existing = giteaProviders[account.id] {
            provider = existing
        } else {
            provider = try makeGiteaProvider(for: account)
        }
        giteaProviders[account.id] = provider
        let deadline = Date().addingTimeInterval(timeout)
        let demandRemoteJobID = await jobStore.job(byId: jobID)?.remoteJobID
        var missingDemandPolls = 0
        while Date() < deadline {
            try Task.checkCancellation()
            if let claimed = try await provider.claimedJob(for: account, runnerName: runnerName) {
                await jobStore.bindProviderJob(jobId: jobID, claimedJob: claimed)
                return claimed
            }
            if let demandRemoteJobID {
                let queued = try await provider.queuedJobs(for: account)
                if queued.contains(where: { $0.key.remoteJobID == demandRemoteJobID }) {
                    missingDemandPolls = 0
                } else {
                    missingDemandPolls += 1
                    if missingDemandPolls >= 3 {
                        throw GiteaAPIError.jobCancelledBeforeClaim(demandRemoteJobID)
                    }
                }
            }
            try await sleep(seconds: 2)
        }
        return nil
    }

    func releaseProviderDemand(job: RunnerJob, account: RunnerAccount, diagnosticsPath: String?) async {
        processedMessageIdsByOrg[accountKey(for: account)]?.remove(job.id)
        _ = await runnerLeaseStore.completeAndRemove(jobId: job.id, diagnosticsPath: diagnosticsPath)
        await jobStore.removeJob(id: job.id)
        Log.gitea.info(
            "Released unclaimed demand account=\(account.id.uuidString, privacy: .public) local_job=\(job.id) for retry"
        )
    }

    func reconciledResult(for job: RunnerJob, account: RunnerAccount, fallback: JobResult) async -> JobResult {
        guard account.provider == .gitea,
            let remoteJobID = job.remoteJobID,
            let provider = giteaProviders[account.id]
        else { return fallback }
        do {
            for _ in 0..<10 {
                if let result = try await provider.terminalResult(
                    for: account,
                    remoteJobID: remoteJobID,
                    repositoryName: job.repositoryName
                ) {
                    return result
                }
                try await sleep(seconds: 2)
            }
        } catch {
            Log.gitea.warning("Terminal status reconciliation failed for remote job \(remoteJobID): \(error.localizedDescription)")
        }
        return fallback
    }

    func handleMessages(_ messages: [ScaleSetMessage], org: Organization, poolID: UUID? = nil) async {
        let resolvedPoolID = poolID ?? org.runnerPool(id: nil)?.id
        let key = accountKey(for: org, poolID: resolvedPoolID)
        for message in messages {
            if processedMessageIdsByOrg[key, default: []].contains(message.messageId) {
                Log.queue.debug("Skipping duplicate GitHub message \(message.messageId) for org \(org.name)")
                continue
            }
            processedMessageIdsByOrg[key, default: []].insert(message.messageId)

            switch message.messageType {
            case "JobAvailable":
                await handleJobAvailable(message, org: org, poolID: resolvedPoolID)
            case "JobCompleted":
                await handleJobCompleted(message)
            default:
                Log.queue.debug("Unhandled message type: \(message.messageType)")
            }
        }
    }

    func handleQueuedWorkflowJobs(_ jobs: [GitHubQueuedWorkflowJob], org: Organization) async {
        let key = accountKey(for: org)
        let orderedJobs = jobs.sorted {
            switch ($0.queuedAt, $1.queuedAt) {
            case let (lhs?, rhs?) where lhs != rhs:
                return lhs < rhs
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            default:
                return $0.id < $1.id
            }
        }
        var enqueuedJob = false

        for queuedJob in orderedJobs {
            if processedMessageIdsByOrg[key, default: []].contains(queuedJob.id) {
                Log.queue.debug("Skipping duplicate queued workflow job \(queuedJob.id) for org \(org.name)")
                continue
            }
            if await jobStore.job(byId: queuedJob.id) != nil {
                processedMessageIdsByOrg[key, default: []].insert(queuedJob.id)
                continue
            }
            guard org.acceptsRepository(queuedJob.repositoryName) else {
                Log.queue.info(
                    "Queued workflow job \(queuedJob.id) skipped — repo \(queuedJob.repositoryName) filtered out for org \(org.name)"
                )
                continue
            }
            guard let pool = org.runnerPool(matching: queuedJob.labels) else {
                Log.queue.warning(
                    "Queued workflow job \(queuedJob.id) has no enabled runner pool matching labels \(queuedJob.labels.joined(separator: ","), privacy: .public)"
                )
                continue
            }

            processedMessageIdsByOrg[key, default: []].insert(queuedJob.id)
            let job = RunnerJob(
                id: queuedJob.id,
                accountID: org.id,
                provider: org.provider,
                remoteJobID: String(queuedJob.id),
                runnerPoolID: pool.id,
                requestedLabels: queuedJob.labels,
                organizationName: org.name,
                runnerRequestId: queuedJob.runId,
                status: .pending,
                workflowName: queuedJob.name,
                repositoryName: queuedJob.repositoryName,
                queuedAt: queuedJob.queuedAt ?? Date()
            )

            await jobStore.addJob(job)
            enqueuedJob = true
        }

        if enqueuedJob {
            await tryDispatch()
        }
    }

    private func handleJobAvailable(_ message: ScaleSetMessage, org: Organization, poolID: UUID?) async {
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

        var job = RunnerJob(
            id: base.jobId,
            accountID: org.id,
            provider: org.provider,
            remoteJobID: String(base.jobId),
            runnerPoolID: poolID,
            requestedLabels: org.runnerLabels,
            organizationName: org.name,
            runnerRequestId: base.runnerRequestId,
            status: .pending,
            workflowName: base.workflowRunName,
            repositoryName: base.repositoryName,
            queuedAt: Date()
        )
        job.runnerGroupId = runnerGroupIds[accountKey(for: org, poolID: poolID)]

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
        await completeJob(jobId: completed.jobId, result: result, source: .github)
    }

    func completeJobFromGuest(jobId: Int64, result: JobResult) async {
        await completeJob(jobId: jobId, result: result, source: .guest)
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

    private func completeJob(jobId: Int64, result: JobResult, source: JobCompletionSource) async {
        guard let job = await jobStore.job(byId: jobId) else {
            Log.queue.warning("Completion ignored for unknown job \(jobId)")
            return
        }

        guard job.status != .completed, job.status != .failed else {
            Log.queue.info("Completion ignored for terminal job \(jobId)")
            return
        }

        await dispatcher.markCompleted(jobId: jobId, in: jobStore, result: result)
        if let completedJob = await jobStore.job(byId: jobId) {
            await onJobCompleted?(completedJob, result, source)
        }
        await tryDispatch()
    }

    private func applyPollingFailure(
        orgName: String,
        failure: QueuePollingFailureKind,
        message: String?
    ) {
        guard var state = pollingStates[orgName] else {
            return
        }

        state.lastFailure = failure
        state.lastFailureMessage = message
        if failure.isTerminal {
            state.retryAttempt = 0
            state.nextRetryDelay = nil
        } else {
            state.retryAttempt += 1
        }
        pollingStates[orgName] = state
    }

    private func accountKey(for org: Organization, poolID: UUID? = nil) -> String {
        if let poolID {
            return "\(accountKey(for: org))#pool:\(poolID.uuidString.lowercased())"
        }
        if org.provider == .gitea { return "gitea:\(org.id.uuidString)" }
        switch org.accountType {
        case .repository:
            return org.accountPath
        case .organization, .enterprise:
            return org.name
        }
    }

    private func makeGiteaProvider(for account: RunnerAccount) throws -> GiteaEngine {
        guard let providerKeychainService, let providerStorage else {
            throw GiteaAPIError.invalidResponse
        }
        return try GiteaEngine(
            account: account,
            keychainService: providerKeychainService,
            storage: providerStorage
        )
    }

    private func giteaFailureKind(for error: Error) -> QueuePollingFailureKind {
        guard let error = error as? GiteaAPIError else { return .unknown }
        switch error {
        case .missingToken, .invalidURL, .unsupportedVersion: return .missingConfiguration
        case .httpError(let status, _) where status == 401: return .tokenExpired
        case .httpError(let status, _) where status == 403: return .permissionDenied
        case .httpError(let status, _) where status == 429: return .rateLimited
        case .httpError(let status, _) where status >= 500: return .transientFailure
        case .decodingError: return .malformedResponse
        default: return .requestFailed
        }
    }

    private func pollingFailureMessage(for error: Error, failure: QueuePollingFailureKind) -> String? {
        if let pollerError = error as? ScaleSetPollerError {
            return pollerError.errorDescription
        }
        if failure == .malformedResponse {
            return error.localizedDescription
        }
        return nil
    }

    private func failureKind(for error: Error) -> QueuePollingFailureKind {
        guard let pollerError = error as? ScaleSetPollerError else {
            return .unknown
        }

        switch pollerError {
        case .missingScaleSetId:
            return .missingConfiguration
        case .scaleSetUnavailable:
            return .scaleSetUnavailable
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

enum JobCompletionSource: Equatable, Sendable {
    case github
    case guest
}
