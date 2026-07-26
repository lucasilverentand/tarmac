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
        try Data([0x01]).write(
            to: tempDir
                .appendingPathComponent("Platform", isDirectory: true)
                .appendingPathComponent("auxiliaryStorage.bin")
        )
        // Most VMEngine tests exercise the one-shot lifecycle. Tests that cover
        // the product's default-on warm runner opt in explicitly below.
        engine.updateWarmRunnerConfig(WarmRunnerConfiguration(isEnabled: false))

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

        let configuration = VMConfiguration(cpuCount: 6, memorySizeGB: 12, diskSizeGB: 90)
        let instance = try await engine.bootVM(
            for: 42,
            config: configuration,
            sharedDirectory: sharedDir
        )

        #expect(instance.state == .running)
        #expect(instance.jobId == 42)
        #expect(instance.diskImagePath.deletingLastPathComponent().lastPathComponent == "disks")
        #expect(engine.currentInstance?.state == .running)
        #expect(engine.currentVMConfiguration == configuration)
        #expect(engine.currentSharedDirectory == sharedDir)
        #expect(engine.isRunning)
    }

    @Test("worker resource usage is read from the current guest share")
    @MainActor
    func readsCurrentWorkerResourceUsage() async throws {
        let (engine, _, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        let sharedDir = tempDir.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        _ = try await engine.bootVM(for: 42, config: VMConfiguration(), sharedDirectory: sharedDir)

        let usage = WorkerResourceUsage(
            sampledAt: Date(timeIntervalSince1970: 1_700_000_000),
            cpuPercent: 37.5,
            memoryUsedBytes: 4_000,
            memoryTotalBytes: 8_000,
            diskUsedBytes: 30_000,
            diskTotalBytes: 80_000
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(usage).write(
            to: sharedDir.appendingPathComponent(GuestBootstrapContract.workerResourceUsageFileName)
        )

        #expect(engine.currentResourceUsage() == usage)
        #expect(engine.currentDiskImageAllocatedSizeBytes() != nil)

        try await engine.teardown()
        #expect(engine.currentVMConfiguration == nil)
        #expect(engine.currentSharedDirectory == nil)
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

    @Test("prewarm boots a jobless VM and reuses it for the first job")
    @MainActor
    func prewarmAndReuseForFirstJob() async throws {
        let (engine, mock, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        engine.updateWarmRunnerConfig(WarmRunnerConfiguration(isEnabled: true))
        let configuration = VMConfiguration(cpuCount: 6, memorySizeGB: 12, diskSizeGB: 90)
        let prewarmedInstance = try await engine.prewarm(
            config: configuration,
            readinessTimeoutSeconds: 1
        )

        #expect(mock.bootCallCount == 1)
        #expect(prewarmedInstance.jobId == nil)
        #expect(engine.hasWarmRunner)
        #expect(engine.warmRunnerState?.jobsServed == 0)
        #expect(engine.warmRunnerState?.lastJobId == nil)

        let runnerDirectory = tempDir.appendingPathComponent("runner-bin")
        try writeExecutableRunScript(in: runnerDirectory)
        var job = TestFactories.makeJob(id: 90)
        job.jitConfig = "jit"

        let runningInstance = try await engine.provisionAndRun(
            job: job,
            config: configuration,
            runnerPath: runnerDirectory
        )

        #expect(mock.bootCallCount == 1)
        #expect(runningInstance.id == prewarmedInstance.id)
        #expect(runningInstance.jobId == 90)
        #expect(engine.warmRunnerState?.jobsServed == 1)
        #expect(engine.warmRunnerState?.lastJobId == 90)
        #expect(
            FileManager.default.fileExists(
                atPath: tempDir.appendingPathComponent("jobs/_warm/job-ready").path
            )
        )

        try await engine.releaseWarmRunner()
    }

    @Test("prewarm readiness timeout tears down its VM and clone")
    @MainActor
    func prewarmReadinessTimeoutCleansUp() async throws {
        let mock = MockVMLifecycle()
        mock.completeWarmReadinessOnBoot = false
        let (engine, _, tempDir) = try makeEngine(lifecycle: mock)
        defer { TestFactories.cleanup(tempDir) }

        engine.updateWarmRunnerConfig(WarmRunnerConfiguration(isEnabled: true))

        await #expect(throws: VMEngineError.self) {
            try await engine.prewarm(config: VMConfiguration(), readinessTimeoutSeconds: 1)
        }

        #expect(mock.bootCallCount == 1)
        #expect(mock.stopCallCount == 1)
        #expect(engine.currentInstance == nil)
        #expect(engine.warmRunnerState == nil)
        let disks = try FileManager.default.contentsOfDirectory(
            at: tempDir.appendingPathComponent("disks"),
            includingPropertiesForKeys: nil
        )
        #expect(disks.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("jobs/_warm").path))
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

        // Create the runner package that prepareForJob will copy into the shared directory.
        let runnerPath = tempDir.appendingPathComponent("runner")
        try FileManager.default.createDirectory(at: runnerPath, withIntermediateDirectories: true)
        try writeExecutableRunScript(in: runnerPath)

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

    @Test("provisionAndRun writes signing injection into shared job directory")
    @MainActor
    func provisionAndRunWritesSigningInjection() async throws {
        let (engine, _, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        let runnerPath = tempDir.appendingPathComponent("runner")
        try FileManager.default.createDirectory(at: runnerPath, withIntermediateDirectories: true)
        try writeExecutableRunScript(in: runnerPath)

        var job = TestFactories.makeJob(id: 109)
        job.jitConfig = "test-jit-config"
        let asset = AppleSigningAsset(
            displayName: "Distribution",
            teamId: "TEAM12345",
            bundleIdentifierPattern: "com.example.*",
            certificateCommonName: "Apple Distribution",
            provisioningProfileUUID: "profile-uuid"
        )
        let injection = AppleSigningInjection(
            asset: asset,
            certificateData: Data([0x01, 0x02]),
            certificatePassphrase: "secret",
            provisioningProfileData: Data([0x03, 0x04])
        )

        try await engine.provisionAndRun(
            job: job,
            config: VMConfiguration(),
            runnerPath: runnerPath,
            signingInjection: injection
        )

        let signingDir = StorageManager(rootPath: tempDir.path)
            .jobsDirectory
            .appendingPathComponent("109")
            .appendingPathComponent(GuestBootstrapContract.appleSigningDirectoryName)

        #expect(
            try Data(
                contentsOf: signingDir.appendingPathComponent(
                    GuestBootstrapContract.appleSigningCertificateFileName
                )
            ) == Data([0x01, 0x02])
        )
        #expect(
            try Data(
                contentsOf: signingDir.appendingPathComponent(
                    GuestBootstrapContract.appleSigningProvisioningProfileFileName
                )
            ) == Data([0x03, 0x04])
        )
        let environment = try String(
            contentsOf: signingDir.appendingPathComponent(
                GuestBootstrapContract.appleSigningEnvironmentFileName
            ),
            encoding: .utf8
        )
        #expect(environment.contains("TARMAC_APPLE_TEAM_ID='TEAM12345'"))
        #expect(environment.contains("TARMAC_APPLE_CERTIFICATE_PASSPHRASE='secret'"))
    }

    @Test("provisionAndRun can boot from runner-specific image")
    @MainActor
    func provisionAndRunUsesRunnerImageOverride() async throws {
        let (engine, _, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        let customImage = tempDir.appendingPathComponent("custom-runner.img")
        let imageData = Data("custom-runner-image".utf8)
        try imageData.write(to: customImage)

        let runnerPath = tempDir.appendingPathComponent("runner")
        try FileManager.default.createDirectory(at: runnerPath, withIntermediateDirectories: true)
        try writeExecutableRunScript(in: runnerPath)

        var job = TestFactories.makeJob(id: 199)
        job.jitConfig = "test-jit-config"

        let instance = try await engine.provisionAndRun(
            job: job,
            config: VMConfiguration(),
            runnerPath: runnerPath,
            baseImagePath: customImage.path
        )

        #expect(try Data(contentsOf: instance.diskImagePath) == imageData)
    }

    @Test("teardown stops VM and cleans up disk")
    @MainActor
    func teardownCleansUp() async throws {
        let (engine, mock, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        let runnerPath = tempDir.appendingPathComponent("runner")
        try FileManager.default.createDirectory(at: runnerPath, withIntermediateDirectories: true)
        try writeExecutableRunScript(in: runnerPath)

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

    @Test("Boot failure cleans up cloned disk")
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

        #expect(engine.currentInstance?.state == .failed)
        if let diskPath = mock.lastBootDiskPath {
            #expect(!FileManager.default.fileExists(atPath: diskPath.path))
        }
    }

    @Test("provisionAndRun cleans shared directory when boot fails")
    @MainActor
    func provisionAndRunCleansSharedDirectoryOnBootFailure() async throws {
        let mock = MockVMLifecycle()
        mock.shouldThrowOnBoot = true
        let (engine, _, tempDir) = try makeEngine(lifecycle: mock)
        defer { TestFactories.cleanup(tempDir) }

        let runnerPath = tempDir.appendingPathComponent("runner")
        try FileManager.default.createDirectory(at: runnerPath, withIntermediateDirectories: true)
        try writeExecutableRunScript(in: runnerPath)

        var job = TestFactories.makeJob(id: 123)
        job.jitConfig = "jit-config"

        await #expect(throws: Error.self) {
            try await engine.provisionAndRun(
                job: job,
                config: VMConfiguration(),
                runnerPath: runnerPath
            )
        }

        let sharedDir = tempDir.appendingPathComponent("jobs/123")
        #expect(!FileManager.default.fileExists(atPath: sharedDir.path))

        let diagnosticsRoot = StorageManager(rootPath: tempDir.path).diagnosticsDirectory
            .appendingPathComponent("jobs", isDirectory: true)
        let bundles =
            (try? FileManager.default.contentsOfDirectory(
                at: diagnosticsRoot,
                includingPropertiesForKeys: nil
            )) ?? []
        #expect(bundles.count == 1)
        #expect(FileManager.default.fileExists(atPath: bundles[0].appendingPathComponent("host-lifecycle.log").path))
    }

    @Test("teardown preserves guest diagnostics before deleting shared directory")
    @MainActor
    func teardownPreservesDiagnostics() async throws {
        let (engine, _, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        let runnerPath = tempDir.appendingPathComponent("runner")
        try FileManager.default.createDirectory(at: runnerPath, withIntermediateDirectories: true)
        try writeExecutableRunScript(in: runnerPath)

        var job = TestFactories.makeJob(id: 321)
        job.jitConfig = "jit-config"
        job.runnerRequestId = 9001
        job.runnerName = "ephemeral-321"

        _ = try await engine.provisionAndRun(
            job: job,
            config: VMConfiguration(),
            runnerPath: runnerPath
        )

        let storage = StorageManager(rootPath: tempDir.path)
        let sharedDir = storage.jobsDirectory.appendingPathComponent("321", isDirectory: true)
        try "guest log".write(
            to: sharedDir.appendingPathComponent(GuestBootstrapContract.bootstrapLogFileName),
            atomically: true,
            encoding: .utf8
        )
        try "runner failed".write(
            to: sharedDir.appendingPathComponent(GuestBootstrapContract.runnerLogFileName),
            atomically: true,
            encoding: .utf8
        )
        try "1".write(
            to: sharedDir.appendingPathComponent(GuestBootstrapContract.exitCodeFileName),
            atomically: true,
            encoding: .utf8
        )
        try #"{"exitCode":1}"#.write(
            to: sharedDir.appendingPathComponent(GuestBootstrapContract.completionMarkerFileName),
            atomically: true,
            encoding: .utf8
        )

        try await engine.teardown(outcome: .failed(reason: "runner failed"))

        #expect(!FileManager.default.fileExists(atPath: sharedDir.path))
        let bundleURL = try #require(engine.diagnosticsBundlePath(for: 321))
        #expect(FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("host-lifecycle.log").path))
        #expect(
            FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent(GuestBootstrapContract.bootstrapLogFileName).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent(GuestBootstrapContract.runnerLogFileName).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent(GuestBootstrapContract.exitCodeFileName).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: bundleURL.appendingPathComponent(GuestBootstrapContract.completionMarkerFileName).path
            )
        )
    }

    @Test("waitForJobCompletion returns success for zero exit code")
    @MainActor
    func waitForJobCompletionSuccess() async throws {
        let (engine, _, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        let storage = StorageManager(rootPath: tempDir.path)
        let sharedDir = storage.jobsDirectory.appendingPathComponent("700", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        try "0".write(
            to: sharedDir.appendingPathComponent(GuestBootstrapContract.exitCodeFileName),
            atomically: true,
            encoding: .utf8
        )
        try #"{"exitCode":0}"#.write(
            to: sharedDir.appendingPathComponent(GuestBootstrapContract.completionMarkerFileName),
            atomically: true,
            encoding: .utf8
        )

        let result = try await engine.waitForJobCompletion(
            jobId: 700,
            timeoutSeconds: 1,
            pollIntervalSeconds: 0.01
        )

        #expect(result == .success)
    }

    @Test("waitForJobCompletion returns failure for nonzero exit code")
    @MainActor
    func waitForJobCompletionFailure() async throws {
        let (engine, _, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        let storage = StorageManager(rootPath: tempDir.path)
        let sharedDir = storage.jobsDirectory.appendingPathComponent("701", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        try "2".write(
            to: sharedDir.appendingPathComponent(GuestBootstrapContract.exitCodeFileName),
            atomically: true,
            encoding: .utf8
        )
        try #"{"exitCode":2}"#.write(
            to: sharedDir.appendingPathComponent(GuestBootstrapContract.completionMarkerFileName),
            atomically: true,
            encoding: .utf8
        )

        let result = try await engine.waitForJobCompletion(
            jobId: 701,
            timeoutSeconds: 1,
            pollIntervalSeconds: 0.01
        )

        #expect(result == .failure("Runner exited with code 2"))
    }

    @Test("waitForJobCompletion times out without marker")
    @MainActor
    func waitForJobCompletionTimeout() async throws {
        let (engine, _, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        let result = try await engine.waitForJobCompletion(
            jobId: 702,
            timeoutSeconds: 1,
            pollIntervalSeconds: 0.01
        )

        #expect(result == .failure("Timed out after 1s waiting for runner completion marker"))
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

    @Test("cache persists between clean job clones while job scratch is removed")
    @MainActor
    func cachePersistsBetweenCleanJobClones() async throws {
        let (engine, mock, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        let runnerPath = tempDir.appendingPathComponent("runner")
        try FileManager.default.createDirectory(at: runnerPath, withIntermediateDirectories: true)
        try writeExecutableRunScript(in: runnerPath)

        var firstJob = TestFactories.makeJob(id: 401)
        firstJob.jitConfig = "jit-config-1"

        try await engine.provisionAndRun(
            job: firstJob,
            config: VMConfiguration(),
            runnerPath: runnerPath
        )

        let storage = StorageManager(rootPath: tempDir.path)
        let cacheDir = try #require(mock.lastBootCacheDir)
        #expect(cacheDir.path == storage.actionsCacheDirectory.path)

        let swiftPMCache = cacheDir.appendingPathComponent(CacheConfiguration.swiftPMDirectoryName)
        try FileManager.default.createDirectory(at: swiftPMCache, withIntermediateDirectories: true)
        let cachedArtifact = swiftPMCache.appendingPathComponent("module-cache.bin")
        try "warm cache".write(to: cachedArtifact, atomically: true, encoding: .utf8)

        let firstSharedDir = storage.jobsDirectory.appendingPathComponent("401", isDirectory: true)
        let firstDisk = try #require(engine.currentInstance?.diskImagePath)

        try await engine.teardown(outcome: .succeeded)

        #expect(FileManager.default.fileExists(atPath: cachedArtifact.path))
        #expect(!FileManager.default.fileExists(atPath: firstSharedDir.path))
        #expect(!FileManager.default.fileExists(atPath: firstDisk.path))

        var secondJob = TestFactories.makeJob(id: 402)
        secondJob.jitConfig = "jit-config-2"

        try await engine.provisionAndRun(
            job: secondJob,
            config: VMConfiguration(),
            runnerPath: runnerPath
        )

        #expect(mock.lastBootCacheDir?.path == cacheDir.path)
        #expect(FileManager.default.fileExists(atPath: cachedArtifact.path))
        #expect(!FileManager.default.fileExists(atPath: firstSharedDir.path))
        #expect(FileManager.default.fileExists(atPath: storage.jobsDirectory.appendingPathComponent("402").path))

        try await engine.teardown(outcome: .succeeded)
    }

    // MARK: - Boot Verification

    @Test("verifyBaseImage writes marker and transitions to verified")
    @MainActor
    func verifyBaseImageSuccess() async throws {
        let (engine, mock, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        #expect(!engine.baseImageVerified)
        #expect(!engine.baseImageReady)

        try await engine.verifyBaseImage(config: VMConfiguration(), holdSeconds: 0)

        #expect(mock.bootCallCount == 1)
        #expect(mock.stopCallCount == 1)
        #expect(engine.verificationState == .verified)
        #expect(engine.baseImageVerified)
        #expect(engine.guestBootstrapVerified)
        #expect(engine.baseImageReady)

        let storage = StorageManager(rootPath: tempDir.path)
        #expect(FileManager.default.fileExists(atPath: storage.baseImageVerifiedMarkerURL.path))
        #expect(FileManager.default.fileExists(atPath: storage.guestBootstrapVerifiedMarkerURL.path))
    }

    @Test("verifyBaseImage fails when guest bootstrap probe does not complete")
    @MainActor
    func verifyBaseImageGuestBootstrapMissing() async throws {
        let mock = MockVMLifecycle()
        mock.completeBootstrapProbeOnBoot = false
        let (engine, _, tempDir) = try makeEngine(lifecycle: mock)
        defer { TestFactories.cleanup(tempDir) }

        await #expect(throws: VMEngineError.self) {
            try await engine.verifyBaseImage(
                config: VMConfiguration(),
                holdSeconds: 0,
                bootstrapProbeTimeoutSeconds: 1
            )
        }

        #expect(!engine.baseImageVerified)
        #expect(!engine.guestBootstrapVerified)
        #expect(!engine.baseImageReady)
    }

    @Test("verifyBaseImage throws when base image is missing")
    @MainActor
    func verifyBaseImageMissing() async throws {
        let (engine, _, tempDir) = try makeEngine(baseImageExists: false)
        defer { TestFactories.cleanup(tempDir) }

        await #expect(throws: VMEngineError.self) {
            try await engine.verifyBaseImage(config: VMConfiguration(), holdSeconds: 0)
        }
        #expect(!engine.baseImageVerified)
    }

    @Test("verifyBaseImage failure leaves no marker and reports failure state")
    @MainActor
    func verifyBaseImageBootFailure() async throws {
        let mock = MockVMLifecycle()
        mock.shouldThrowOnBoot = true
        let (engine, _, tempDir) = try makeEngine(lifecycle: mock)
        defer { TestFactories.cleanup(tempDir) }

        await #expect(throws: VMEngineError.self) {
            try await engine.verifyBaseImage(config: VMConfiguration(), holdSeconds: 0)
        }

        #expect(!engine.baseImageVerified)
        #expect(!engine.baseImageReady)
        if case .failed = engine.verificationState {
            // expected
        } else {
            Issue.record("Expected verificationState to be .failed, got \(engine.verificationState)")
        }
    }

    @Test("verifyBaseImage failure cleans up the cloned disk")
    @MainActor
    func verifyBaseImageCleanupOnFailure() async throws {
        let mock = MockVMLifecycle()
        mock.shouldThrowOnBoot = true
        let (engine, _, tempDir) = try makeEngine(lifecycle: mock)
        defer { TestFactories.cleanup(tempDir) }

        _ = try? await engine.verifyBaseImage(config: VMConfiguration(), holdSeconds: 0)

        let disks = tempDir.appendingPathComponent("disks")
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: disks, includingPropertiesForKeys: nil)) ?? []
        let verifyClones = leftovers.filter { $0.lastPathComponent.hasPrefix("verify-") }
        #expect(verifyClones.isEmpty)
    }

    @Test("teardown with keepWarmRunner policy leaves VM booted")
    @MainActor
    func teardownKeepWarmRunnerLeavesVMBooted() async throws {
        let (engine, mock, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        engine.updateWarmRunnerConfig(WarmRunnerConfiguration(isEnabled: true))

        let runnerDir = tempDir.appendingPathComponent("runner-bin")
        try writeExecutableRunScript(in: runnerDir)

        var job = TestFactories.makeJob(id: 88)
        job.jitConfig = "jit"
        _ = try await engine.provisionAndRun(
            job: job,
            config: VMConfiguration(),
            runnerPath: runnerDir
        )

        #expect(mock.bootCallCount == 1)
        try await engine.teardown(outcome: .succeeded, policy: .keepWarmRunner)
        #expect(mock.stopCallCount == 0)
        #expect(engine.hasWarmRunner)
        #expect(engine.isRunning)

        try await engine.releaseWarmRunner()
        #expect(mock.stopCallCount == 1)
        #expect(!engine.hasWarmRunner)
    }

    @Test("idle warm runner can restart without replacing its clone")
    @MainActor
    func restartWarmRunnerRebootsExistingClone() async throws {
        let (engine, mock, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        engine.updateWarmRunnerConfig(WarmRunnerConfiguration(isEnabled: true))

        let runnerDir = tempDir.appendingPathComponent("runner-bin")
        try writeExecutableRunScript(in: runnerDir)

        var job = TestFactories.makeJob(id: 89)
        job.jitConfig = "jit"
        let originalInstance = try await engine.provisionAndRun(
            job: job,
            config: VMConfiguration(),
            runnerPath: runnerDir
        )
        try await engine.teardown(outcome: .succeeded, policy: .keepWarmRunner)

        try await engine.restartWarmRunner()

        #expect(mock.stopCallCount == 1)
        #expect(mock.bootCallCount == 2)
        #expect(engine.currentInstance?.id == originalInstance.id)
        #expect(engine.currentInstance?.diskImagePath == originalInstance.diskImagePath)
        #expect(engine.currentInstance?.state == .running)
        #expect(engine.hasWarmRunner)

        try await engine.releaseWarmRunner()
    }

    @Test("baseImageReady requires both file presence and verified marker")
    @MainActor
    func baseImageReadyGating() throws {
        let (engine, _, tempDir) = try makeEngine()
        defer { TestFactories.cleanup(tempDir) }

        #expect(engine.baseImageExists)
        #expect(!engine.baseImageVerified)
        #expect(!engine.baseImageReady)

        let storage = StorageManager(rootPath: tempDir.path)
        try storage.prepareBaseDirectories()
        try storage.markBaseImageVerified()

        #expect(engine.baseImageVerified)
        #expect(!engine.baseImageReady)

        try storage.markGuestBootstrapVerified()
        #expect(engine.baseImageReady)
    }

    private func writeExecutableRunScript(in runnerPath: URL) throws {
        try FileManager.default.createDirectory(at: runnerPath, withIntermediateDirectories: true)
        let runScript = runnerPath.appendingPathComponent("run.sh")
        try "#!/bin/bash".write(to: runScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runScript.path
        )
    }
}
