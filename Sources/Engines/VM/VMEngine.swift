import Foundation
import Virtualization

@Observable
@MainActor
final class VMEngine: VMManagerProtocol {
    private let lifecycle = VMLifecycle()
    private let diskManager = DiskImageManager()
    private let imageManager = ImageManager()
    private let sharedDirManager: SharedDirectoryManager
    private let cacheManager: CacheManager
    private let platformStore: PlatformDataStore
    private let baseImageURL: URL

    private(set) var currentInstance: VMInstance?
    private var virtualMachine: VZVirtualMachine?
    private var cacheConfig: CacheConfiguration

    var isRunning: Bool { currentInstance?.state == .running }

    var baseImageExists: Bool {
        FileManager.default.fileExists(atPath: baseImageURL.path)
    }

    var installProgress: Double {
        imageManager.installProgress
    }

    init(
        cacheDirectoryPath: String,
        baseImagePath: String,
        cacheConfig: CacheConfiguration = CacheConfiguration(),
        platformStore: PlatformDataStore = PlatformDataStore()
    ) {
        self.sharedDirManager = SharedDirectoryManager(cacheDirectoryPath: cacheDirectoryPath)
        self.cacheManager = CacheManager(cacheDirectoryPath: cacheDirectoryPath)
        self.platformStore = platformStore
        self.baseImageURL = URL(fileURLWithPath: baseImagePath)
        self.cacheConfig = cacheConfig
    }

    // MARK: - Base Image

    func createBaseImage(from ipsw: URL, config: VMConfiguration) async throws {
        let path = baseImageURL.path
        Log.vm.info("Creating base image at \(path)")

        try diskManager.createSparseDisk(at: baseImageURL, sizeGB: config.diskSizeGB)

        try await imageManager.installMacOS(
            ipsw: ipsw,
            diskPath: baseImageURL,
            config: config,
            platformStore: platformStore
        )

        Log.vm.info("Base image created successfully")
    }

    // MARK: - VM Lifecycle

    func bootVM(
        for jobId: Int64,
        config: VMConfiguration,
        sharedDirectory: URL
    ) async throws -> VMInstance {
        let instanceId = UUID()
        let clonedDiskPath = sharedDirManager.baseDirectory
            .appendingPathComponent("disks")
            .appendingPathComponent("\(instanceId.uuidString).img")

        try diskManager.cloneDisk(from: baseImageURL, to: clonedDiskPath)

        // Prepare cache directory and evict stale entries
        var cacheDirectoryURL: URL? = nil
        if cacheConfig.isEnabled {
            try cacheManager.prepare()
            try cacheManager.evict(retentionDays: cacheConfig.retentionDays)
            try cacheManager.enforceMaxSize(maxSizeGB: cacheConfig.maxSizeGB)
            cacheDirectoryURL = cacheManager.baseDirectory
        }

        let vmConfiguration = try lifecycle.createConfiguration(
            vmConfig: config,
            diskPath: clonedDiskPath,
            platformStore: platformStore,
            sharedDirectoryURL: sharedDirectory,
            cacheDirectoryURL: cacheDirectoryURL
        )

        var instance = VMInstance(
            id: instanceId,
            jobId: jobId,
            diskImagePath: clonedDiskPath,
            startedAt: Date(),
            state: .booting
        )

        currentInstance = instance

        let vm = try await lifecycle.boot(configuration: vmConfiguration)
        virtualMachine = vm

        instance.state = .running
        currentInstance = instance

        Log.vm.info("VM running for job \(jobId)")
        return instance
    }

    func stopVM() async throws {
        guard let vm = virtualMachine else { return }
        currentInstance?.state = .stopping

        try await lifecycle.stop(vm: vm)
        virtualMachine = nil
        currentInstance?.state = .stopped

        Log.vm.info("VM stopped")
    }

    // MARK: - Full Job Flow

    func provisionAndRun(job: RunnerJob, config: VMConfiguration, runnerPath: URL) async throws {
        guard let jitConfig = job.jitConfig else {
            throw VMEngineError.missingJITConfig
        }

        let sharedDir = try sharedDirManager.prepareForJob(
            jobId: job.id,
            runnerPath: runnerPath,
            jitConfig: jitConfig
        )

        _ = try await bootVM(for: job.id, config: config, sharedDirectory: sharedDir)
    }

    func teardown() async throws {
        let diskPath = currentInstance?.diskImagePath
        let jobId = currentInstance?.jobId

        try await stopVM()

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

    func clearCache() throws {
        try cacheManager.clear()
    }

    func cacheSizeBytes() throws -> Int64 {
        try cacheManager.currentSizeBytes()
    }
}

enum VMEngineError: LocalizedError {
    case missingJITConfig

    var errorDescription: String? {
        switch self {
        case .missingJITConfig:
            "Job is missing JIT configuration"
        }
    }
}
