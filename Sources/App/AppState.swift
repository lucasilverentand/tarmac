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

    init() {
        let configStore = ConfigStore()
        self.configStore = configStore
        self.queueViewModel = QueueViewModel()
        self.vmStatusViewModel = VMStatusViewModel()
        self.settingsViewModel = SettingsViewModel(configStore: configStore)
    }

    // MARK: - Engine Lifecycle

    func start() async {
        let issues = settingsViewModel.validateConfiguration()
        guard issues.isEmpty else {
            Log.app.warning("Cannot start: \(issues.joined(separator: ", "))")
            return
        }

        let client = GitHubClient()
        let githubEngine = GitHubEngine(
            client: client,
            cacheDirectory: URL(fileURLWithPath: configStore.cacheDirectoryPath)
        )
        self.githubEngine = githubEngine

        let vmEngine = VMEngine(
            cacheDirectoryPath: configStore.cacheDirectoryPath,
            baseImagePath: resolvedBaseImagePath(),
            cacheConfig: configStore.cacheConfig
        )
        self.vmEngine = vmEngine
        vmStatusViewModel.baseImageExists = vmEngine.baseImageExists

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
                return
            }

            // Update status to provisioning
            queueViewModel.updateJobStatus(id: job.id, status: .provisioning)

            // Get runner binary + JIT config
            let runnerPath = try await githubEngine.ensureRunner(for: org)
            let jitConfig = try await githubEngine.generateJITConfig(for: org, runnerName: "ephemeral-\(job.id)")

            // Update job with JIT config in the store
            await queueEngine.jobStore.updateJob(id: job.id, status: .running)

            // Provision and boot VM
            var runnableJob = job
            runnableJob.jitConfig = jitConfig
            runnableJob.status = .running
            try await vmEngine.provisionAndRun(
                job: runnableJob,
                config: configStore.vmConfiguration,
                runnerPath: runnerPath
            )

            queueViewModel.updateJobStatus(id: job.id, status: .running)
            vmStatusViewModel.activeVM = vmEngine.currentInstance

            Log.app.info("Job \(job.id) is running in VM")
        } catch {
            Log.app.error("Failed to provision job \(job.id): \(error.localizedDescription)")
            await queueEngine.jobStore.updateJob(id: job.id, status: .failed)
            queueViewModel.updateJobStatus(id: job.id, status: .failed)

            // Teardown on failure
            if vmEngine.isRunning {
                try? await vmEngine.teardown()
                vmStatusViewModel.activeVM = nil
            }
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
                }

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Helpers

    private func resolvedBaseImagePath() -> String {
        if !configStore.baseImagePath.isEmpty {
            return configStore.baseImagePath
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Tarmac")
            .appendingPathComponent("BaseImage.img")
            .path
    }
}
