import Foundation
import Testing

@testable import Tarmac

@Suite("DiagnosticsBundleStore")
struct DiagnosticsBundleStoreTests {
    @Test("failed job bundle retains host guest runner logs and metadata")
    func failedBundleRetainsLogs() throws {
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        let storage = StorageManager(rootDirectory: root)
        let store = DiagnosticsBundleStore(
            storage: storage,
            retention: DiagnosticsRetentionConfiguration(maxBundleCount: 10, maxAgeDays: 30, maxSizeMB: 64)
        )
        let sharedDirectory = storage.jobsDirectory.appendingPathComponent("42", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        store.appendHostLifecycleEvent("boot failed after runner start", to: sharedDirectory)
        try "guest bootstrap".write(
            to: sharedDirectory.appendingPathComponent(GuestBootstrapContract.bootstrapLogFileName),
            atomically: true,
            encoding: .utf8
        )
        try "runner output".write(
            to: sharedDirectory.appendingPathComponent(GuestBootstrapContract.runnerLogFileName),
            atomically: true,
            encoding: .utf8
        )
        try "1".write(
            to: sharedDirectory.appendingPathComponent(GuestBootstrapContract.exitCodeFileName),
            atomically: true,
            encoding: .utf8
        )

        var job = TestFactories.makeJob(id: 42, status: .failed)
        job.runnerRequestId = 777
        job.runnerName = "ephemeral-42"
        job.vmInstanceId = UUID()
        let bundle = try store.createBundle(
            context: JobDiagnosticsContext(job: job),
            sharedDirectory: sharedDirectory,
            outcome: .failed(reason: "runner failed")
        )

        #expect(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("host-lifecycle.log").path))
        #expect(
            FileManager.default.fileExists(
                atPath: bundle.url.appendingPathComponent(GuestBootstrapContract.bootstrapLogFileName).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: bundle.url.appendingPathComponent(GuestBootstrapContract.runnerLogFileName).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: bundle.url.appendingPathComponent(GuestBootstrapContract.exitCodeFileName).path
            )
        )

        let metadata = try String(contentsOf: bundle.url.appendingPathComponent("metadata.json"), encoding: .utf8)
        #expect(metadata.contains("\"runnerRequestId\" : 777"))
        #expect(metadata.contains("\"runnerName\" : \"ephemeral-42\""))
        #expect(metadata.contains("\"outcome\" : \"failed\""))
    }

    @Test("successful bundle keeps minimal diagnostics by default")
    func successfulBundlePrunesRunnerLog() throws {
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        let storage = StorageManager(rootDirectory: root)
        let store = DiagnosticsBundleStore(
            storage: storage,
            retention: DiagnosticsRetentionConfiguration(maxBundleCount: 10, maxAgeDays: 30, maxSizeMB: 64)
        )
        let sharedDirectory = storage.jobsDirectory.appendingPathComponent("99", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        try "bootstrap ok".write(
            to: sharedDirectory.appendingPathComponent(GuestBootstrapContract.bootstrapLogFileName),
            atomically: true,
            encoding: .utf8
        )
        try "large runner output".write(
            to: sharedDirectory.appendingPathComponent(GuestBootstrapContract.runnerLogFileName),
            atomically: true,
            encoding: .utf8
        )
        try "0".write(
            to: sharedDirectory.appendingPathComponent(GuestBootstrapContract.exitCodeFileName),
            atomically: true,
            encoding: .utf8
        )

        let bundle = try store.createBundle(
            context: JobDiagnosticsContext(job: TestFactories.makeJob(id: 99, status: .completed)),
            sharedDirectory: sharedDirectory,
            outcome: .succeeded
        )

        #expect(
            FileManager.default.fileExists(
                atPath: bundle.url.appendingPathComponent(GuestBootstrapContract.bootstrapLogFileName).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: bundle.url.appendingPathComponent(GuestBootstrapContract.exitCodeFileName).path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: bundle.url.appendingPathComponent(GuestBootstrapContract.runnerLogFileName).path
            )
        )

        let metadata = try String(contentsOf: bundle.url.appendingPathComponent("metadata.json"), encoding: .utf8)
        #expect(metadata.contains("\"omittedFiles\" : ["))
        #expect(metadata.contains("runner.log"))
    }

    @Test("retention enforces maximum bundle count")
    func retentionEnforcesCount() throws {
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        let storage = StorageManager(rootDirectory: root)
        let store = DiagnosticsBundleStore(
            storage: storage,
            retention: DiagnosticsRetentionConfiguration(maxBundleCount: 2, maxAgeDays: 30, maxSizeMB: 64)
        )

        for jobId in 1...3 {
            _ = try store.createBundle(
                context: JobDiagnosticsContext(jobId: Int64(jobId)),
                sharedDirectory: nil,
                outcome: .failed(reason: "test"),
                createdAt: Date(timeIntervalSince1970: TimeInterval(jobId))
            )
        }

        let bundles = try FileManager.default.contentsOfDirectory(
            at: store.bundleRoot,
            includingPropertiesForKeys: nil
        )
        #expect(bundles.count == 2)
    }

    @Test("retention removes bundles older than max age")
    func retentionEnforcesAge() throws {
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        let storage = StorageManager(rootDirectory: root)
        let store = DiagnosticsBundleStore(
            storage: storage,
            retention: DiagnosticsRetentionConfiguration(maxBundleCount: 10, maxAgeDays: 1, maxSizeMB: 64)
        )

        _ = try store.createBundle(
            context: JobDiagnosticsContext(jobId: 7),
            sharedDirectory: nil,
            outcome: .failed(reason: "test"),
            createdAt: Date(timeIntervalSince1970: 0)
        )

        try store.enforceRetention(now: Date(timeIntervalSince1970: 3 * 86_400))
        let bundles = try FileManager.default.contentsOfDirectory(
            at: store.bundleRoot,
            includingPropertiesForKeys: nil
        )
        #expect(bundles.isEmpty)
    }
}
