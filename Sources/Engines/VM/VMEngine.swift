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
    private(set) var verificationState: BaseImageVerificationState = .notStarted
    private var cacheConfig: CacheConfiguration
    private var diagnosticsContexts: [Int64: JobDiagnosticsContext] = [:]
    private var diagnosticsBundleURLs: [Int64: URL] = [:]

    var isRunning: Bool { currentInstance?.state == .running }

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

    // MARK: - VM Lifecycle

    func bootVM(
        for jobId: Int64,
        config: VMConfiguration,
        sharedDirectory: URL
    ) async throws -> VMInstance {
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

            let cloneMetrics = try diskManager.cloneDisk(from: baseImageURL, to: clonedDiskPath)
            logCloneFallbackIfNeeded(cloneMetrics, context: "job \(jobId) boot")
            appendHostLifecycle(
                "Cloned base disk to \(clonedDiskPath.lastPathComponent)",
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
    func provisionAndRun(job: RunnerJob, config: VMConfiguration, runnerPath: URL) async throws -> VMInstance {
        guard let jitConfig = job.jitConfig else {
            throw VMEngineError.missingJITConfig
        }

        let sharedDir = try sharedDirManager.prepareForJob(
            jobId: job.id,
            runnerPath: runnerPath,
            jitConfig: jitConfig
        )
        diagnosticsContexts[job.id] = JobDiagnosticsContext(job: job, runnerName: job.runnerName)
        appendHostLifecycle(
            "Prepared shared job directory with runner \(runnerPath.lastPathComponent)",
            jobId: job.id,
            sharedDirectory: sharedDir
        )

        do {
            return try await bootVM(for: job.id, config: config, sharedDirectory: sharedDir)
        } catch {
            try? sharedDirManager.cleanupJob(jobId: job.id)
            throw error
        }
    }

    func teardown(outcome: JobDiagnosticsOutcome = .unknown()) async throws {
        let diskPath = currentInstance?.diskImagePath
        let jobId = currentInstance?.jobId
        let sharedDirectory = jobId.map { storage.jobsDirectory.appendingPathComponent("\($0)", isDirectory: true) }

        if let jobId, let sharedDirectory {
            appendHostLifecycle("Teardown requested", jobId: jobId, sharedDirectory: sharedDirectory)
        }
        do {
            try await stopVM()
        } catch {
            if let jobId, let sharedDirectory {
                appendHostLifecycle(
                    "VM stop failed: \(error.localizedDescription)",
                    jobId: jobId,
                    sharedDirectory: sharedDirectory
                )
                preserveDiagnosticsIfNeeded(
                    jobId: jobId,
                    sharedDirectory: sharedDirectory,
                    outcome: .failed(reason: "VM stop failed: \(error.localizedDescription)")
                )
            }
            throw error
        }
        if let jobId, let sharedDirectory {
            updateDiagnosticsContext(jobId: jobId) { context in
                context.completedAt = Date()
            }
            appendHostLifecycle("VM stop completed", jobId: jobId, sharedDirectory: sharedDirectory)
            if let diskPath {
                appendHostLifecycle(
                    "Deleting cloned disk \(diskPath.lastPathComponent)",
                    jobId: jobId,
                    sharedDirectory: sharedDirectory
                )
            }
            preserveDiagnosticsIfNeeded(jobId: jobId, sharedDirectory: sharedDirectory, outcome: outcome)
        }

        if let diskPath {
            try diskManager.deleteDisk(at: diskPath)
        }

        if let jobId {
            try sharedDirManager.cleanupJob(jobId: jobId)
        }

        currentInstance = nil
        Log.vm.info("VM teardown complete")
    }

    // MARK: - Cache

    func updateCacheConfig(_ config: CacheConfiguration) {
        self.cacheConfig = config
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
}

enum VMEngineError: LocalizedError {
    case missingJITConfig
    case baseImageMissing
    case verificationFailed(reason: String)
    case unsuitableStorage(reason: String)

    var errorDescription: String? {
        switch self {
        case .missingJITConfig:
            "Job is missing JIT configuration"
        case .baseImageMissing:
            "Base image does not exist on disk"
        case .verificationFailed(let reason):
            "Base image verification failed: \(reason)"
        case .unsuitableStorage(let reason):
            "Storage is not suitable for VM work: \(reason)"
        }
    }
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
