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
