import Foundation
import Testing

@testable import Tarmac

@Suite("SharedDirectoryManager")
struct SharedDirectoryManagerTests {
    @Test("prepareForJob creates directory with runner package and jitconfig")
    func prepareForJobCreatesStructure() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let runnerDir = tempDir.appendingPathComponent("runner-bin")
        try makeRunnerPackage(at: runnerDir)

        let manager = SharedDirectoryManager(cacheDirectoryPath: tempDir.path)
        let jobDir = try manager.prepareForJob(
            jobId: 42,
            runnerPath: runnerDir,
            guestConfig: .jit(config: "test-jit-config-data")
        )

        let runnerCopy = jobDir.appendingPathComponent(GuestBootstrapContract.runnerDirectoryName)
        let runScript = runnerCopy.appendingPathComponent(GuestBootstrapContract.runnerEntrypointName)
        let originalRunScript = runnerCopy.appendingPathComponent(
            GuestBootstrapContract.originalRunnerEntrypointName
        )
        #expect(FileManager.default.fileExists(atPath: runnerCopy.path))
        #expect(FileManager.default.fileExists(atPath: runScript.path))
        #expect(FileManager.default.isExecutableFile(atPath: runScript.path))
        #expect(FileManager.default.isExecutableFile(atPath: originalRunScript.path))

        let wrapper = try String(contentsOf: runScript, encoding: .utf8)
        #expect(wrapper.contains(GuestBootstrapContract.workerResourceUsageFileName))
        #expect(wrapper.contains(GuestBootstrapContract.workerResourceUsagePIDFileName))
        #expect(wrapper.contains("exec \"${ORIGINAL_RUNNER}\" \"$@\""))
        #expect(wrapper.contains("/usr/bin/top -l 1"))
        #expect(wrapper.contains("/usr/bin/vm_stat"))

        let syntaxCheck = Process()
        syntaxCheck.executableURL = URL(fileURLWithPath: "/bin/bash")
        syntaxCheck.arguments = ["-n", runScript.path]
        try syntaxCheck.run()
        syntaxCheck.waitUntilExit()
        #expect(syntaxCheck.terminationStatus == 0)
    }

    @Test("prepareForJob writes correct jitconfig content")
    func jitconfigContent() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let runnerDir = tempDir.appendingPathComponent("runner-bin")
        try makeRunnerPackage(at: runnerDir)

        let manager = SharedDirectoryManager(cacheDirectoryPath: tempDir.path)
        let jobDir = try manager.prepareForJob(
            jobId: 100,
            runnerPath: runnerDir,
            guestConfig: .jit(config: "my-encoded-config")
        )

        let jitPath = jobDir.appendingPathComponent(GuestBootstrapContract.jitConfigFileName)
        let content = try String(contentsOf: jitPath, encoding: .utf8)
        #expect(content == "my-encoded-config")
    }

    @Test("cleanupJob removes directory")
    func cleanupJobRemovesDir() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let runnerDir = tempDir.appendingPathComponent("runner-bin")
        try makeRunnerPackage(at: runnerDir)

        let manager = SharedDirectoryManager(cacheDirectoryPath: tempDir.path)
        _ = try manager.prepareForJob(jobId: 55, runnerPath: runnerDir, guestConfig: .jit(config: "cfg"))

        try manager.cleanupJob(jobId: 55)

        let jobDir = tempDir.appendingPathComponent("jobs/55")
        #expect(!FileManager.default.fileExists(atPath: jobDir.path))
    }

    @Test("cleanupJob is safe when directory doesn't exist")
    func cleanupJobSafeOnMissing() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let manager = SharedDirectoryManager(cacheDirectoryPath: tempDir.path)

        // Should not throw
        try manager.cleanupJob(jobId: 999)
    }

    @Test("prepareForJob fails when runner package is missing")
    func missingRunnerPackageFails() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let manager = SharedDirectoryManager(cacheDirectoryPath: tempDir.path)

        #expect(throws: SharedDirectoryError.self) {
            try manager.prepareForJob(
                jobId: 1,
                runnerPath: tempDir.appendingPathComponent("missing-runner"),
                guestConfig: .jit(config: "cfg")
            )
        }
    }

    @Test("prepareForJob fails when runner entrypoint is missing")
    func missingRunnerEntrypointFails() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let runnerDir = tempDir.appendingPathComponent("runner-bin")
        try FileManager.default.createDirectory(at: runnerDir, withIntermediateDirectories: true)

        let manager = SharedDirectoryManager(cacheDirectoryPath: tempDir.path)

        #expect(throws: SharedDirectoryError.self) {
            try manager.prepareForJob(jobId: 1, runnerPath: runnerDir, guestConfig: .jit(config: "cfg"))
        }
    }

    @Test("prepareForJob fails when jitconfig is empty")
    func emptyJITConfigFails() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let runnerDir = tempDir.appendingPathComponent("runner-bin")
        try makeRunnerPackage(at: runnerDir)

        let manager = SharedDirectoryManager(cacheDirectoryPath: tempDir.path)

        #expect(throws: SharedDirectoryError.self) {
            try manager.prepareForJob(jobId: 1, runnerPath: runnerDir, guestConfig: .jit(config: " \n "))
        }
    }

    @Test("prepareForJob fails when runner entrypoint is not executable")
    func nonExecutableRunnerEntrypointFails() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let runnerDir = tempDir.appendingPathComponent("runner-bin")
        try FileManager.default.createDirectory(at: runnerDir, withIntermediateDirectories: true)
        try "#!/bin/bash".write(
            to: runnerDir.appendingPathComponent("run.sh"),
            atomically: true,
            encoding: .utf8
        )

        let manager = SharedDirectoryManager(cacheDirectoryPath: tempDir.path)

        #expect(throws: SharedDirectoryError.self) {
            try manager.prepareForJob(jobId: 1, runnerPath: runnerDir, guestConfig: .jit(config: "cfg"))
        }
    }

    @Test("prepareForJob writes registration token guest files")
    func prepareForJobWritesRegistrationTokenFiles() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let runnerDir = tempDir.appendingPathComponent("runner-bin")
        try makeRunnerPackage(at: runnerDir)

        let manager = SharedDirectoryManager(cacheDirectoryPath: tempDir.path)
        let jobDir = try manager.prepareForJob(
            jobId: 88,
            runnerPath: runnerDir,
            guestConfig: .registrationToken(
                url: "https://github.com/orgs/octo",
                token: "REGTOKEN",
                runnerName: "ephemeral-88",
                labels: ["self-hosted", "macOS"]
            )
        )

        let tokenPath = jobDir.appendingPathComponent(GuestBootstrapContract.registrationTokenFileName)
        let urlPath = jobDir.appendingPathComponent(GuestBootstrapContract.runnerURLFileName)
        let namePath = jobDir.appendingPathComponent(GuestBootstrapContract.runnerNameFileName)
        let labelsPath = jobDir.appendingPathComponent(GuestBootstrapContract.runnerLabelsFileName)
        let jitPath = jobDir.appendingPathComponent(GuestBootstrapContract.jitConfigFileName)

        #expect(try String(contentsOf: tokenPath, encoding: .utf8) == "REGTOKEN")
        #expect(try String(contentsOf: urlPath, encoding: .utf8) == "https://github.com/orgs/octo")
        #expect(try String(contentsOf: namePath, encoding: .utf8) == "ephemeral-88")
        #expect(try String(contentsOf: labelsPath, encoding: .utf8) == "self-hosted,macOS")
        #expect(!FileManager.default.fileExists(atPath: jitPath.path))
    }

    @Test("prepareForJob writes ephemeral Apple signing injection")
    func prepareForJobWritesSigningInjection() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let runnerDir = tempDir.appendingPathComponent("runner-bin")
        try makeRunnerPackage(at: runnerDir)

        let asset = AppleSigningAsset(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            displayName: "iOS Distribution",
            teamId: "TEAM12345",
            bundleIdentifierPattern: "com.example.*",
            certificateCommonName: "Apple Distribution",
            provisioningProfileUUID: "profile-uuid"
        )
        let injection = AppleSigningInjection(
            asset: asset,
            certificateData: Data([0x01, 0x02]),
            certificatePassphrase: "p12 secret",
            provisioningProfileData: Data([0x03, 0x04])
        )

        let manager = SharedDirectoryManager(cacheDirectoryPath: tempDir.path)
        let jobDir = try manager.prepareForJob(
            jobId: 77,
            runnerPath: runnerDir,
            guestConfig: .jit(config: "cfg"),
            signingInjection: injection
        )

        let signingDir = jobDir.appendingPathComponent(GuestBootstrapContract.appleSigningDirectoryName)
        let certificateURL = signingDir.appendingPathComponent(
            GuestBootstrapContract.appleSigningCertificateFileName
        )
        let profileURL = signingDir.appendingPathComponent(
            GuestBootstrapContract.appleSigningProvisioningProfileFileName
        )
        let environmentURL = signingDir.appendingPathComponent(
            GuestBootstrapContract.appleSigningEnvironmentFileName
        )
        let scriptURL = signingDir.appendingPathComponent(
            GuestBootstrapContract.appleSigningImportScriptFileName
        )

        #expect(try Data(contentsOf: certificateURL) == Data([0x01, 0x02]))
        #expect(try Data(contentsOf: profileURL) == Data([0x03, 0x04]))

        let environment = try String(contentsOf: environmentURL, encoding: .utf8)
        #expect(environment.contains("TARMAC_APPLE_SIGNING_DIR"))
        #expect(environment.contains("TARMAC_APPLE_TEAM_ID='TEAM12345'"))
        #expect(environment.contains("TARMAC_APPLE_BUNDLE_IDENTIFIER_PATTERN='com.example.*'"))
        #expect(environment.contains("TARMAC_APPLE_PROVISIONING_PROFILE_INSTALL_PATH"))

        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        #expect(script.contains("security create-keychain"))
        #expect(script.contains("security import"))
        #expect(script.contains("set-key-partition-list"))
        #expect(script.contains("cleanup_apple_signing"))
        #expect(FileManager.default.isExecutableFile(atPath: scriptURL.path))
    }

    @Test("prepareForJob rejects empty Apple signing material")
    func prepareForJobRejectsEmptySigningMaterial() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let runnerDir = tempDir.appendingPathComponent("runner-bin")
        try makeRunnerPackage(at: runnerDir)
        let manager = SharedDirectoryManager(cacheDirectoryPath: tempDir.path)
        let injection = AppleSigningInjection(
            asset: AppleSigningAsset(displayName: "Bad", teamId: "TEAM", bundleIdentifierPattern: "*"),
            certificateData: Data(),
            certificatePassphrase: "secret",
            provisioningProfileData: Data([0x01])
        )

        #expect(throws: SharedDirectoryError.self) {
            try manager.prepareForJob(
                jobId: 78,
                runnerPath: runnerDir,
                guestConfig: .jit(config: "cfg"),
                signingInjection: injection
            )
        }
    }

    @Test("prepareWarmRunnerJob writes warm mode and job-ready signaling files")
    func prepareWarmRunnerJobWritesArtifacts() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let runnerDir = tempDir.appendingPathComponent("runner-bin")
        try makeRunnerPackage(at: runnerDir)

        let manager = SharedDirectoryManager(cacheDirectoryPath: tempDir.path)
        let warmDir = try manager.prepareWarmRunnerJob(
            jobId: 99,
            runnerPath: runnerDir,
            guestConfig: .jit(config: "warm-config")
        )
        try manager.enableWarmMode(in: warmDir)
        try manager.signalJobReady(in: warmDir)

        #expect(warmDir.lastPathComponent == GuestBootstrapContract.warmRunnerJobDirectoryName)
        let warmModeURL = warmDir.appendingPathComponent(GuestBootstrapContract.warmModeFileName)
        let jobReadyURL = warmDir.appendingPathComponent(GuestBootstrapContract.jobReadyFileName)
        #expect(FileManager.default.fileExists(atPath: warmModeURL.path))
        #expect(FileManager.default.fileExists(atPath: jobReadyURL.path))
    }

    @Test("prepareWarmRunner creates a jobless guest handshake directory")
    func prepareWarmRunnerCreatesJoblessDirectory() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let manager = SharedDirectoryManager(cacheDirectoryPath: tempDir.path)
        let warmDirectory = try manager.prepareWarmRunner()

        #expect(warmDirectory.lastPathComponent == GuestBootstrapContract.warmRunnerJobDirectoryName)
        #expect(
            FileManager.default.fileExists(
                atPath: warmDirectory.appendingPathComponent(GuestBootstrapContract.warmModeFileName).path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: warmDirectory.appendingPathComponent(GuestBootstrapContract.jobReadyFileName).path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: warmDirectory.appendingPathComponent(GuestBootstrapContract.runnerDirectoryName).path
            )
        )
    }

    @Test("prepareWarmRunner replaces guest metadata without owner read access")
    func prepareWarmRunnerReplacesProtectedGuestMetadata() throws {
        let tempDir = try TestFactories.makeTempDir()
        let manager = SharedDirectoryManager(cacheDirectoryPath: tempDir.path)
        let warmDirectory = manager.warmRunnerDirectory
        let guestMetadata = warmDirectory.appendingPathComponent(".Trashes", isDirectory: true)
        try FileManager.default.createDirectory(at: guestMetadata, withIntermediateDirectories: true)
        try Data([0x01]).write(to: guestMetadata.appendingPathComponent("guest-item"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o311],
            ofItemAtPath: guestMetadata.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: guestMetadata.path
            )
            TestFactories.cleanup(tempDir)
        }

        let preparedDirectory = try manager.prepareWarmRunner()

        #expect(preparedDirectory == warmDirectory)
        #expect(!FileManager.default.fileExists(atPath: guestMetadata.path))
        #expect(
            FileManager.default.fileExists(
                atPath: preparedDirectory.appendingPathComponent(GuestBootstrapContract.warmModeFileName).path
            )
        )
    }

    private func makeRunnerPackage(at runnerDir: URL) throws {
        try FileManager.default.createDirectory(at: runnerDir, withIntermediateDirectories: true)
        let runScript = runnerDir.appendingPathComponent("run.sh")
        try "#!/bin/bash".write(to: runScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runScript.path
        )
    }
}
