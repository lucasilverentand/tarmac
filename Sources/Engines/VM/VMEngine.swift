import Foundation
import Virtualization

@Observable
@MainActor
final class VMEngine: VMManagerProtocol {
    private let lifecycle: any VMLifecycleProtocol
    private let diskManager: DiskImageManager
    private let imageManager: ImageManager
    private let sharedDirManager: SharedDirectoryManager
    private let cacheManager: CacheManager
    private let platformStore: PlatformDataStore
    private let storage: StorageManager
    private let baseImageURL: URL
    private var diagnosticsStore: DiagnosticsBundleStore

    private(set) var currentInstance: VMInstance?
    private(set) var warmRunnerState: WarmRunnerState?
    private(set) var verificationState: BaseImageVerificationState = .notStarted
    private var cacheConfig: CacheConfiguration
    private var warmRunnerConfig: WarmRunnerConfiguration = WarmRunnerConfiguration()
    private var diagnosticsContexts: [Int64: JobDiagnosticsContext] = [:]
    private var diagnosticsBundleURLs: [Int64: URL] = [:]

    var isRunning: Bool { currentInstance?.state == .running }

    var hasWarmRunner: Bool {
        warmRunnerState != nil && lifecycle.isBooted
    }

    var baseImageExists: Bool {
        FileManager.default.fileExists(atPath: baseImageURL.path)
    }

    var baseImageVerified: Bool {
        storage.isBaseImageVerified()
    }

    /// True only when the base image both exists on disk and has passed boot verification.
    var baseImageReady: Bool {
        baseImageExists && baseImageVerified
    }

    var installProgress: Double {
        imageManager.installProgress
    }

    init(
        cacheDirectoryPath: String,
        baseImagePath: String,
        platformDirectoryPath: String? = nil,
        cacheConfig: CacheConfiguration = CacheConfiguration(),
        diagnosticsRetention: DiagnosticsRetentionConfiguration = DiagnosticsRetentionConfiguration(),
        platformStore: PlatformDataStore? = nil,
        lifecycle: (any VMLifecycleProtocol)? = nil,
        diskManager: DiskImageManager = DiskImageManager(),
        imageManager: ImageManager? = nil
    ) {
        let storage = StorageManager(rootPath: cacheDirectoryPath)
        self.storage = storage
        self.sharedDirManager = SharedDirectoryManager(storage: storage)
        self.cacheManager = CacheManager(storage: storage)
        self.diagnosticsStore = DiagnosticsBundleStore(storage: storage, retention: diagnosticsRetention)
        if let platformStore {
            self.platformStore = platformStore
        } else if let platformDirectoryPath {
            self.platformStore = PlatformDataStore(directory: URL(fileURLWithPath: platformDirectoryPath))
        } else {
            self.platformStore = PlatformDataStore(storage: storage)
        }
        self.baseImageURL = URL(fileURLWithPath: baseImagePath)
        self.cacheConfig = cacheConfig
        self.lifecycle = lifecycle ?? VMLifecycle()
        self.diskManager = diskManager
        self.imageManager = imageManager ?? ImageManager(storage: storage)
    }

    // MARK: - Base Image

    func createBaseImage(from ipsw: URL, config: VMConfiguration) async throws {
        let path = baseImageURL.path
        Log.vm.info("Creating base image at \(path)")

        try storage.prepareBaseDirectories()
        try storage.cleanupTransientFiles()
        try diskManager.createSparseDisk(at: baseImageURL, sizeGB: config.diskSizeGB, overwrite: true)

        // A fresh install invalidates any previous verification.
        try? storage.clearBaseImageVerified()
        verificationState = .notStarted

        try await imageManager.installMacOS(
            ipsw: ipsw,
            diskPath: baseImageURL,
            config: config,
            platformStore: platformStore
        )

        Log.vm.info("Base image created successfully")
    }

    /// Boot a clone of the base image, hold it briefly, then stop cleanly.
    /// Writes the verified marker only when the full cycle succeeds.
    func verifyBaseImage(
        config: VMConfiguration,
        holdSeconds: TimeInterval = 10
    ) async throws {
        guard baseImageExists else {
            throw VMEngineError.baseImageMissing
        }

        try storage.prepareBaseDirectories()
        verificationState = .verifying
        _ = try ensureStorageReadyForBoot(config: config, context: "base image verification")

        let clonePath = storage.disksDirectory
            .appendingPathComponent("verify-\(UUID().uuidString).img")

        do {
            let cloneMetrics = try diskManager.cloneDisk(from: baseImageURL, to: clonePath)
            logCloneFallbackIfNeeded(cloneMetrics, context: "base image verification")
        } catch {
            verificationState = .failed(message: "Could not clone base image: \(error.localizedDescription)")
            throw VMEngineError.verificationFailed(reason: error.localizedDescription)
        }

        defer { try? diskManager.deleteDisk(at: clonePath) }

        do {
            try await lifecycle.bootVM(
                vmConfig: config,
                diskPath: clonePath,
                platformStore: platformStore,
                sharedDirectoryURL: nil,
                cacheDirectoryURL: nil
            )
        } catch {
            verificationState = .failed(message: "Boot failed: \(error.localizedDescription)")
            Log.vm.error("Base image verification boot failed: \(error.localizedDescription)")
            throw VMEngineError.verificationFailed(reason: error.localizedDescription)
        }

        if holdSeconds > 0 {
            try? await Task.sleep(for: .seconds(holdSeconds))
        }

        do {
            try await lifecycle.stopVM()
        } catch {
            verificationState = .failed(message: "Stop failed: \(error.localizedDescription)")
            Log.vm.error("Base image verification stop failed: \(error.localizedDescription)")
            throw VMEngineError.verificationFailed(reason: error.localizedDescription)
        }

        do {
            try storage.markBaseImageVerified()
        } catch {
            verificationState = .failed(message: "Could not write verified marker: \(error.localizedDescription)")
            throw VMEngineError.verificationFailed(reason: error.localizedDescription)
        }

        verificationState = .verified
        Log.vm.info("Base image verification succeeded")
    }

    func scanRunnerImage(
        baseImagePath overrideBaseImagePath: String? = nil,
        config: VMConfiguration,
        timeoutSeconds: Int = 300
    ) async throws -> RunnerImageInventoryReport {
        let sourceImageURL = baseImageURL(for: overrideBaseImagePath)
        guard FileManager.default.fileExists(atPath: sourceImageURL.path) else {
            throw VMEngineError.baseImageMissing
        }

        try storage.prepareBaseDirectories()
        try storage.cleanupTransientFiles()
        _ = try ensureStorageReadyForBoot(config: config, context: "runner image inventory scan")

        let scanId = UUID()
        let clonePath = storage.disksDirectory
            .appendingPathComponent("inventory-\(scanId.uuidString).img")
        let sharedDirectory = storage.jobsDirectory
            .appendingPathComponent("inventory-\(scanId.uuidString)", isDirectory: true)

        do {
            let cloneMetrics = try diskManager.cloneDisk(from: sourceImageURL, to: clonePath)
            logCloneFallbackIfNeeded(cloneMetrics, context: "runner image inventory scan")
            try prepareInventorySharedDirectory(sharedDirectory)
            try await lifecycle.bootVM(
                vmConfig: config,
                diskPath: clonePath,
                platformStore: platformStore,
                sharedDirectoryURL: sharedDirectory,
                cacheDirectoryURL: nil
            )

            let result = try await waitForSharedCompletion(
                in: sharedDirectory,
                timeoutSeconds: timeoutSeconds,
                context: "runner image inventory scan"
            )
            guard case .success = result else {
                if case .failure(let reason) = result {
                    throw VMEngineError.imageInventoryScanFailed(reason: reason)
                }
                throw VMEngineError.imageInventoryScanFailed(reason: "Inventory runner failed")
            }

            let inventoryURL = sharedDirectory.appendingPathComponent(Self.inventoryReportFileName)
            let contents = try String(contentsOf: inventoryURL, encoding: .utf8)
            try? await stopVM()
            try? diskManager.deleteDisk(at: clonePath)
            try? FileManager.default.removeItem(at: sharedDirectory)
            return RunnerImageInventoryReport.parse(contents)
        } catch {
            try? await stopVM()
            try? diskManager.deleteDisk(at: clonePath)
            try? FileManager.default.removeItem(at: sharedDirectory)
            throw error
        }
    }

    // MARK: - VM Lifecycle

    func bootVM(
        for jobId: Int64,
        config: VMConfiguration,
        sharedDirectory: URL
    ) async throws -> VMInstance {
        try await bootVM(
            for: jobId,
            config: config,
            sharedDirectory: sharedDirectory,
            baseImagePath: nil
        )
    }

    func bootVM(
        for jobId: Int64,
        config: VMConfiguration,
        sharedDirectory: URL,
        baseImagePath overrideBaseImagePath: String?
    ) async throws -> VMInstance {
        let sourceImageURL = baseImageURL(for: overrideBaseImagePath)
        guard FileManager.default.fileExists(atPath: sourceImageURL.path) else {
            throw VMEngineError.baseImageMissing
        }

        try storage.prepareBaseDirectories()
        try storage.cleanupTransientFiles()

        let instanceId = UUID()
        let clonedDiskPath = storage.disksDirectory
            .appendingPathComponent("\(instanceId.uuidString).img")

        updateDiagnosticsContext(jobId: jobId) { context in
            context.vmInstanceId = instanceId
            context.diskImagePath = clonedDiskPath
            if context.startedAt == nil {
                context.startedAt = Date()
            }
        }
        appendHostLifecycle(
            "Starting VM boot with instance \(instanceId.uuidString)",
            jobId: jobId,
            sharedDirectory: sharedDirectory
        )

        var instance = VMInstance(
            id: instanceId,
            jobId: jobId,
            diskImagePath: clonedDiskPath,
            startedAt: Date(),
            state: .booting
        )

        do {
            _ = try ensureStorageReadyForBoot(config: config, context: "job \(jobId) boot")

            let cloneMetrics = try diskManager.cloneDisk(from: sourceImageURL, to: clonedDiskPath)
            logCloneFallbackIfNeeded(cloneMetrics, context: "job \(jobId) boot")
            appendHostLifecycle(
                "Cloned base disk \(sourceImageURL.lastPathComponent) to \(clonedDiskPath.lastPathComponent)",
                jobId: jobId,
                sharedDirectory: sharedDirectory
            )

            // Prepare cache directory and evict stale entries
            var cacheDirectoryURL: URL? = nil
            if cacheConfig.isEnabled {
                try cacheManager.prepare()
                try cacheManager.evict(retentionDays: cacheConfig.retentionDays)
                try cacheManager.enforceMaxSize(maxSizeGB: cacheConfig.maxSizeGB)
                cacheDirectoryURL = cacheManager.baseDirectory
                appendHostLifecycle(
                    "Prepared actions cache at \(cacheManager.baseDirectory.path); guest tag \(CacheConfiguration.guestMountTag) mounts at \(CacheConfiguration.guestMountPoint)",
                    jobId: jobId,
                    sharedDirectory: sharedDirectory
                )
            }

            currentInstance = instance
            try await lifecycle.bootVM(
                vmConfig: config,
                diskPath: clonedDiskPath,
                platformStore: platformStore,
                sharedDirectoryURL: sharedDirectory,
                cacheDirectoryURL: cacheDirectoryURL
            )
        } catch {
            instance.state = .failed
            currentInstance = instance
            appendHostLifecycle(
                "VM boot failed: \(error.localizedDescription)",
                jobId: jobId,
                sharedDirectory: sharedDirectory
            )
            preserveDiagnosticsIfNeeded(
                jobId: jobId,
                sharedDirectory: sharedDirectory,
                outcome: .failed(reason: "VM boot failed: \(error.localizedDescription)")
            )
            try? diskManager.deleteDisk(at: clonedDiskPath)
            Log.vm.error("VM boot failed for job \(jobId): \(error.localizedDescription)")
            throw error
        }

        instance.state = .running
        currentInstance = instance

        appendHostLifecycle("VM booted and is running", jobId: jobId, sharedDirectory: sharedDirectory)
        Log.vm.info("VM running for job \(jobId)")
        return instance
    }

    func stopVM() async throws {
        guard lifecycle.isBooted else { return }
        currentInstance?.state = .stopping

        try await lifecycle.stopVM()
        currentInstance?.state = .stopped

        Log.vm.info("VM stopped")
    }

    // MARK: - Full Job Flow

    @discardableResult
    func provisionAndRun(
        job: RunnerJob,
        config: VMConfiguration,
        runnerPath: URL,
        baseImagePath overrideBaseImagePath: String? = nil,
        signingInjection: AppleSigningInjection? = nil
    ) async throws -> VMInstance {
        guard let guestConfig = job.runnerGuestConfig else {
            throw VMEngineError.missingRunnerGuestConfig
        }

        let sourceImagePath = baseImageURL(for: overrideBaseImagePath).path
        if warmRunnerConfig.isEnabled,
            let warmState = warmRunnerState,
            canReuseWarmRunner(config: config, baseImagePath: sourceImagePath, warmState: warmState)
        {
            return try await reuseWarmRunner(
                job: job,
                runnerPath: runnerPath,
                guestConfig: guestConfig,
                signingInjection: signingInjection,
                warmState: warmState
            )
        }

        if warmRunnerConfig.isEnabled {
            if warmRunnerState != nil {
                try await releaseWarmRunner()
            }
            return try await provisionWarmRunner(
                job: job,
                config: config,
                runnerPath: runnerPath,
                guestConfig: guestConfig,
                baseImagePath: overrideBaseImagePath,
                signingInjection: signingInjection
            )
        }

        let sharedDir = try sharedDirManager.prepareForJob(
            jobId: job.id,
            runnerPath: runnerPath,
            guestConfig: guestConfig,
            signingInjection: signingInjection
        )
        diagnosticsContexts[job.id] = JobDiagnosticsContext(job: job, runnerName: job.runnerName)
        appendHostLifecycle(
            "Prepared shared job directory with runner \(runnerPath.lastPathComponent)",
            jobId: job.id,
            sharedDirectory: sharedDir
        )

        do {
            return try await bootVM(
                for: job.id,
                config: config,
                sharedDirectory: sharedDir,
                baseImagePath: overrideBaseImagePath
            )
        } catch {
            try? sharedDirManager.cleanupJob(jobId: job.id)
            throw error
        }
    }

    func waitForJobCompletion(
        jobId: Int64,
        timeoutSeconds: Int,
        pollIntervalSeconds: TimeInterval = 2
    ) async throws -> JobResult {
        let sharedDirectory = sharedDirectory(forJobId: jobId)
        let markerURL = sharedDirectory.appendingPathComponent(GuestBootstrapContract.completionMarkerFileName)
        let exitCodeURL = sharedDirectory.appendingPathComponent(GuestBootstrapContract.exitCodeFileName)
        let timeout = max(1, timeoutSeconds)
        let pollMilliseconds = max(100, Int(pollIntervalSeconds * 1_000))
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))

        appendHostLifecycle(
            "Waiting up to \(timeout)s for runner completion marker \(GuestBootstrapContract.completionMarkerFileName)",
            jobId: jobId,
            sharedDirectory: sharedDirectory
        )

        while Date() < deadline {
            try Task.checkCancellation()

            if FileManager.default.fileExists(atPath: markerURL.path) {
                let result = readCompletionResult(exitCodeURL: exitCodeURL)
                appendHostLifecycle(
                    "Runner completion marker observed with \(result.logDescription)",
                    jobId: jobId,
                    sharedDirectory: sharedDirectory
                )
                return result
            }

            try await Task.sleep(for: .milliseconds(pollMilliseconds))
        }

        let reason = "Timed out after \(timeout)s waiting for runner completion marker"
        appendHostLifecycle(reason, jobId: jobId, sharedDirectory: sharedDirectory)
        return .failure(reason)
    }

    func teardown(
        outcome: JobDiagnosticsOutcome = .unknown(),
        policy: VMTeardownPolicy = .full
    ) async throws {
        let diskPath = currentInstance?.diskImagePath
        let jobId = currentInstance?.jobId
        let jobSharedDirectory = jobId.map { self.sharedDirectory(forJobId: $0) }

        if policy == .keepWarmRunner, warmRunnerConfig.isEnabled, warmRunnerState != nil {
            if let jobId, let jobSharedDirectory {
                updateDiagnosticsContext(jobId: jobId) { context in
                    context.completedAt = Date()
                }
                preserveDiagnosticsIfNeeded(jobId: jobId, sharedDirectory: jobSharedDirectory, outcome: outcome)
                try? sharedDirManager.clearWarmRunnerJobArtifacts(in: jobSharedDirectory)
                appendHostLifecycle(
                    "Teardown kept warm runner running",
                    jobId: jobId,
                    sharedDirectory: jobSharedDirectory
                )
            }
            warmRunnerState?.lastActivityAt = Date()
            Log.vm.info("Warm runner kept running after job \(jobId.map { String($0) } ?? "unknown")")
            return
        }

        if let warmDirectory = warmRunnerState?.sharedDirectory {
            try? sharedDirManager.requestWarmShutdown(in: warmDirectory)
        }

        if let jobId, let jobSharedDirectory {
            appendHostLifecycle("Teardown requested (full)", jobId: jobId, sharedDirectory: jobSharedDirectory)
        }
        do {
            try await stopVM()
        } catch {
            if let jobId, let jobSharedDirectory {
                appendHostLifecycle(
                    "VM stop failed: \(error.localizedDescription)",
                    jobId: jobId,
                    sharedDirectory: jobSharedDirectory
                )
                preserveDiagnosticsIfNeeded(
                    jobId: jobId,
                    sharedDirectory: jobSharedDirectory,
                    outcome: .failed(reason: "VM stop failed: \(error.localizedDescription)")
                )
            }
            throw error
        }
        if let jobId, let jobSharedDirectory {
            updateDiagnosticsContext(jobId: jobId) { context in
                context.completedAt = Date()
            }
            appendHostLifecycle("VM stop completed", jobId: jobId, sharedDirectory: jobSharedDirectory)
            if let diskPath {
                appendHostLifecycle(
                    "Deleting cloned disk \(diskPath.lastPathComponent)",
                    jobId: jobId,
                    sharedDirectory: jobSharedDirectory
                )
            }
            preserveDiagnosticsIfNeeded(jobId: jobId, sharedDirectory: jobSharedDirectory, outcome: outcome)
        }

        if let diskPath {
            try diskManager.deleteDisk(at: diskPath)
        }

        if let jobId, warmRunnerState == nil {
            try sharedDirManager.cleanupJob(jobId: jobId)
        }

        currentInstance = nil
        warmRunnerState = nil
        Log.vm.info("VM teardown complete")
    }

    func releaseWarmRunner() async throws {
        try await teardown(policy: .full)
    }

    // MARK: - Cache

    func updateCacheConfig(_ config: CacheConfiguration) {
        self.cacheConfig = config
    }

    func updateWarmRunnerConfig(_ config: WarmRunnerConfiguration) {
        warmRunnerConfig = config
    }

    func updateDiagnosticsRetentionConfig(_ config: DiagnosticsRetentionConfiguration) {
        diagnosticsStore.retention = config
    }

    func diagnosticsBundlePath(for jobId: Int64) -> URL? {
        diagnosticsBundleURLs[jobId]
    }

    func clearCache() throws {
        try cacheManager.clear()
    }

    func cacheSizeBytes() throws -> Int64 {
        try cacheManager.currentSizeBytes()
    }

    // MARK: - Storage Readiness

    private func ensureStorageReadyForBoot(config: VMConfiguration, context: String) throws -> StorageHealth {
        let health = storage.evaluateHealth(minimumFreeBytes: nil)
        let requiredFreeBytes = requiredFreeBytes(for: config, cloneBehavior: health.cloneBehavior)
        let volume = health.volume?.formatDisplayName ?? "unknown"
        let mountPoint = health.volume?.mountPoint ?? "unknown"
        let available = formatBytes(health.volume?.availableCapacityBytes)
        let required = formatBytes(requiredFreeBytes)

        Log.vm.info(
            "Storage before \(context, privacy: .public): root=\(health.rootDirectory.path, privacy: .public), volume=\(volume, privacy: .public), mount=\(mountPoint, privacy: .public), clone=\(health.cloneBehavior.displayName, privacy: .public), available=\(available, privacy: .public), required=\(required, privacy: .public)"
        )

        if !health.blockingIssues.isEmpty {
            throw VMEngineError.unsuitableStorage(reason: health.summary)
        }

        if let available = health.volume?.availableCapacityBytes, available < requiredFreeBytes {
            throw VMEngineError.unsuitableStorage(
                reason:
                    "Storage volume has \(formatBytes(available)) available; \(formatBytes(requiredFreeBytes)) required before \(context)."
            )
        }

        if health.status == .degraded {
            Log.vm.warning(
                "Storage is degraded before \(context, privacy: .public): \(health.summary, privacy: .public)"
            )
        }

        return health
    }

    private func requiredFreeBytes(for config: VMConfiguration, cloneBehavior: StorageCloneBehavior) -> Int64 {
        let gib: Int64 = 1024 * 1024 * 1024
        if cloneBehavior.isFastPath {
            return max(10 * gib, Int64(config.diskSizeGB) * gib / 10)
        }
        return Int64(config.diskSizeGB) * gib
    }

    private func logCloneFallbackIfNeeded(_ metrics: DiskCloneResult, context: String) {
        if case .fullCopyFallback(let errno) = metrics.method {
            Log.vm.warning(
                "Disk clone for \(context, privacy: .public) used full-copy fallback after clonefile errno \(errno); duration=\(formatDuration(metrics.duration), privacy: .public), allocated=\(formatBytes(metrics.destinationAllocatedSizeBytes), privacy: .public)"
            )
        }
    }

    private func updateDiagnosticsContext(
        jobId: Int64,
        update: (inout JobDiagnosticsContext) -> Void
    ) {
        var context = diagnosticsContexts[jobId] ?? JobDiagnosticsContext(jobId: jobId)
        update(&context)
        diagnosticsContexts[jobId] = context
    }

    private func appendHostLifecycle(_ message: String, jobId: Int64, sharedDirectory: URL) {
        diagnosticsStore.appendHostLifecycleEvent(message, to: sharedDirectory)
        Log.vm.debug("Job \(jobId) diagnostic: \(message, privacy: .public)")
    }

    private func preserveDiagnosticsIfNeeded(
        jobId: Int64,
        sharedDirectory: URL,
        outcome: JobDiagnosticsOutcome
    ) {
        if diagnosticsBundleURLs[jobId] != nil {
            return
        }

        var context = diagnosticsContexts[jobId] ?? JobDiagnosticsContext(jobId: jobId)
        if context.completedAt == nil, outcome != .succeeded {
            context.completedAt = Date()
        }

        do {
            let bundle = try diagnosticsStore.createBundle(
                context: context,
                sharedDirectory: sharedDirectory,
                outcome: outcome
            )
            diagnosticsContexts[jobId] = context
            diagnosticsBundleURLs[jobId] = bundle.url
        } catch {
            Log.vm.error("Failed to preserve diagnostics for job \(jobId): \(error.localizedDescription)")
        }
    }

    private func readCompletionResult(exitCodeURL: URL) -> JobResult {
        guard let contents = try? String(contentsOf: exitCodeURL, encoding: .utf8) else {
            return .failure("Runner completion marker was written without an exit code")
        }

        let rawExitCode = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let exitCode = Int(rawExitCode) else {
            return .failure("Runner wrote an invalid exit code: \(rawExitCode)")
        }

        if exitCode == 0 {
            return .success
        }

        return .failure("Runner exited with code \(exitCode)")
    }

    private func baseImageURL(for overridePath: String?) -> URL {
        guard let overridePath,
            !overridePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return baseImageURL
        }
        return URL(fileURLWithPath: overridePath)
    }

    private func sharedDirectory(forJobId jobId: Int64) -> URL {
        if warmRunnerConfig.isEnabled, warmRunnerState != nil {
            return sharedDirManager.warmRunnerDirectory
        }
        return storage.jobsDirectory.appendingPathComponent("\(jobId)", isDirectory: true)
    }

    private func canReuseWarmRunner(
        config: VMConfiguration,
        baseImagePath: String,
        warmState: WarmRunnerState
    ) -> Bool {
        guard lifecycle.isBooted else { return false }
        guard warmState.vmConfiguration == config else { return false }
        guard warmState.baseImagePath == baseImagePath else { return false }
        guard !warmRunnerConfig.shouldRecycleWarmRunner(jobsServed: warmState.jobsServed) else { return false }
        return true
    }

    private func provisionWarmRunner(
        job: RunnerJob,
        config: VMConfiguration,
        runnerPath: URL,
        guestConfig: RunnerGuestConfig,
        baseImagePath overrideBaseImagePath: String?,
        signingInjection: AppleSigningInjection?
    ) async throws -> VMInstance {
        let sharedDir = try sharedDirManager.prepareWarmRunnerJob(
            jobId: job.id,
            runnerPath: runnerPath,
            guestConfig: guestConfig,
            signingInjection: signingInjection
        )
        try sharedDirManager.enableWarmMode(in: sharedDir)
        diagnosticsContexts[job.id] = JobDiagnosticsContext(job: job, runnerName: job.runnerName)
        appendHostLifecycle(
            "Prepared warm runner shared directory with runner \(runnerPath.lastPathComponent)",
            jobId: job.id,
            sharedDirectory: sharedDir
        )

        do {
            let instance = try await bootVM(
                for: job.id,
                config: config,
                sharedDirectory: sharedDir,
                baseImagePath: overrideBaseImagePath
            )
            warmRunnerState = WarmRunnerState(
                instanceId: instance.id,
                sharedDirectory: sharedDir,
                vmConfiguration: config,
                baseImagePath: baseImageURL(for: overrideBaseImagePath).path,
                jobsServed: 0,
                lastActivityAt: Date()
            )
            try sharedDirManager.signalJobReady(in: sharedDir)
            appendHostLifecycle("Signaled warm runner job ready", jobId: job.id, sharedDirectory: sharedDir)
            return instance
        } catch {
            try? FileManager.default.removeItem(at: sharedDir)
            warmRunnerState = nil
            throw error
        }
    }

    private func reuseWarmRunner(
        job: RunnerJob,
        runnerPath: URL,
        guestConfig: RunnerGuestConfig,
        signingInjection: AppleSigningInjection?,
        warmState: WarmRunnerState
    ) async throws -> VMInstance {
        let sharedDir = try sharedDirManager.prepareWarmRunnerJob(
            jobId: job.id,
            runnerPath: runnerPath,
            guestConfig: guestConfig,
            signingInjection: signingInjection
        )
        diagnosticsContexts[job.id] = JobDiagnosticsContext(job: job, runnerName: job.runnerName)
        appendHostLifecycle(
            "Reusing warm runner VM for job \(job.id)",
            jobId: job.id,
            sharedDirectory: sharedDir
        )

        guard var instance = currentInstance, instance.id == warmState.instanceId else {
            throw VMEngineError.warmRunnerUnavailable
        }

        instance.jobId = job.id
        instance.state = .running
        currentInstance = instance
        warmRunnerState?.jobsServed += 1
        warmRunnerState?.lastActivityAt = Date()
        warmRunnerState?.sharedDirectory = sharedDir

        try sharedDirManager.signalJobReady(in: sharedDir)
        appendHostLifecycle("Signaled warm runner job ready", jobId: job.id, sharedDirectory: sharedDir)
        return instance
    }

    private func prepareInventorySharedDirectory(_ sharedDirectory: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: sharedDirectory.path) {
            try fm.removeItem(at: sharedDirectory)
        }
        let runnerDirectory = sharedDirectory.appendingPathComponent(GuestBootstrapContract.runnerDirectoryName)
        try fm.createDirectory(at: runnerDirectory, withIntermediateDirectories: true)
        try "inventory-scan\n".write(
            to: sharedDirectory.appendingPathComponent(GuestBootstrapContract.jitConfigFileName),
            atomically: true,
            encoding: .utf8
        )

        let runScriptURL = runnerDirectory.appendingPathComponent(GuestBootstrapContract.runnerEntrypointName)
        try Self.inventoryRunScript.write(to: runScriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runScriptURL.path)
    }

    private func waitForSharedCompletion(
        in sharedDirectory: URL,
        timeoutSeconds: Int,
        context: String
    ) async throws -> JobResult {
        let markerURL = sharedDirectory.appendingPathComponent(GuestBootstrapContract.completionMarkerFileName)
        let exitCodeURL = sharedDirectory.appendingPathComponent(GuestBootstrapContract.exitCodeFileName)
        let deadline = Date().addingTimeInterval(TimeInterval(max(1, timeoutSeconds)))

        while Date() < deadline {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: markerURL.path) {
                return readCompletionResult(exitCodeURL: exitCodeURL)
            }
            try await Task.sleep(for: .seconds(1))
        }

        return .failure("Timed out waiting for \(context)")
    }
}

enum VMEngineError: LocalizedError {
    case missingRunnerGuestConfig
    case missingJITConfig
    case baseImageMissing
    case verificationFailed(reason: String)
    case unsuitableStorage(reason: String)
    case imageInventoryScanFailed(reason: String)
    case warmRunnerUnavailable

    var errorDescription: String? {
        switch self {
        case .missingRunnerGuestConfig, .missingJITConfig:
            "Job is missing runner guest configuration"
        case .baseImageMissing:
            "Base image does not exist on disk"
        case .verificationFailed(let reason):
            "Base image verification failed: \(reason)"
        case .unsuitableStorage(let reason):
            "Storage is not suitable for VM work: \(reason)"
        case .imageInventoryScanFailed(let reason):
            "Runner image inventory scan failed: \(reason)"
        case .warmRunnerUnavailable:
            "Warm runner VM is not available for reuse"
        }
    }
}

enum VMTeardownPolicy: Equatable, Sendable {
    case full
    case keepWarmRunner
}

struct WarmRunnerState: Equatable, Sendable {
    let instanceId: UUID
    var sharedDirectory: URL
    let vmConfiguration: VMConfiguration
    let baseImagePath: String
    var jobsServed: Int
    var lastActivityAt: Date
}

private extension VMEngine {
    static let inventoryReportFileName = "toolchain-inventory.tsv"

    static let inventoryRunScript = """
        #!/bin/bash
        set -u -o pipefail

        PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        OUT="\(GuestBootstrapContract.sharedMountPoint)/\(inventoryReportFileName)"
        TMP="${OUT}.tmp"
        : > "${TMP}"

        trim() {
            /usr/bin/sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//'
        }

        emit2() {
            /usr/bin/printf '%s\\t%s\\n' "$1" "$2" >> "${TMP}"
        }

        emit3() {
            /usr/bin/printf '%s\\t%s\\t%s\\n' "$1" "$2" "$3" >> "${TMP}"
        }

        emit4() {
            /usr/bin/printf '%s\\t%s\\t%s\\t%s\\n' "$1" "$2" "$3" "$4" >> "${TMP}"
        }

        first_line() {
            "$@" 2>&1 | /usr/bin/head -n 1 | trim
        }

        emit2 "captured_at" "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
        emit2 "macos_version" "$(/usr/bin/sw_vers -productVersion 2>/dev/null | trim)"

        developer_directory="$(/usr/bin/xcode-select --print-path 2>/dev/null | trim || true)"
        emit2 "developer_directory" "${developer_directory}"

        xcode_version="$(/usr/bin/xcodebuild -version 2>/dev/null | /usr/bin/awk '/^Xcode / { print $2; exit }')"
        emit2 "xcode_version" "${xcode_version}"

        if /usr/bin/xcodebuild -license check >/dev/null 2>&1; then
            emit2 "xcode_license_accepted" "true"
        else
            emit2 "xcode_license_accepted" "false"
        fi

        clt_version="$(/usr/sbin/pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null | /usr/bin/awk -F': ' '/^version:/ { print $2; exit }')"
        emit2 "command_line_tools_version" "${clt_version}"
        if [[ -n "${clt_version}" || -n "${xcode_version}" ]]; then
            emit2 "command_line_tools_installed" "true"
        else
            emit2 "command_line_tools_installed" "false"
        fi

        sdk_output="$(/usr/bin/mktemp)"
        if /usr/bin/xcodebuild -showsdks > "${sdk_output}" 2>/dev/null; then
            while IFS= read -r line; do
                [[ "${line}" == *"-sdk "* ]] || continue
                sdk="${line##*-sdk }"
                platform=""
                case "${sdk}" in
                    macosx*) platform="macos" ;;
                    iphoneos*|iphonesimulator*) platform="ios" ;;
                    watchos*|watchsimulator*) platform="watchos" ;;
                    appletvos*|appletvsimulator*) platform="tvos" ;;
                    xros*|xrsimulator*) platform="visionos" ;;
                esac
                [[ -n "${platform}" ]] || continue
                version="$(/usr/bin/printf '%s' "${sdk}" | /usr/bin/sed -E 's/^[^0-9]*//')"
                [[ -n "${version}" ]] || continue
                emit3 "sdk" "${platform}" "${version}"
            done < "${sdk_output}"
        fi
        /bin/rm -f "${sdk_output}"

        runtime_output="$(/usr/bin/mktemp)"
        if /usr/bin/xcrun simctl list runtimes > "${runtime_output}" 2>/dev/null; then
            while IFS= read -r line; do
                platform=""
                case "${line}" in
                    iOS\\ *) platform="ios" ;;
                    watchOS\\ *) platform="watchos" ;;
                    tvOS\\ *) platform="tvos" ;;
                    visionOS\\ *) platform="visionos" ;;
                esac
                [[ -n "${platform}" ]] || continue
                version="$(/usr/bin/printf '%s' "${line}" | /usr/bin/awk '{ print $2 }')"
                [[ -n "${version}" ]] || continue
                available="true"
                if [[ "${line}" == *"unavailable"* ]]; then
                    available="false"
                fi
                emit4 "runtime" "${platform}" "${version}" "${available}"
            done < "${runtime_output}"
        fi
        /bin/rm -f "${runtime_output}"

        if command -v flutter >/dev/null 2>&1; then emit3 "tool" "flutter" "$(first_line flutter --version)"; fi
        if command -v dart >/dev/null 2>&1; then emit3 "tool" "dart" "$(first_line dart --version)"; fi
        if command -v node >/dev/null 2>&1; then emit3 "tool" "node" "$(first_line node --version)"; fi
        if command -v ruby >/dev/null 2>&1; then emit3 "tool" "ruby" "$(first_line ruby --version)"; fi
        if command -v pod >/dev/null 2>&1; then emit3 "tool" "cocoapods" "$(first_line pod --version)"; fi
        if command -v expo >/dev/null 2>&1; then emit3 "tool" "expo" "$(first_line expo --version)"; fi
        if command -v eas >/dev/null 2>&1; then emit3 "tool" "eas" "$(first_line eas --version)"; fi

        for manager in npm yarn pnpm bun; do
            if command -v "${manager}" >/dev/null 2>&1; then
                emit3 "package_manager" "${manager}" "$(first_line "${manager}" --version)"
            fi
        done

        /bin/mv "${TMP}" "${OUT}"
        """
}

enum BaseImageVerificationState: Equatable, Sendable {
    case notStarted
    case verifying
    case verified
    case failed(message: String)
}

private func formatBytes(_ bytes: Int64?) -> String {
    guard let bytes else { return "unknown" }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    return formatter.string(fromByteCount: bytes)
}

private func formatDuration(_ duration: TimeInterval) -> String {
    String(format: "%.3fs", duration)
}
