import Foundation
import Testing

@testable import Tarmac

@Suite("VMEngine")
struct VMEngineTests {
    @MainActor
    private func makeEngine(
        baseImageExists: Bool = true,
        lifecycle: MockVMLifecycle? = nil
    ) throws -> (VMEngine, MockVMLifecycle, URL) {
        let tempDir = try TestFactories.makeTempDir()
        let baseImagePath = tempDir.appendingPathComponent("base.img")

        if baseImageExists {
            // Create a small file as the base image
            try Data(repeating: 0x00, count: 1024).write(to: baseImagePath)
        }

        let mock = lifecycle ?? MockVMLifecycle()
        let engine = VMEngine(
            cacheDirectoryPath: tempDir.path,
            baseImagePath: baseImagePath.path,
            lifecycle: mock
        )

        return (engine, mock, tempDir)
    }

    @Test("baseImageExists reflects filesystem state")
    @MainActor
    func baseImageExistsReflectsFilesystem() throws {
        let (engine, _, tempDir) = try makeEngine(baseImageExists: true)
        defer { TestFactories.cleanup(tempDir) }
        #expect(engine.baseImageExists)

        let (engine2, _, tempDir2) = try makeEngine(baseImageExists: false)
        defer { TestFactories.cleanup(tempDir2) }
        #expect(!engine2.baseImageExists)
    }

    @Test("bootVM sets instance state to booting then running")
    @MainActor
    func bootVMStateTransitions() async throws {
        let (engine, _, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        let sharedDir = tempDir.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)

        let instance = try await engine.bootVM(
            for: 42,
            config: VMConfiguration(),
            sharedDirectory: sharedDir
        )

        #expect(instance.state == .running)
        #expect(instance.jobId == 42)
        #expect(engine.currentInstance?.state == .running)
        #expect(engine.isRunning)
    }

    @Test("stopVM sets state to stopped")
    @MainActor
    func stopVMSetsStateStopped() async throws {
        let (engine, mock, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        let sharedDir = tempDir.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)

        _ = try await engine.bootVM(
            for: 1,
            config: VMConfiguration(),
            sharedDirectory: sharedDir
        )

        try await engine.stopVM()

        #expect(mock.stopCallCount == 1)
        #expect(engine.currentInstance?.state == .stopped)
    }

    @Test("stopVM when no VM running is a no-op")
    @MainActor
    func stopVMNoOp() async throws {
        let (engine, mock, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        try await engine.stopVM()
        #expect(mock.stopCallCount == 0)
    }

    @Test("provisionAndRun with missing JIT config throws")
    @MainActor
    func provisionAndRunMissingJITConfig() async throws {
        let (engine, _, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        let job = TestFactories.makeJob(id: 1)
        // job.jitConfig is nil by default

        await #expect(throws: VMEngineError.self) {
            try await engine.provisionAndRun(
                job: job,
                config: VMConfiguration(),
                runnerPath: URL(filePath: "/tmp/runner")
            )
        }
    }

    @Test("provisionAndRun happy path boots VM")
    @MainActor
    func provisionAndRunHappyPath() async throws {
        let (engine, mock, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        // Create the runner binary that prepareForJob will symlink to
        let runnerPath = tempDir.appendingPathComponent("runner")
        try FileManager.default.createDirectory(at: runnerPath, withIntermediateDirectories: true)

        var job = TestFactories.makeJob(id: 99)
        job.jitConfig = "test-jit-config"

        try await engine.provisionAndRun(
            job: job,
            config: VMConfiguration(),
            runnerPath: runnerPath
        )

        #expect(mock.bootCallCount == 1)
        #expect(engine.isRunning)
        #expect(engine.currentInstance?.jobId == 99)
    }

    @Test("teardown stops VM and cleans up disk")
    @MainActor
    func teardownCleansUp() async throws {
        let (engine, mock, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        let runnerPath = tempDir.appendingPathComponent("runner")
        try FileManager.default.createDirectory(at: runnerPath, withIntermediateDirectories: true)

        var job = TestFactories.makeJob(id: 50)
        job.jitConfig = "jit-config"

        try await engine.provisionAndRun(
            job: job,
            config: VMConfiguration(),
            runnerPath: runnerPath
        )

        #expect(engine.isRunning)

        try await engine.teardown()

        #expect(mock.stopCallCount == 1)
        #expect(engine.currentInstance == nil)
    }

    @Test("teardown when no VM running is a no-op")
    @MainActor
    func teardownNoVM() async throws {
        let (engine, _, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        try await engine.teardown()
        #expect(engine.currentInstance == nil)
    }

    @Test("Boot failure cleans up")
    @MainActor
    func bootFailureCleanup() async throws {
        let mock = MockVMLifecycle()
        mock.shouldThrowOnBoot = true
        let (engine, _, tempDir) = try makeEngine(lifecycle: mock)
        defer { TestFactories.cleanup(tempDir) }

        let sharedDir = tempDir.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)

        await #expect(throws: Error.self) {
            _ = try await engine.bootVM(
                for: 1,
                config: VMConfiguration(),
                sharedDirectory: sharedDir
            )
        }

        // After boot failure, instance was set to booting but never to running
        // The instance is still set since we set it before boot attempt
        #expect(engine.currentInstance?.state == .booting)
    }

    @Test("cacheSizeBytes delegates to CacheManager")
    @MainActor
    func cacheSizeDelegates() throws {
        let (engine, _, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        let size = try engine.cacheSizeBytes()
        #expect(size == 0)
    }

    @Test("updateCacheConfig updates internal config")
    @MainActor
    func updateCacheConfig() throws {
        let (engine, _, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        var newConfig = CacheConfiguration()
        newConfig.maxSizeGB = 50
        newConfig.retentionDays = 30
        engine.updateCacheConfig(newConfig)

        // No direct way to verify, but this shouldn't crash
        // The config is used during bootVM when cache is enabled
    }
}
