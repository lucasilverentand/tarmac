import Foundation

enum AppSection: String, Identifiable, CaseIterable, Hashable {
    case queue
    case workers
    case organizations
    case cache
    case storage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .queue: "Queue"
        case .workers: "Workers"
        case .organizations: "Accounts"
        case .cache: "Cache & Diagnostics"
        case .storage: "Storage"
        }
    }

    var systemImage: String {
        switch self {
        case .queue: "tray.full"
        case .workers: "server.rack"
        case .organizations: "building.2"
        case .cache: "archivebox"
        case .storage: "externaldrive"
        }
    }
}

@Observable
@MainActor
final class AppState {
    let configStore: ConfigStore
    let queueViewModel: QueueViewModel
    let vmStatusViewModel: VMStatusViewModel
    let settingsViewModel: SettingsViewModel
    var selectedSection: AppSection = .queue

    private var githubEngine: GitHubEngine?
    private var queueEngine: QueueEngine?
    private var vmEngine: VMEngine?
    private var vmEngines: [UUID: VMEngine] = [:]
    private var runnerPools: [UUID: RunnerPoolConfiguration] = [:]
    private var activeJobPoolIDs: [Int64: UUID] = [:]
    private var syncTask: Task<Void, Never>?
    private var completionMonitorTasks: [Int64: Task<Void, Never>] = [:]
    private var warmRunnerIdleReleaseTasks: [UUID: Task<Void, Never>] = [:]
    private var warmRunnerIdleShutdownDates: [UUID: Date] = [:]
    private var pinnedWarmRunnerPoolIDs: Set<UUID> = []
    private var warmRunnerConfigurationTask: Task<Void, Never>?
    private var pendingWarmRunnerConfiguration: WarmRunnerConfiguration?
    private let warmRunnerIdleShutdownSecondsOverride: Int?
    private var controlVMEngine: VMEngine?
    private var vmControlServer: LocalVMControlHTTPServer?
    private var vmControlHandler: VMControlHandler?

    private let githubClientFactory: () -> any GitHubClientProtocol
    private let queueEngineFactory: (GitHubEngine, any GitHubClientProtocol) -> QueueEngine
    private let vmEngineFactory:
        @MainActor (String, String, String, CacheConfiguration, DiagnosticsRetentionConfiguration) -> VMEngine

    init() {
        let configStore = ConfigStore()
        self.configStore = configStore
        self.queueViewModel = QueueViewModel()
        self.vmStatusViewModel = VMStatusViewModel()
        self.settingsViewModel = SettingsViewModel(configStore: configStore)
        self.githubClientFactory = { GitHubClient() }
        self.queueEngineFactory = { github, client in
            QueueEngine(github: github, client: client)
        }
        self.vmEngineFactory = { cachePath, basePath, platformPath, cacheConfig, diagnosticsRetention in
            VMEngine(
                cacheDirectoryPath: cachePath,
                baseImagePath: basePath,
                platformDirectoryPath: platformPath,
                cacheConfig: cacheConfig,
                diagnosticsRetention: diagnosticsRetention
            )
        }
        self.warmRunnerIdleShutdownSecondsOverride = nil
        configureSettingsCallbacks()
        refreshReadiness(performCloneProbe: false)
    }

    init(
        configStore: ConfigStore,
        githubClientFactory: @escaping () -> any GitHubClientProtocol = { GitHubClient() },
        queueEngineFactory: @escaping (GitHubEngine, any GitHubClientProtocol) -> QueueEngine = { github, client in
            QueueEngine(github: github, client: client)
        },
        vmEngineFactory:
            @escaping @MainActor (String, String, String, CacheConfiguration, DiagnosticsRetentionConfiguration) ->
            VMEngine = {
                cachePath,
                basePath,
                platformPath,
                cacheConfig,
                diagnosticsRetention in
                VMEngine(
                    cacheDirectoryPath: cachePath,
                    baseImagePath: basePath,
                    platformDirectoryPath: platformPath,
                    cacheConfig: cacheConfig,
                    diagnosticsRetention: diagnosticsRetention
                )
            },
        warmRunnerIdleShutdownSecondsOverride: Int? = nil
    ) {
        self.configStore = configStore
        self.queueViewModel = QueueViewModel()
        self.vmStatusViewModel = VMStatusViewModel()
        self.settingsViewModel = SettingsViewModel(configStore: configStore)
        self.githubClientFactory = githubClientFactory
        self.queueEngineFactory = queueEngineFactory
        self.vmEngineFactory = vmEngineFactory
        self.warmRunnerIdleShutdownSecondsOverride = warmRunnerIdleShutdownSecondsOverride
        configureSettingsCallbacks()
        refreshReadiness(performCloneProbe: false)
    }

    /// Whether a warm-runner idle shutdown task is pending (test access).
    internal var isWarmRunnerIdleReleaseScheduled: Bool {
        !warmRunnerIdleReleaseTasks.isEmpty
    }

    /// Delivers scale-set messages through the live queue engine (test access).
    internal func testing_handleScaleSetMessages(_ messages: [ScaleSetMessage], org: Organization) async {
        await queueEngine?.handleMessages(messages, org: org)
    }

    #if DEBUG
        /// Delivers repository-polled workflow jobs through the live queue engine (test access).
        @discardableResult
        internal func testing_handleQueuedWorkflowJobs(
            _ jobs: [GitHubQueuedWorkflowJob],
            org: Organization
        ) async -> Bool {
            guard let queueEngine else {
                return false
            }
            await queueEngine.handleQueuedWorkflowJobs(jobs, org: org)
            return true
        }
    #endif

    // MARK: - Engine Lifecycle

    func start() async {
        guard queueEngine == nil else {
            Log.app.debug("Start ignored because app is already running")
            return
        }

        _ = configStore.configureApprovedAppleReleasePoolsIfNeeded()
        refreshReadiness()
        guard vmStatusViewModel.readyForJobs else {
            Log.app.warning("Cannot start: \(self.vmStatusViewModel.readinessStatusText)")
            return
        }

        let client = githubClientFactory()
        let storage = StorageManager(rootPath: configStore.storageRootPath)
        let githubEngine = GitHubEngine(
            client: client,
            keychainService: configStore.keychainService,
            storage: storage
        )
        self.githubEngine = githubEngine

        let setupResults = await settingsViewModel.runGitHubSetupChecks(using: githubEngine)
        var setupIssues = setupResults.flatMap(\.readinessIssues)
        for account in configStore.organizations where account.isEnabled && account.provider == .gitea {
            let result = await settingsViewModel.runGiteaSetupCheck(for: account)
            setupIssues.append(
                contentsOf: result.issues.map {
                    RunnerHostReadinessIssue(category: .github, message: "Gitea: \($0.message)")
                }
            )
        }
        guard setupIssues.isEmpty else {
            var readiness = vmStatusViewModel.readiness
            readiness.issues.append(contentsOf: setupIssues)
            vmStatusViewModel.readiness = readiness
            self.githubEngine = nil
            Log.app.warning("Cannot start: GitHub setup checks failed")
            return
        }

        vmEngines.removeAll()
        runnerPools.removeAll()
        for account in configStore.organizations where account.isEnabled {
            for pool in account.effectiveRunnerPools where pool.isEnabled {
                let baseImagePath = pool.resolvedBaseImagePath(defaultPath: configStore.resolvedBaseImagePath)
                guard FileManager.default.fileExists(atPath: baseImagePath) else {
                    Log.app.warning(
                        "Runner pool \(pool.displayName, privacy: .public) is enabled but its base image is missing at \(baseImagePath, privacy: .public)"
                    )
                    continue
                }
                let engine = vmEngineFactory(
                    pool.runtimeStorageRootPath(storageRootPath: configStore.storageRootPath),
                    baseImagePath,
                    pool.resolvedPlatformDirectoryPath(storageRootPath: configStore.storageRootPath),
                    configStore.cacheConfig,
                    configStore.diagnosticsRetentionConfig
                )
                engine.updateWarmRunnerConfig(configStore.warmRunnerConfig)
                vmEngines[pool.id] = engine
                runnerPools[pool.id] = pool
                if vmEngine == nil { vmEngine = engine }
            }
        }
        guard !vmEngines.isEmpty else {
            self.githubEngine = nil
            Log.app.error("Cannot start: no enabled runner pool has a base image")
            return
        }
        vmStatusViewModel.baseImageExists = vmEngines.values.contains(where: \.baseImageExists)
        vmStatusViewModel.baseImageVerified = vmEngines.values.contains(where: \.baseImageVerified)
        refreshReadiness()

        let queueEngine = queueEngineFactory(githubEngine, client)
        await queueEngine.configureProviders(
            keychainService: configStore.keychainService,
            storage: storage
        )
        self.queueEngine = queueEngine

        // Wire job dispatch → VM provisioning
        await queueEngine.setOnJobReady { [weak self] job in
            guard let self else { return }
            await self.handleJobReady(job)
        }
        await queueEngine.setOnJobCompleted { [weak self] job, result, source in
            guard let self else { return }
            await self.handleJobCompleted(job, result: result, source: source)
        }

        do {
            let cleanup = try storage.cleanupOrphanedJobArtifacts(
                activeLeases: await queueEngine.runnerLeaseStore.activeLeases
            )
            if cleanup.removedItems > 0 {
                Log.app.info(
                    "Reclaimed \(cleanup.removedDisks) orphaned VM disk(s) and \(cleanup.removedJobDirectories) orphaned job folder(s)."
                )
            }
        } catch {
            Log.app.warning("Failed to reclaim orphaned VM artifacts: \(error.localizedDescription)")
        }

        let reconciliation = await queueEngine.reconcileInterruptedLeases(orgs: configStore.organizations)
        vmStatusViewModel.runnerReconciliation = reconciliation

        for (poolID, engine) in vmEngines where runnerPools[poolID]?.keepsWarmRunner == true {
            _ = await prewarmRunnerIfNeeded(using: engine)
        }

        // Start polling
        await queueEngine.start(orgs: configStore.organizations)
        queueViewModel.startPolling()

        // Sync job store → view model periodically
        startJobStoreSync()

        Log.app.info("App started — polling \(self.configStore.organizations.filter(\.isEnabled).count) org(s)")
        syncVMControlServer()
    }

    func stop() async {
        let configurationTask = warmRunnerConfigurationTask
        warmRunnerConfigurationTask = nil
        pendingWarmRunnerConfiguration = nil
        configurationTask?.cancel()
        await configurationTask?.value

        syncTask?.cancel()
        syncTask = nil
        for task in completionMonitorTasks.values {
            task.cancel()
        }
        completionMonitorTasks.removeAll()
        for task in warmRunnerIdleReleaseTasks.values { task.cancel() }
        warmRunnerIdleReleaseTasks.removeAll()
        warmRunnerIdleShutdownDates.removeAll()
        pinnedWarmRunnerPoolIDs.removeAll()

        if let queueEngine {
            await queueEngine.stop()
        }
        queueViewModel.stopPolling()

        for engine in vmEngines.values where engine.isRunning {
            do {
                try await engine.teardown()
            } catch {
                Log.app.error("Failed to teardown VM on stop: \(error.localizedDescription)")
            }
        }

        if let controlVMEngine, controlVMEngine.isRunning {
            try? await controlVMEngine.teardown()
        }

        clearVMStatus()
        stopVMControlServer()
        controlVMEngine = nil

        githubEngine = nil
        queueEngine = nil
        vmEngine = nil
        vmEngines.removeAll()
        runnerPools.removeAll()
        activeJobPoolIDs.removeAll()

        Log.app.info("App stopped")
    }

    func shutdownForTermination() async {
        await stop()
    }

    func syncVMControlServer() {
        guard configStore.vmControlConfiguration.isEnabled else {
            stopVMControlServer()
            return
        }

        guard configStore.hasCompletedStorageSetup else {
            stopVMControlServer()
            return
        }

        var configuration = configStore.vmControlConfiguration
        let previousToken = configuration.authToken
        configuration.ensureAuthToken()
        if configuration.authToken != previousToken {
            configStore.vmControlConfiguration = configuration
            configStore.save()
        }

        stopVMControlServer()

        let handler = makeVMControlHandler()
        vmControlHandler = handler
        let server = LocalVMControlHTTPServer(configuration: configuration, handler: handler)
        vmControlServer = server

        do {
            try server.start()
        } catch {
            Log.vmControl.error("Failed to start VM control server: \(error.localizedDescription)")
            stopVMControlServer()
        }
    }

    private func stopVMControlServer() {
        vmControlServer?.stop()
        vmControlServer = nil
        vmControlHandler = nil
    }

    private func makeVMControlHandler() -> VMControlHandler {
        VMControlHandler(
            engineProvider: { [weak self] in self?.engineForVMControl() },
            vmConfiguration: { [weak self] in self?.configStore.vmConfiguration ?? VMConfiguration() },
            storageRootPath: { [weak self] in self?.configStore.storageRootPath ?? "" },
            baseImagePath: { [weak self] in self?.configStore.resolvedBaseImagePath ?? "" },
            platformDirectoryPath: { [weak self] in self?.configStore.platformDirectoryPath ?? "" },
            cacheConfig: { [weak self] in self?.configStore.cacheConfig ?? CacheConfiguration() },
            diagnosticsRetention: { [weak self] in
                self?.configStore.diagnosticsRetentionConfig ?? DiagnosticsRetentionConfiguration()
            },
            hasActiveRunnerJob: { [weak self] in
                self?.queueViewModel.activeJob != nil
            }
        )
    }

    private func engineForVMControl() -> VMEngine? {
        if let vmEngine {
            return vmEngine
        }

        guard configStore.hasCompletedStorageSetup else { return nil }

        if controlVMEngine == nil {
            controlVMEngine = vmEngineFactory(
                configStore.storageRootPath,
                configStore.resolvedBaseImagePath,
                configStore.platformDirectoryPath,
                configStore.cacheConfig,
                configStore.diagnosticsRetentionConfig
            )
        }

        return controlVMEngine
    }

    func restart() async {
        await stop()
        await start()
    }

    private func configureSettingsCallbacks() {
        settingsViewModel.onWarmRunnerConfigurationChanged = { [weak self] configuration in
            self?.warmRunnerConfigurationDidChange(configuration)
        }
    }

    private func warmRunnerConfigurationDidChange(_ configuration: WarmRunnerConfiguration) {
        for engine in vmEngines.values { engine.updateWarmRunnerConfig(configuration) }
        controlVMEngine?.updateWarmRunnerConfig(configuration)
        pendingWarmRunnerConfiguration = configuration

        guard queueEngine != nil, warmRunnerConfigurationTask == nil else { return }
        warmRunnerConfigurationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let configuration = self.pendingWarmRunnerConfiguration {
                self.pendingWarmRunnerConfiguration = nil
                await self.reconcileWarmRunnerConfiguration(configuration)
            }
            self.warmRunnerConfigurationTask = nil
        }
    }

    private func reconcileWarmRunnerConfiguration(_ configuration: WarmRunnerConfiguration) async {
        guard !vmEngines.isEmpty, let queueEngine else { return }

        for engine in vmEngines.values { engine.updateWarmRunnerConfig(configuration) }

        let hasActiveJob = await queueEngine.jobStore.activeJob != nil
        if configuration.isEnabled {
            guard !hasActiveJob else { return }
            for (poolID, engine) in vmEngines where runnerPools[poolID]?.keepsWarmRunner == true {
                if engine.hasWarmRunner {
                    scheduleWarmRunnerIdleRelease(using: engine)
                } else if engine.currentInstance == nil {
                    _ = await prewarmRunnerIfNeeded(using: engine)
                }
            }
            syncAllVMStatus()
        } else {
            guard !hasActiveJob else { return }
            for engine in vmEngines.values where engine.warmRunnerState != nil {
                beginIdleVMControl(.shuttingDown, using: engine)
                do {
                    try await engine.releaseWarmRunner()
                } catch {
                    vmStatusViewModel.idleVMControlErrorMessage = error.localizedDescription
                    Log.app.error("Failed to disable warm runner: \(error.localizedDescription)")
                }
            }
            vmStatusViewModel.idleVMControlOperation = nil
            clearVMStatus()
        }
    }

    @discardableResult
    private func prewarmRunnerIfNeeded(using vmEngine: VMEngine) async -> Bool {
        let warmConfiguration = configStore.warmRunnerConfig
        vmEngine.updateWarmRunnerConfig(warmConfiguration)
        guard warmConfiguration.isEnabled else { return false }
        guard vmEngine.currentInstance == nil else { return vmEngine.hasWarmRunner }

        let pool = poolConfiguration(for: vmEngine)
        let vmConfiguration = pool?.imageProfile.resolvedVMConfiguration(
            defaultConfiguration: configStore.vmConfiguration
        ) ?? configStore.vmConfiguration
        let baseImagePath = pool?.resolvedBaseImagePath(
            defaultPath: configStore.resolvedBaseImagePath
        ) ?? configStore.resolvedBaseImagePath

        beginIdleVMControl(.starting, using: vmEngine)
        do {
            try await vmEngine.prewarm(
                config: vmConfiguration,
                baseImagePath: baseImagePath
            )

            guard configStore.warmRunnerConfig.isEnabled else {
                try await vmEngine.releaseWarmRunner()
                clearVMStatus()
                return false
            }

            vmStatusViewModel.idleVMControlOperation = nil
            scheduleWarmRunnerIdleRelease(using: vmEngine)
            syncVMStatus(from: vmEngine, role: .warmRunnerIdle)
            Log.app.info("Prewarmed runner VM is ready before queue polling")
            return true
        } catch is CancellationError {
            vmStatusViewModel.idleVMControlOperation = nil
            return false
        } catch {
            vmStatusViewModel.idleVMControlOperation = nil
            vmStatusViewModel.idleVMControlErrorMessage = error.localizedDescription
            Log.app.error("Warm runner prewarm failed; continuing with cold job starts: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Job Handling

    private func handleJobReady(_ job: RunnerJob) async {
        await waitForIdleVMControl()
        guard githubEngine != nil, let queueEngine else { return }
        var dispatchVMEngine: VMEngine?

        do {
            let org = configStore.organizations.first {
                if let accountID = job.accountID { return $0.id == accountID }
                return $0.name == job.organizationName
            }
            guard let org else {
                let reason = "No account found for job organization \(job.organizationName)."
                Log.app.error("\(reason)")
                await queueEngine.jobStore.updateJob(id: job.id, status: .failed, failureReason: reason)
                queueViewModel.updateJobStatus(id: job.id, status: .failed, failureReason: reason)
                await queueEngine.tryDispatch()
                return
            }
            guard let pool = org.runnerPool(id: job.runnerPoolID)
                ?? org.runnerPool(matching: job.requestedLabels)
            else {
                throw RunnerPoolDispatchError.noMatchingPool(labels: job.requestedLabels)
            }
            guard let vmEngine = vmEngines[pool.id] else {
                throw RunnerPoolDispatchError.poolUnavailable(name: pool.displayName)
            }
            dispatchVMEngine = vmEngine
            self.vmEngine = vmEngine
            activeJobPoolIDs[job.id] = pool.id
            let runtimeOrg = org.runtimeAccount(for: pool)

            refreshReadiness()
            guard vmStatusViewModel.readyForJobs else {
                let reason = "Pre-flight readiness failed: \(vmStatusViewModel.readinessStatusText)"
                Log.app.warning("Job \(job.id) refused before VM provisioning: \(reason)")
                await queueEngine.jobStore.updateJob(id: job.id, status: .failed, failureReason: reason)
                queueViewModel.updateJobStatus(id: job.id, status: .failed, failureReason: reason)
                await queueEngine.tryDispatch()
                return
            }

            warmRunnerIdleReleaseTasks[pool.id]?.cancel()
            warmRunnerIdleReleaseTasks[pool.id] = nil
            warmRunnerIdleShutdownDates[pool.id] = nil
            if vmEngine.warmRunnerState != nil {
                syncVMStatus(from: vmEngine, role: .warmRunnerActive)
            }

            // Update status to provisioning
            queueViewModel.updateJobStatus(id: job.id, status: .provisioning)

            let runnerName = "tarmac-\(runtimeOrg.provider.rawValue)-\(job.id)"
            let preparedRunner = try await queueEngine.prepareRunner(
                for: job,
                account: runtimeOrg,
                runnerName: runnerName
            )
            var lease = RunnerLease(
                job: job,
                runnerName: runnerName,
                labels: runtimeOrg.provider == .gitea ? runtimeOrg.giteaRunnerLabels : runtimeOrg.runnerLabels,
                provider: runtimeOrg.provider == .gitea ? .gitea : .github
            )
            await queueEngine.runnerLeaseStore.upsert(lease)
            await queueEngine.jobStore.updateRunnerLease(jobId: job.id, lease: lease)

            // Update job with runner config in the store
            await queueEngine.jobStore.updateJob(id: job.id, status: .running)

            // Provision and boot VM
            var runnableJob = job
            runnableJob.applyRunnerGuestConfig(preparedRunner.guestConfig)
            runnableJob.runnerName = runnerName
            runnableJob.runnerLease = lease
            runnableJob.status = .running
            let runnerVMConfiguration = pool.imageProfile.resolvedVMConfiguration(
                defaultConfiguration: configStore.vmConfiguration
            )
            let signingInjection = try appleSigningInjection(for: runnableJob, organization: org)
            let instance = try await vmEngine.provisionAndRun(
                job: runnableJob,
                config: runnerVMConfiguration,
                runnerPath: preparedRunner.runnerPath,
                baseImagePath: pool.resolvedBaseImagePath(defaultPath: configStore.resolvedBaseImagePath),
                signingInjection: signingInjection
            )
            let sharedDirectoryPath = StorageManager(
                rootPath: pool.runtimeStorageRootPath(storageRootPath: configStore.storageRootPath)
            )
                .jobsDirectory
                .appendingPathComponent("\(job.id)", isDirectory: true)
                .path
            if let startedLease = await queueEngine.runnerLeaseStore.recordVMStarted(
                jobId: job.id,
                vmInstanceId: instance.id,
                diskImagePath: instance.diskImagePath.path,
                sharedDirectoryPath: sharedDirectoryPath
            ) {
                lease = startedLease
                await queueEngine.jobStore.updateRunnerLease(jobId: job.id, lease: lease)
            }
            await queueEngine.jobStore.updateVMInstance(jobId: job.id, vmInstanceId: instance.id)

            if runtimeOrg.provider == .gitea {
                guard let claimed = try await queueEngine.waitForProviderClaim(
                    jobID: job.id,
                    account: runtimeOrg,
                    runnerName: runnerName
                ) else {
                    throw ProviderDispatchError.claimTimedOut(runnerName)
                }
                Log.gitea.info(
                    "Runner claim correlated account=\(runtimeOrg.id.uuidString, privacy: .public) remote_job=\(claimed.key.remoteJobID, privacy: .public) runner=\(runnerName, privacy: .public)"
                )
            }

            queueViewModel.updateJobStatus(id: job.id, status: .running)
            syncVMStatus(from: vmEngine, role: vmEngine.warmRunnerState == nil ? .jobRunner : .warmRunnerActive)

            Log.app.info("Job \(job.id) is running in VM")
            startCompletionMonitor(
                for: job.id,
                timeoutSeconds: runnerVMConfiguration.runnerCompletionTimeoutSeconds,
                vmEngine: vmEngine,
                queueEngine: queueEngine
            )
        } catch {
            let reason = error.localizedDescription
            Log.app.error("Failed to provision job \(job.id): \(reason)")
            if let failedLease = await queueEngine.runnerLeaseStore.recordCleanupState(jobId: job.id, state: .failed) {
                await queueEngine.jobStore.updateRunnerLease(jobId: job.id, lease: failedLease)
            }
            await queueEngine.jobStore.updateJob(id: job.id, status: .failed, failureReason: reason)
            queueViewModel.updateJobStatus(id: job.id, status: .failed, failureReason: reason)
            if let diagnosticsPath = dispatchVMEngine?.diagnosticsBundlePath(for: job.id)?.path {
                if let lease = await queueEngine.runnerLeaseStore.recordDiagnosticsBundle(
                    jobId: job.id,
                    path: diagnosticsPath
                ) {
                    await queueEngine.jobStore.updateRunnerLease(jobId: job.id, lease: lease)
                }
                await queueEngine.jobStore.updateDiagnosticsBundle(jobId: job.id, path: diagnosticsPath)
            }

            // Teardown on failure
            if let vmEngine = dispatchVMEngine, vmEngine.currentInstance != nil {
                try? await vmEngine.teardown(outcome: .failed(reason: error.localizedDescription))
                if let diagnosticsPath = vmEngine.diagnosticsBundlePath(for: job.id)?.path {
                    if let lease = await queueEngine.runnerLeaseStore.recordDiagnosticsBundle(
                        jobId: job.id,
                        path: diagnosticsPath
                    ) {
                        await queueEngine.jobStore.updateRunnerLease(jobId: job.id, lease: lease)
                    }
                    await queueEngine.jobStore.updateDiagnosticsBundle(jobId: job.id, path: diagnosticsPath)
                }
                clearVMStatus()
            }
            if let account = configStore.organizations.first(where: { $0.id == job.accountID }),
                account.provider == .gitea,
                shouldRetryUnclaimedDemand(after: error)
            {
                await queueEngine.releaseProviderDemand(
                    job: job,
                    account: account,
                    diagnosticsPath: dispatchVMEngine?.diagnosticsBundlePath(for: job.id)?.path
                )
            }
            activeJobPoolIDs[job.id] = nil
            await queueEngine.tryDispatch()
        }
    }

    private func shouldRetryUnclaimedDemand(after error: Error) -> Bool {
        if error is ProviderDispatchError { return true }
        guard let giteaError = error as? GiteaAPIError else { return false }
        switch giteaError {
        case .ambiguousClaim, .jobCancelledBeforeClaim:
            return true
        default:
            return false
        }
    }

    func appleSigningInjection(
        for job: RunnerJob,
        organization: Organization
    ) throws -> AppleSigningInjection? {
        try configStore.loadAppleSigningInjection(for: job, organization: organization)
    }

    private func startCompletionMonitor(
        for jobId: Int64,
        timeoutSeconds: Int,
        vmEngine: VMEngine,
        queueEngine: QueueEngine
    ) {
        completionMonitorTasks[jobId]?.cancel()
        completionMonitorTasks[jobId] = Task { [weak self] in
            guard let self else { return }

            do {
                let result = try await vmEngine.waitForJobCompletion(
                    jobId: jobId,
                    timeoutSeconds: timeoutSeconds
                )
                guard !Task.isCancelled else { return }
                let reconciledResult: JobResult
                if let job = await queueEngine.jobStore.job(byId: jobId),
                    let account = self.configStore.organizations.first(where: { $0.id == job.accountID })
                {
                    reconciledResult = await queueEngine.reconciledResult(
                        for: job,
                        account: account,
                        fallback: result
                    )
                } else {
                    reconciledResult = result
                }
                await queueEngine.completeJobFromGuest(jobId: jobId, result: reconciledResult)
            } catch is CancellationError {
                Log.app.debug("Completion monitor cancelled for job \(jobId)")
            } catch {
                await queueEngine.completeJobFromGuest(jobId: jobId, result: .failure(error.localizedDescription))
            }

            self.completionMonitorTasks[jobId] = nil
        }
    }

    private func handleJobCompleted(
        _ job: RunnerJob,
        result: JobResult,
        source: JobCompletionSource
    ) async {
        let poolID = activeJobPoolIDs[job.id] ?? job.runnerPoolID
        let completedEngine = poolID.flatMap { vmEngines[$0] }
            ?? vmEngines.values.first { $0.currentInstance?.jobId == job.id }
        guard let vmEngine = completedEngine, let queueEngine else { return }
        guard vmEngine.currentInstance?.jobId == job.id else { return }
        if source == .github {
            completionMonitorTasks[job.id]?.cancel()
            completionMonitorTasks[job.id] = nil
        }

        let outcome: JobDiagnosticsOutcome =
            switch result {
            case .success:
                .succeeded
            case .failure(let reason):
                .failed(reason: reason)
            }

        let keepsWarmRunner = poolID.flatMap { runnerPools[$0]?.keepsWarmRunner } ?? true
        let teardownPolicy: VMTeardownPolicy =
            configStore.warmRunnerConfig.isEnabled && keepsWarmRunner ? .keepWarmRunner : .full

        do {
            try await vmEngine.teardown(outcome: outcome, policy: teardownPolicy)
        } catch {
            Log.app.error("Failed to teardown completed job \(job.id): \(error.localizedDescription)")
        }

        if teardownPolicy == .keepWarmRunner, vmEngine.hasWarmRunner {
            scheduleWarmRunnerIdleRelease(using: vmEngine)
            syncVMStatus(from: vmEngine, role: .warmRunnerIdle)
        } else if let poolID {
            warmRunnerIdleReleaseTasks[poolID]?.cancel()
            warmRunnerIdleReleaseTasks[poolID] = nil
            warmRunnerIdleShutdownDates[poolID] = nil
        }

        let diagnosticsPath = vmEngine.diagnosticsBundlePath(for: job.id)?.path
        if let completedLease = await queueEngine.runnerLeaseStore.completeAndRemove(
            jobId: job.id,
            diagnosticsPath: diagnosticsPath
        ) {
            await queueEngine.jobStore.updateRunnerLease(jobId: job.id, lease: completedLease)
        }
        if let diagnosticsPath {
            await queueEngine.jobStore.updateDiagnosticsBundle(jobId: job.id, path: diagnosticsPath)
        }
        let failureReason: String? =
            if case .failure(let reason) = result {
                reason
            } else {
                nil
            }
        queueViewModel.updateJobStatus(id: job.id, status: result.jobStatus, failureReason: failureReason)
        if !vmEngine.hasWarmRunner {
            clearVMStatus()
        } else {
            syncVMStatus(from: vmEngine, role: .warmRunnerIdle)
        }
        completionMonitorTasks[job.id] = nil
        activeJobPoolIDs[job.id] = nil
    }

    private func scheduleWarmRunnerIdleRelease(using vmEngine: VMEngine) {
        guard let poolID = poolID(for: vmEngine) else { return }
        warmRunnerIdleReleaseTasks[poolID]?.cancel()
        warmRunnerIdleReleaseTasks[poolID] = nil
        guard !pinnedWarmRunnerPoolIDs.contains(poolID) else {
            warmRunnerIdleShutdownDates[poolID] = nil
            syncAllVMStatus()
            return
        }

        let idleSeconds =
            warmRunnerIdleShutdownSecondsOverride
            ?? configStore.warmRunnerConfig.normalizedIdleShutdownSeconds
        warmRunnerIdleShutdownDates[poolID] = Date().addingTimeInterval(TimeInterval(idleSeconds))
        warmRunnerIdleReleaseTasks[poolID] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(idleSeconds))
            } catch {
                return
            }
            guard let self, self.vmEngines[poolID] === vmEngine else { return }
            guard !self.pinnedWarmRunnerPoolIDs.contains(poolID) else {
                self.warmRunnerIdleReleaseTasks[poolID] = nil
                self.warmRunnerIdleShutdownDates[poolID] = nil
                self.syncAllVMStatus()
                return
            }
            guard vmEngine.warmRunnerState != nil else {
                self.warmRunnerIdleReleaseTasks[poolID] = nil
                self.warmRunnerIdleShutdownDates[poolID] = nil
                return
            }
            guard await self.queueEngine?.jobStore.activeJob == nil else {
                self.warmRunnerIdleReleaseTasks[poolID] = nil
                self.warmRunnerIdleShutdownDates[poolID] = nil
                return
            }
            guard self.vmStatusViewModel.idleVMControlOperation == nil else {
                self.warmRunnerIdleReleaseTasks[poolID] = nil
                self.warmRunnerIdleShutdownDates[poolID] = nil
                return
            }

            Log.app.info("Releasing warm runner after \(idleSeconds)s idle")
            self.warmRunnerIdleReleaseTasks[poolID] = nil
            self.warmRunnerIdleShutdownDates[poolID] = nil
            self.vmStatusViewModel.idleVMControlOperation = .shuttingDown
            do {
                try await vmEngine.releaseWarmRunner()
                self.clearVMStatus()
            } catch {
                Log.app.error("Failed to release idle warm runner: \(error.localizedDescription)")
                self.vmStatusViewModel.idleVMControlErrorMessage = error.localizedDescription
                self.vmStatusViewModel.idleVMControlOperation = nil
                if vmEngine.warmRunnerState != nil {
                    self.syncVMStatus(from: vmEngine, role: .warmRunnerIdle)
                    self.scheduleWarmRunnerIdleRelease(using: vmEngine)
                }
            }
        }
        syncAllVMStatus()
    }

    func keepIdleWarmRunnerAlive(workerID: UUID? = nil) {
        guard let context = warmRunnerContext(workerID: workerID),
            context.engine.warmRunnerState != nil,
            queueViewModel.activeJob == nil
        else { return }

        vmEngine = context.engine
        warmRunnerIdleReleaseTasks[context.poolID]?.cancel()
        warmRunnerIdleReleaseTasks[context.poolID] = nil
        warmRunnerIdleShutdownDates[context.poolID] = nil
        pinnedWarmRunnerPoolIDs.insert(context.poolID)
        vmStatusViewModel.isWarmRunnerPinned = true
        vmStatusViewModel.idleVMControlErrorMessage = nil
        syncAllVMStatus()
        Log.app.info("Idle warm runner pinned until automatic shutdown is resumed")
    }

    func resumeIdleWarmRunnerAutomaticShutdown(workerID: UUID? = nil) {
        guard let context = warmRunnerContext(workerID: workerID),
            context.engine.warmRunnerState != nil,
            queueViewModel.activeJob == nil
        else { return }

        vmEngine = context.engine
        pinnedWarmRunnerPoolIDs.remove(context.poolID)
        vmStatusViewModel.isWarmRunnerPinned = false
        vmStatusViewModel.idleVMControlErrorMessage = nil
        scheduleWarmRunnerIdleRelease(using: context.engine)
        Log.app.info("Automatic idle warm runner shutdown resumed")
    }

    func restartIdleWarmRunner(workerID: UUID? = nil) async {
        guard let context = warmRunnerContext(workerID: workerID),
            await canBeginIdleVMControl(using: context.engine)
        else { return }
        let vmEngine = context.engine
        self.vmEngine = vmEngine

        let remainsPinned = pinnedWarmRunnerPoolIDs.contains(context.poolID)
        beginIdleVMControl(.restarting, using: vmEngine)

        do {
            try await vmEngine.restartWarmRunner()
        } catch {
            Log.app.error("Failed to restart idle warm runner: \(error.localizedDescription)")
            vmStatusViewModel.idleVMControlErrorMessage = error.localizedDescription
        }

        let hasWaitingJob = await queueEngine?.jobStore.activeJob != nil
        if vmEngine.warmRunnerState != nil {
            syncVMStatus(from: vmEngine, role: hasWaitingJob ? .warmRunnerActive : .warmRunnerIdle)
        } else {
            clearVMStatus()
        }
        vmStatusViewModel.idleVMControlOperation = nil

        if !remainsPinned, !hasWaitingJob, vmEngine.warmRunnerState != nil {
            scheduleWarmRunnerIdleRelease(using: vmEngine)
        }
    }

    func shutDownIdleWarmRunner(workerID: UUID? = nil) async {
        guard let context = warmRunnerContext(workerID: workerID),
            await canBeginIdleVMControl(using: context.engine)
        else { return }
        let vmEngine = context.engine
        self.vmEngine = vmEngine

        let wasPinned = pinnedWarmRunnerPoolIDs.contains(context.poolID)
        beginIdleVMControl(.shuttingDown, using: vmEngine)

        do {
            try await vmEngine.releaseWarmRunner()
            pinnedWarmRunnerPoolIDs.remove(context.poolID)
            clearVMStatus()
        } catch {
            Log.app.error("Failed to shut down idle warm runner: \(error.localizedDescription)")
            vmStatusViewModel.idleVMControlErrorMessage = error.localizedDescription
            vmStatusViewModel.idleVMControlOperation = nil
            vmStatusViewModel.isWarmRunnerPinned = wasPinned

            let hasWaitingJob = await queueEngine?.jobStore.activeJob != nil
            if vmEngine.warmRunnerState != nil {
                syncVMStatus(from: vmEngine, role: hasWaitingJob ? .warmRunnerActive : .warmRunnerIdle)
                if !wasPinned, !hasWaitingJob {
                    scheduleWarmRunnerIdleRelease(using: vmEngine)
                }
            }
        }
    }

    private func beginIdleVMControl(_ operation: IdleVMControlOperation, using vmEngine: VMEngine? = nil) {
        if let vmEngine, let poolID = poolID(for: vmEngine) {
            warmRunnerIdleReleaseTasks[poolID]?.cancel()
            warmRunnerIdleReleaseTasks[poolID] = nil
            warmRunnerIdleShutdownDates[poolID] = nil
        }
        vmStatusViewModel.idleVMControlErrorMessage = nil
        vmStatusViewModel.idleVMControlOperation = operation
    }

    private func canBeginIdleVMControl(using vmEngine: VMEngine) async -> Bool {
        guard vmEngine.warmRunnerState != nil,
            vmStatusViewModel.idleVMControlOperation == nil,
            queueViewModel.activeJob == nil,
            let queueEngine
        else { return false }

        return await queueEngine.jobStore.activeJob == nil
    }

    private func poolID(for vmEngine: VMEngine) -> UUID? {
        vmEngines.first { $0.value === vmEngine }?.key
    }

    private func poolConfiguration(for vmEngine: VMEngine) -> RunnerPoolConfiguration? {
        poolID(for: vmEngine).flatMap { runnerPools[$0] }
    }

    private func warmRunnerContext(workerID: UUID?) -> (poolID: UUID, engine: VMEngine)? {
        if let workerID,
            let match = vmEngines.first(where: { $0.value.currentInstance?.id == workerID })
        {
            return (match.key, match.value)
        }
        if let vmEngine, let poolID = poolID(for: vmEngine), vmEngine.warmRunnerState != nil {
            return (poolID, vmEngine)
        }
        guard let match = vmEngines.first(where: { $0.value.warmRunnerState != nil }) else { return nil }
        return (match.key, match.value)
    }

    private func waitForIdleVMControl() async {
        while vmStatusViewModel.idleVMControlOperation != nil {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Job Store Sync

    private func startJobStoreSync() {
        guard let queueEngine else { return }

        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let jobs = await queueEngine.jobStore.jobs
                self.queueViewModel.allJobs = jobs
                for account in self.configStore.organizations {
                    let pollingState = await queueEngine.pollingState(for: account)
                    self.settingsViewModel.updatePollingState(pollingState, for: account)
                }

                self.syncAllVMStatus()
                self.vmStatusViewModel.baseImageExists = self.vmEngines.values.contains(where: \.baseImageExists)
                self.vmStatusViewModel.baseImageVerified = self.vmEngines.values.contains(where: \.baseImageVerified)
                self.refreshReadiness()

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refreshReadiness(performCloneProbe: Bool = true) {
        settingsViewModel.refreshStorageHealth(performCloneProbe: performCloneProbe)
        let storage = StorageManager(rootPath: configStore.storageRootPath)
        vmStatusViewModel.storageHealth = settingsViewModel.storageHealth
        vmStatusViewModel.baseImageExists = FileManager.default.fileExists(atPath: configStore.resolvedBaseImagePath)
        vmStatusViewModel.baseImageVerified = storage.isBaseImageVerified()
        vmStatusViewModel.readiness = RunnerHostReadiness.evaluate(
            configStore: configStore,
            storageHealth: settingsViewModel.storageHealth
        )
    }

    func refreshWorkers() {
        if !vmEngines.isEmpty {
            syncAllVMStatus()
        } else if let engine = controlVMEngine {
            syncVMStatus(from: engine)
        } else {
            vmStatusViewModel.workers = []
        }
    }

    private func syncVMStatus(from vmEngine: VMEngine, role forcedRole: ActiveVMRole? = nil) {
        self.vmEngine = vmEngine
        if let poolID = poolID(for: vmEngine), let forcedRole {
            syncAllVMStatus(forcedRoles: [poolID: forcedRole])
            return
        }
        if vmEngines.isEmpty {
            syncStandaloneVMStatus(from: vmEngine, role: forcedRole)
        } else {
            syncAllVMStatus()
        }
    }

    private func syncAllVMStatus(forcedRoles: [UUID: ActiveVMRole] = [:]) {
        var workers: [WorkerSnapshot] = []
        var roles: [UUID: ActiveVMRole] = [:]

        for (poolID, engine) in vmEngines {
            guard let instance = engine.currentInstance else { continue }
            let matchingJob = instance.jobId.flatMap { jobId in
                queueViewModel.allJobs.first { $0.id == jobId }
            }
            let role: ActiveVMRole
            if let forcedRole = forcedRoles[poolID] {
                role = forcedRole
            } else if engine.warmRunnerState != nil {
                role = instance.jobId.map { queueViewModel.activeJob?.id == $0 } == true
                    ? .warmRunnerActive
                    : .warmRunnerIdle
            } else {
                role = instance.jobId == VMControlHandler.controlJobId ? .manualControl : .jobRunner
            }
            roles[poolID] = role

            let warmState = engine.warmRunnerState
            let pool = runnerPools[poolID]
            workers.append(
                WorkerSnapshot(
                    id: instance.id,
                    runnerPoolID: poolID,
                    runnerPoolName: pool?.displayName,
                    releaseChannel: pool?.releaseChannel,
                    routingLabels: pool?.advertisedLabels ?? [],
                    kind: role == .manualControl ? .manualControl : .githubRunner,
                    lifecycleState: workerLifecycleState(for: instance.state, role: role),
                    vmState: instance.state,
                    jobId: instance.jobId,
                    diskImagePath: instance.diskImagePath,
                    startedAt: instance.startedAt,
                    configuration: engine.currentVMConfiguration ?? configStore.vmConfiguration,
                    task: matchingJob.map(WorkerTaskSummary.init),
                    resourceUsage: engine.currentResourceUsage(),
                    diskImageAllocatedBytes: engine.currentDiskImageAllocatedSizeBytes(),
                    warmRunnerJobsServed: warmState?.jobsServed,
                    warmRunnerLastActivityAt: warmState?.lastActivityAt,
                    automaticShutdownAt: warmRunnerIdleShutdownDates[poolID],
                    isPinned: pinnedWarmRunnerPoolIDs.contains(poolID)
                )
            )
        }

        workers.sort {
            let lhsChannel = $0.releaseChannel == .appStore ? 0 : ($0.releaseChannel == .beta ? 1 : 2)
            let rhsChannel = $1.releaseChannel == .appStore ? 0 : ($1.releaseChannel == .beta ? 1 : 2)
            if lhsChannel != rhsChannel { return lhsChannel < rhsChannel }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        vmStatusViewModel.workers = workers

        let selectedEngine: VMEngine? = {
            if let vmEngine, vmEngine.currentInstance != nil { return vmEngine }
            guard let firstPoolID = workers.first?.runnerPoolID else { return nil }
            return vmEngines[firstPoolID]
        }()
        vmEngine = selectedEngine ?? vmEngine
        vmStatusViewModel.activeVM = selectedEngine?.currentInstance
        if let selectedEngine, let selectedPoolID = poolID(for: selectedEngine) {
            let selectedWarmState = selectedEngine.warmRunnerState
            vmStatusViewModel.activeVMRole = roles[selectedPoolID]
            vmStatusViewModel.warmRunnerJobsServed = selectedWarmState?.jobsServed
            vmStatusViewModel.warmRunnerLastActivityAt = selectedWarmState?.lastActivityAt
            vmStatusViewModel.warmRunnerIdleShutdownAt = warmRunnerIdleShutdownDates[selectedPoolID]
            vmStatusViewModel.isWarmRunnerPinned = pinnedWarmRunnerPoolIDs.contains(selectedPoolID)
        } else {
            vmStatusViewModel.activeVMRole = nil
            vmStatusViewModel.warmRunnerJobsServed = nil
            vmStatusViewModel.warmRunnerLastActivityAt = nil
            vmStatusViewModel.warmRunnerIdleShutdownAt = nil
            vmStatusViewModel.isWarmRunnerPinned = false
        }
    }

    private func syncStandaloneVMStatus(from vmEngine: VMEngine, role forcedRole: ActiveVMRole?) {
        guard let instance = vmEngine.currentInstance else {
            vmStatusViewModel.workers = []
            vmStatusViewModel.activeVM = nil
            vmStatusViewModel.activeVMRole = nil
            return
        }
        let role = forcedRole ?? (instance.jobId == VMControlHandler.controlJobId ? .manualControl : .jobRunner)
        vmStatusViewModel.activeVM = instance
        vmStatusViewModel.activeVMRole = role
        vmStatusViewModel.workers = [
            WorkerSnapshot(
                id: instance.id,
                kind: role == .manualControl ? .manualControl : .githubRunner,
                lifecycleState: workerLifecycleState(for: instance.state, role: role),
                vmState: instance.state,
                jobId: instance.jobId,
                diskImagePath: instance.diskImagePath,
                startedAt: instance.startedAt,
                configuration: vmEngine.currentVMConfiguration ?? configStore.vmConfiguration,
                task: nil,
                resourceUsage: vmEngine.currentResourceUsage(),
                diskImageAllocatedBytes: vmEngine.currentDiskImageAllocatedSizeBytes(),
                warmRunnerJobsServed: nil,
                warmRunnerLastActivityAt: nil,
                automaticShutdownAt: nil,
                isPinned: false
            )
        ]
    }

    private func workerLifecycleState(
        for vmState: VMInstance.VMState,
        role: ActiveVMRole
    ) -> WorkerLifecycleState {
        switch vmState {
        case .booting:
            .starting
        case .running:
            switch role {
            case .jobRunner, .warmRunnerActive:
                .working
            case .warmRunnerIdle:
                .warmIdle
            case .manualControl:
                .running
            }
        case .stopping:
            .stopping
        case .stopped:
            .stopped
        case .failed:
            .failed
        }
    }

    private func clearVMStatus() {
        if vmEngines.values.contains(where: { $0.currentInstance != nil }) {
            syncAllVMStatus()
            vmStatusViewModel.idleVMControlOperation = nil
            return
        }
        vmStatusViewModel.workers = []
        vmStatusViewModel.activeVM = nil
        vmStatusViewModel.activeVMRole = nil
        vmStatusViewModel.warmRunnerJobsServed = nil
        vmStatusViewModel.warmRunnerLastActivityAt = nil
        vmStatusViewModel.warmRunnerIdleShutdownAt = nil
        vmStatusViewModel.isWarmRunnerPinned = false
        vmStatusViewModel.idleVMControlOperation = nil
        vmStatusViewModel.idleVMControlErrorMessage = nil
    }
}

enum ProviderDispatchError: LocalizedError {
    case claimTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .claimTimedOut(let runnerName):
            "Gitea did not assign a job to runner \(runnerName) before the claim timeout."
        }
    }
}

enum RunnerPoolDispatchError: LocalizedError {
    case noMatchingPool(labels: [String])
    case poolUnavailable(name: String)

    var errorDescription: String? {
        switch self {
        case .noMatchingPool(let labels):
            "No enabled runner pool matches the requested labels: \(labels.joined(separator: ", "))"
        case .poolUnavailable(let name):
            "Runner pool \(name) is not available because its base image is not ready"
        }
    }
}
