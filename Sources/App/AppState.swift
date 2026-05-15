import Foundation

@Observable
@MainActor
final class AppState {
    let configStore: ConfigStore
    let queueViewModel: QueueViewModel
    let vmStatusViewModel: VMStatusViewModel
    let settingsViewModel: SettingsViewModel

    private var githubEngine: GitHubEngine?
    private var queueEngine: QueueEngine?
    private var vmEngine: VMEngine?
    private var syncTask: Task<Void, Never>?

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
        self.vmStatusViewModel.storageHealth = settingsViewModel.storageHealth
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
        self.vmStatusViewModel.storageHealth = settingsViewModel.storageHealth
    }

    // MARK: - Engine Lifecycle

    func start() async {
        guard queueEngine == nil else {
            Log.app.debug("Start ignored because app is already running")
            return
        }

        let issues = settingsViewModel.validateConfiguration()
        vmStatusViewModel.storageHealth = settingsViewModel.storageHealth
        guard issues.isEmpty else {
            Log.app.warning("Cannot start: \(issues.joined(separator: ", "))")
            return
        }

        let client = githubClientFactory()
        let storage = StorageManager(rootPath: configStore.storageRootPath)
        let githubEngine = GitHubEngine(
            client: client,
            storage: storage
        )
        self.githubEngine = githubEngine

        let vmEngine = vmEngineFactory(
            configStore.storageRootPath,
            configStore.resolvedBaseImagePath,
            configStore.platformDirectoryPath,
            configStore.cacheConfig,
            configStore.diagnosticsRetentionConfig
        )
        self.vmEngine = vmEngine
        vmStatusViewModel.baseImageExists = vmEngine.baseImageExists
        vmStatusViewModel.baseImageVerified = vmEngine.baseImageVerified

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
        await queueEngine.setOnJobCompleted { [weak self] job, result in
            guard let self else { return }
            await self.handleJobCompleted(job, result: result)
        }

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

            // Update status to provisioning
            queueViewModel.updateJobStatus(id: job.id, status: .provisioning)

            // Get runner binary + JIT config
            let runnerPath = try await githubEngine.ensureRunner(for: org)
            let runnerName = "ephemeral-\(job.id)"
            let jitConfig = try await githubEngine.generateJITConfig(for: org, runnerName: runnerName)
            await queueEngine.jobStore.updateRunnerLease(jobId: job.id, runnerName: runnerName)

            // Update job with JIT config in the store
            await queueEngine.jobStore.updateJob(id: job.id, status: .running)

            // Provision and boot VM
            var runnableJob = job
            runnableJob.jitConfig = jitConfig
            runnableJob.runnerName = runnerName
            runnableJob.status = .running
            let instance = try await vmEngine.provisionAndRun(
                job: runnableJob,
                config: configStore.vmConfiguration,
                runnerPath: runnerPath
            )
            await queueEngine.jobStore.updateVMInstance(jobId: job.id, vmInstanceId: instance.id)

            queueViewModel.updateJobStatus(id: job.id, status: .running)
            vmStatusViewModel.activeVM = vmEngine.currentInstance

            Log.app.info("Job \(job.id) is running in VM")
        } catch {
            Log.app.error("Failed to provision job \(job.id): \(error.localizedDescription)")
            await queueEngine.jobStore.updateJob(id: job.id, status: .failed)
            queueViewModel.updateJobStatus(id: job.id, status: .failed)
            if let diagnosticsPath = vmEngine.diagnosticsBundlePath(for: job.id)?.path {
                await queueEngine.jobStore.updateDiagnosticsBundle(jobId: job.id, path: diagnosticsPath)
            }

            // Teardown on failure
            if vmEngine.currentInstance != nil {
                try? await vmEngine.teardown(outcome: .failed(reason: error.localizedDescription))
                if let diagnosticsPath = vmEngine.diagnosticsBundlePath(for: job.id)?.path {
                    await queueEngine.jobStore.updateDiagnosticsBundle(jobId: job.id, path: diagnosticsPath)
                }
                vmStatusViewModel.activeVM = nil
            }
            await queueEngine.tryDispatch()
        }
    }

    private func handleJobCompleted(_ job: RunnerJob, result: JobResult) async {
        guard let vmEngine, let queueEngine else { return }
        guard vmEngine.currentInstance?.jobId == job.id else { return }

        let outcome: JobDiagnosticsOutcome =
            switch result {
            case .success:
                .succeeded
            case .failure(let reason):
                .failed(reason: reason)
            }

        do {
            try await vmEngine.teardown(outcome: outcome)
        } catch {
            Log.app.error("Failed to teardown completed job \(job.id): \(error.localizedDescription)")
        }

        if let diagnosticsPath = vmEngine.diagnosticsBundlePath(for: job.id)?.path {
            await queueEngine.jobStore.updateDiagnosticsBundle(jobId: job.id, path: diagnosticsPath)
        }
        vmStatusViewModel.activeVM = nil
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
                    self.settingsViewModel.refreshStorageHealth()
                    self.vmStatusViewModel.storageHealth = self.settingsViewModel.storageHealth
                }

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
