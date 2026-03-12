import Foundation
import Testing

@testable import Tarmac

@Suite("SharedDirectoryManager")
struct SharedDirectoryManagerTests {
    @Test("prepareForJob creates directory with runner symlink and jitconfig")
    func prepareForJobCreatesStructure() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        // Create a fake runner directory
        let runnerDir = tempDir.appendingPathComponent("runner-bin")
        try FileManager.default.createDirectory(at: runnerDir, withIntermediateDirectories: true)
        try "#!/bin/bash".write(
            to: runnerDir.appendingPathComponent("run.sh"),
            atomically: true,
            encoding: .utf8
        )

        let manager = SharedDirectoryManager(cacheDirectoryPath: tempDir.path)
        let jobDir = try manager.prepareForJob(
            jobId: 42,
            runnerPath: runnerDir,
            jitConfig: "test-jit-config-data"
        )

        // Check runner symlink exists
        let runnerLink = jobDir.appendingPathComponent("runner")
        #expect(FileManager.default.fileExists(atPath: runnerLink.path))

        // Check it's a symlink pointing to the runner dir
        let linkDest = try FileManager.default.destinationOfSymbolicLink(atPath: runnerLink.path)
        #expect(linkDest == runnerDir.path)
    }

    @Test("prepareForJob writes correct jitconfig content")
    func jitconfigContent() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let runnerDir = tempDir.appendingPathComponent("runner-bin")
        try FileManager.default.createDirectory(at: runnerDir, withIntermediateDirectories: true)

        let manager = SharedDirectoryManager(cacheDirectoryPath: tempDir.path)
        let jobDir = try manager.prepareForJob(
            jobId: 100,
            runnerPath: runnerDir,
            jitConfig: "my-encoded-config"
        )

        let jitPath = jobDir.appendingPathComponent("jitconfig")
        let content = try String(contentsOf: jitPath, encoding: .utf8)
        #expect(content == "my-encoded-config")
    }

    @Test("cleanupJob removes directory")
    func cleanupJobRemovesDir() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let runnerDir = tempDir.appendingPathComponent("runner-bin")
        try FileManager.default.createDirectory(at: runnerDir, withIntermediateDirectories: true)

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
}
