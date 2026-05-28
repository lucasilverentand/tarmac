import Foundation

enum AppSection: String, Identifiable, CaseIterable, Hashable {
    case queue
    case virtualMachine
    case organizations
    case cache
    case storage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .queue: "Queue"
        case .virtualMachine: "Virtual Machine"
        case .organizations: "Accounts"
        case .cache: "Cache & Diagnostics"
        case .storage: "Storage"
        }
    }

    var systemImage: String {
        switch self {
        case .queue: "tray.full"
        case .virtualMachine: "desktopcomputer"
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
    private var syncTask: Task<Void, Never>?
    private var completionMonitorTasks: [Int64: Task<Void, Never>] = [:]
    private var warmRunnerIdleReleaseTask: Task<Void, Never>?

    private let githubClientFactory: () -> any GitHubClientProtocol
    private let vmEngineFactory:
        (String, String, String, CacheConfiguration, DiagnosticsRetentionConfiguration) -> VMEngine

    init() {
        let configStore = ConfigStore()
        self.configStore = configStore
        self.queueViewModel = QueueViewModel()
        self.vmStatusViewModel = VMStatusViewModel()
        self.settingsViewModel = SettingsViewModel(configStore: configStore)
        self.githubClientFactory = { GitHubClient() }
        self.vmEngineFactory = { cachePath, basePath, platformPath, cacheConfig, diagnosticsRetention in
            VMEngine(
                cacheDirectoryPath: cachePath,
                baseImagePath: basePath,
                platformDirectoryPath: platformPath,
                cacheConfig: cacheConfig,
                diagnosticsRetention: diagnosticsRetention
            )
        }
        refreshReadiness()
    }

    init(
        configStore: ConfigStore,
        githubClientFactory: @escaping () -> any GitHubClientProtocol = { GitHubClient() },
        vmEngineFactory:
            @escaping (String, String, String, CacheConfiguration, DiagnosticsRetentionConfiguration) -> VMEngine = {
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
            }
    ) {
        self.configStore = configStore
        self.queueViewModel = QueueViewModel()
        self.vmStatusViewModel = VMStatusViewModel()
        self.settingsViewModel = SettingsViewModel(configStore: configStore)
        self.githubClientFactory = githubClientFactory
        self.vmEngineFactory = vmEngineFactory
        refreshReadiness()
    }

    // MARK: - Engine Lifecycle

    func start() async {
        guard queueEngine == nil else {
            Log.app.debug("Start ignored because app is already running")
            return
        }

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
        let setupIssues = setupResults.flatMap(\.readinessIssues)
        guard setupIssues.isEmpty else {
            var readiness = vmStatusViewModel.readiness
            readiness.issues.append(contentsOf: setupIssues)
            vmStatusViewModel.readiness = readiness
            self.githubEngine = nil
            Log.app.warning("Cannot start: GitHub setup checks failed")
            return
        }

        let vmEngine = vmEngineFactory(
            configStore.storageRootPath,
            configStore.resolvedBaseImagePath,
            configStore.platformDirectoryPath,
            configStore.cacheConfig,
            configStore.diagnosticsRetentionConfig
        )
        self.vmEngine = vmEngine
        vmEngine.updateWarmRunnerConfig(configStore.warmRunnerConfig)
        vmStatusViewModel.baseImageExists = vmEngine.baseImageExists
        vmStatusViewModel.baseImageVerified = vmEngine.baseImageVerified
        refreshReadiness()

        let queueEngine = QueueEngine(
            github: githubEngine,
            client: client
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

        let reconciliation = await queueEngine.reconcileInterruptedLeases(orgs: configStore.organizations)
        vmStatusViewModel.runnerReconciliation = reconciliation

        // Start polling
        await queueEngine.start(orgs: configStore.organizations)
        queueViewModel.startPolling()

        // Sync job store → view model periodically
        startJobStoreSync()

        Log.app.info("App started — polling \(self.configStore.organizations.filter(\.isEnabled).count) org(s)")
    }

    func stop() async {
        syncTask?.cancel()
        syncTask = nil
        for task in completionMonitorTasks.values {
            task.cancel()
        }
        completionMonitorTasks.removeAll()

        if let queueEngine {
            await queueEngine.stop()
        }
        queueViewModel.stopPolling()

        if let vmEngine, vmEngine.isRunning {
            do {
                try await vmEngine.teardown()
            } catch {
                Log.app.error("Failed to teardown VM on stop: \(error.localizedDescription)")
            }
        }

        githubEngine = nil
        queueEngine = nil
        vmEngine = nil

        Log.app.info("App stopped")
    }

    func restart() async {
        await stop()
        await start()
    }

    // MARK: - Job Handling

    private func handleJobReady(_ job: RunnerJob) async {
        guard let githubEngine, let vmEngine, let queueEngine else { return }

        do {
            let org = configStore.organizations.first { $0.name == job.organizationName }
            guard let org else {
                Log.app.error("No org found for job \(job.id)")
                await queueEngine.jobStore.updateJob(id: job.id, status: .failed)
                queueViewModel.updateJobStatus(id: job.id, status: .failed)
                await queueEngine.tryDispatch()
                return
            }

            warmRunnerIdleReleaseTask?.cancel()
            warmRunnerIdleReleaseTask = nil

            // Update status to provisioning
            queueViewModel.updateJobStatus(id: job.id, status: .provisioning)

            // Get runner binary + guest registration config (JIT with registration-token fallback)
            let runnerPath = try await githubEngine.ensureRunner(for: org)
            let runnerName = "ephemeral-\(job.id)"
            let guestConfig = try await githubEngine.generateRunnerGuestConfig(for: org, runnerName: runnerName)
            var lease = RunnerLease(job: job, runnerName: runnerName, labels: org.runnerLabels)
            await queueEngine.runnerLeaseStore.upsert(lease)
            await queueEngine.jobStore.updateRunnerLease(jobId: job.id, lease: lease)

            // Update job with runner config in the store
            await queueEngine.jobStore.updateJob(id: job.id, status: .running)

            // Provision and boot VM
            var runnableJob = job
            runnableJob.applyRunnerGuestConfig(guestConfig)
            runnableJob.runnerName = runnerName
            runnableJob.runnerLease = lease
            runnableJob.status = .running
            let runnerVMConfiguration = org.runnerVMConfiguration(defaultConfiguration: configStore.vmConfiguration)
            let signingInjection = try appleSigningInjection(for: runnableJob, organization: org)
            let instance = try await vmEngine.provisionAndRun(
                job: runnableJob,
                config: runnerVMConfiguration,
                runnerPath: runnerPath,
                baseImagePath: org.runnerBaseImagePath(defaultPath: configStore.resolvedBaseImagePath),
                signingInjection: signingInjection
            )
            let sharedDirectoryPath = StorageManager(rootPath: configStore.storageRootPath)
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

            queueViewModel.updateJobStatus(id: job.id, status: .running)
            vmStatusViewModel.activeVM = vmEngine.currentInstance

            Log.app.info("Job \(job.id) is running in VM")
            startCompletionMonitor(
                for: job.id,
                timeoutSeconds: runnerVMConfiguration.runnerCompletionTimeoutSeconds,
                vmEngine: vmEngine,
                queueEngine: queueEngine
            )
        } catch {
            Log.app.error("Failed to provision job \(job.id): \(error.localizedDescription)")
            if let failedLease = await queueEngine.runnerLeaseStore.recordCleanupState(jobId: job.id, state: .failed) {
                await queueEngine.jobStore.updateRunnerLease(jobId: job.id, lease: failedLease)
            }
            await queueEngine.jobStore.updateJob(id: job.id, status: .failed)
            queueViewModel.updateJobStatus(id: job.id, status: .failed)
            if let diagnosticsPath = vmEngine.diagnosticsBundlePath(for: job.id)?.path {
                if let lease = await queueEngine.runnerLeaseStore.recordDiagnosticsBundle(
                    jobId: job.id,
                    path: diagnosticsPath
                ) {
                    await queueEngine.jobStore.updateRunnerLease(jobId: job.id, lease: lease)
                }
                await queueEngine.jobStore.updateDiagnosticsBundle(jobId: job.id, path: diagnosticsPath)
            }

            // Teardown on failure
            if vmEngine.currentInstance != nil {
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
                vmStatusViewModel.activeVM = nil
            }
            await queueEngine.tryDispatch()
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
                await queueEngine.completeJobFromGuest(jobId: jobId, result: result)
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
        guard let vmEngine, let queueEngine else { return }
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

        let teardownPolicy: VMTeardownPolicy =
            configStore.warmRunnerConfig.isEnabled ? .keepWarmRunner : .full

        do {
            try await vmEngine.teardown(outcome: outcome, policy: teardownPolicy)
        } catch {
            Log.app.error("Failed to teardown completed job \(job.id): \(error.localizedDescription)")
        }

        if teardownPolicy == .keepWarmRunner, vmEngine.hasWarmRunner {
            scheduleWarmRunnerIdleRelease(using: vmEngine)
            vmStatusViewModel.activeVM = vmEngine.currentInstance
        } else {
            warmRunnerIdleReleaseTask?.cancel()
            warmRunnerIdleReleaseTask = nil
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
        queueViewModel.updateJobStatus(id: job.id, status: result.jobStatus)
        if !vmEngine.hasWarmRunner {
            vmStatusViewModel.activeVM = nil
        }
        completionMonitorTasks[job.id] = nil
    }

    private func scheduleWarmRunnerIdleRelease(using vmEngine: VMEngine) {
        warmRunnerIdleReleaseTask?.cancel()
        let idleSeconds = configStore.warmRunnerConfig.normalizedIdleShutdownSeconds
        warmRunnerIdleReleaseTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(idleSeconds))
            } catch {
                return
            }
            guard let self, let vmEngine = self.vmEngine else { return }
            guard vmEngine.hasWarmRunner else { return }
            guard await self.queueEngine?.jobStore.activeJob == nil else { return }

            Log.app.info("Releasing warm runner after \(idleSeconds)s idle")
            do {
                try await vmEngine.releaseWarmRunner()
            } catch {
                Log.app.error("Failed to release idle warm runner: \(error.localizedDescription)")
            }
            self.vmStatusViewModel.activeVM = nil
            self.warmRunnerIdleReleaseTask = nil
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

                if let vmEngine = self.vmEngine {
                    self.vmStatusViewModel.activeVM = vmEngine.currentInstance
                    self.vmStatusViewModel.baseImageExists = vmEngine.baseImageExists
                    self.vmStatusViewModel.baseImageVerified = vmEngine.baseImageVerified
                }
                self.refreshReadiness()

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refreshReadiness() {
        settingsViewModel.refreshStorageHealth()
        let storage = StorageManager(rootPath: configStore.storageRootPath)
        vmStatusViewModel.storageHealth = settingsViewModel.storageHealth
        vmStatusViewModel.baseImageExists = FileManager.default.fileExists(atPath: configStore.resolvedBaseImagePath)
        vmStatusViewModel.baseImageVerified = storage.isBaseImageVerified()
        vmStatusViewModel.readiness = RunnerHostReadiness.evaluate(
            configStore: configStore,
            storageHealth: settingsViewModel.storageHealth
        )
    }
}
