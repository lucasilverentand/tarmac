import Foundation

@MainActor
final class VMControlHandler: VMControlHandling {
    static let controlJobId: Int64 = 0

    private let engineProvider: () -> VMEngine?
    private let vmConfiguration: () -> VMConfiguration
    private let storageRootPath: () -> String
    private let baseImagePath: () -> String
    private let platformDirectoryPath: () -> String
    private let cacheConfig: () -> CacheConfiguration
    private let diagnosticsRetention: () -> DiagnosticsRetentionConfiguration
    private let hasActiveRunnerJob: () -> Bool

    private var controlSharedDirectory: URL?

    init(
        engineProvider: @escaping () -> VMEngine?,
        vmConfiguration: @escaping () -> VMConfiguration,
        storageRootPath: @escaping () -> String,
        baseImagePath: @escaping () -> String,
        platformDirectoryPath: @escaping () -> String,
        cacheConfig: @escaping () -> CacheConfiguration,
        diagnosticsRetention: @escaping () -> DiagnosticsRetentionConfiguration,
        hasActiveRunnerJob: @escaping () -> Bool
    ) {
        self.engineProvider = engineProvider
        self.vmConfiguration = vmConfiguration
        self.storageRootPath = storageRootPath
        self.baseImagePath = baseImagePath
        self.platformDirectoryPath = platformDirectoryPath
        self.cacheConfig = cacheConfig
        self.diagnosticsRetention = diagnosticsRetention
        self.hasActiveRunnerJob = hasActiveRunnerJob
    }

    func health() -> VMControlHealthResponse {
        VMControlHealthResponse(status: "ok", service: "tarmac-vm-control")
    }

    func vmState() -> VMControlVMResponse {
        guard let engine = engineProvider() else {
            let storage = StorageManager(rootPath: storageRootPath())
            return VMControlVMResponse(
                instance: nil,
                isRunning: false,
                baseImageExists: FileManager.default.fileExists(atPath: baseImagePath()),
                baseImageVerified: storage.isBaseImageVerified()
            )
        }
        return snapshot(using: engine)
    }

    func boot() async throws -> VMControlVMResponse {
        try ensureCanMutate()
        let engine = try resolveEngine()

        guard engine.baseImageExists else {
            throw VMControlError.baseImageMissing
        }
        guard !engine.isRunning else {
            throw VMControlError.vmAlreadyRunning
        }

        let sharedDirectory = try prepareControlSharedDirectory()
        controlSharedDirectory = sharedDirectory

        _ = try await engine.bootVM(
            for: Self.controlJobId,
            config: vmConfiguration(),
            sharedDirectory: sharedDirectory
        )

        return snapshot(using: engine)
    }

    func stop() async throws -> VMControlVMResponse {
        try ensureCanMutate()
        let engine = try resolveEngine()

        guard engine.isRunning else {
            throw VMControlError.vmNotRunning
        }

        try await engine.stopVM()
        return snapshot(using: engine)
    }

    func teardown() async throws -> VMControlVMResponse {
        try ensureCanMutate()
        let engine = try resolveEngine()

        guard engine.currentInstance != nil || engine.isRunning else {
            throw VMControlError.vmNotRunning
        }

        try await engine.teardown(outcome: .unknown(), policy: .full)
        controlSharedDirectory = nil
        return snapshot(using: engine)
    }

    private func ensureCanMutate() throws {
        if hasActiveRunnerJob() {
            throw VMControlError.queueBusy
        }
    }

    private func resolveEngine() throws -> VMEngine {
        guard let engine = engineProvider() else {
            throw VMControlError.vmEngineUnavailable
        }
        return engine
    }

    private func snapshot(using engine: VMEngine) -> VMControlVMResponse {
        VMControlVMResponse(
            instance: engine.currentInstance,
            isRunning: engine.isRunning,
            baseImageExists: engine.baseImageExists,
            baseImageVerified: engine.baseImageVerified
        )
    }

    private func prepareControlSharedDirectory() throws -> URL {
        let storage = StorageManager(rootPath: storageRootPath())
        try storage.prepareBaseDirectories()
        let directory = storage.jobsDirectory
            .appendingPathComponent("control-rest", isDirectory: true)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
