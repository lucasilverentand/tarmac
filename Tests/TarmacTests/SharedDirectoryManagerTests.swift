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
            jitConfig: "test-jit-config-data"
        )

        let runnerCopy = jobDir.appendingPathComponent(GuestBootstrapContract.runnerDirectoryName)
        let runScript = runnerCopy.appendingPathComponent(GuestBootstrapContract.runnerEntrypointName)
        #expect(FileManager.default.fileExists(atPath: runnerCopy.path))
        #expect(FileManager.default.fileExists(atPath: runScript.path))
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
            jitConfig: "my-encoded-config"
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
        _ = try manager.prepareForJob(jobId: 55, runnerPath: runnerDir, jitConfig: "cfg")

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
                jitConfig: "cfg"
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
            try manager.prepareForJob(jobId: 1, runnerPath: runnerDir, jitConfig: "cfg")
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
            try manager.prepareForJob(jobId: 1, runnerPath: runnerDir, jitConfig: " \n ")
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
            try manager.prepareForJob(jobId: 1, runnerPath: runnerDir, jitConfig: "cfg")
        }
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
            jitConfig: "cfg",
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
                jitConfig: "cfg",
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
            jitConfig: "warm-config"
        )
        try manager.enableWarmMode(in: warmDir)
        try manager.signalJobReady(in: warmDir)

        #expect(warmDir.lastPathComponent == GuestBootstrapContract.warmRunnerJobDirectoryName)
        let warmModeURL = warmDir.appendingPathComponent(GuestBootstrapContract.warmModeFileName)
        let jobReadyURL = warmDir.appendingPathComponent(GuestBootstrapContract.jobReadyFileName)
        #expect(FileManager.default.fileExists(atPath: warmModeURL.path))
        #expect(FileManager.default.fileExists(atPath: jobReadyURL.path))
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
