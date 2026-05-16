import Foundation
import Testing

@testable import Tarmac

@Suite("RunnerLeaseStore")
struct RunnerLeaseStoreTests {
    private func makeSuiteName() -> String {
        let suiteName = "test-runner-lease-store-\(UUID().uuidString)"
        return suiteName
    }

    private func makeLease(jobId: Int64 = 1) -> RunnerLease {
        let job = RunnerJob(
            id: jobId,
            organizationName: "org",
            runnerRequestId: 9001,
            status: .running,
            workflowName: "CI",
            repositoryName: "repo",
            queuedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return RunnerLease(
            job: job,
            runnerName: "ephemeral-\(jobId)",
            labels: ["self-hosted", "macOS"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
    }

    @Test("upsert persists active leases")
    func upsertPersistsActiveLeases() async {
        let suiteName = makeSuiteName()
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RunnerLeaseStore(defaults: defaults)
        await store.upsert(makeLease(jobId: 42))

        let reloaded = RunnerLeaseStore(defaults: defaults)
        let lease = await reloaded.lease(jobId: 42)
        #expect(lease?.runnerName == "ephemeral-42")
        #expect(lease?.cleanupState == .pending)
    }

    @Test("VM start update records cleanup paths")
    func vmStartUpdateRecordsCleanupPaths() async {
        let suiteName = makeSuiteName()
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RunnerLeaseStore(defaults: defaults)
        await store.upsert(makeLease(jobId: 7))
        let vmId = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

        let lease = await store.recordVMStarted(
            jobId: 7,
            vmInstanceId: vmId,
            diskImagePath: "/tmp/disks/7.img",
            sharedDirectoryPath: "/tmp/jobs/7"
        )

        #expect(lease?.cleanupState == .vmRunning)
        #expect(lease?.executionAttempt?.vmInstanceId == vmId)
        #expect(lease?.executionAttempt?.diskImagePath == "/tmp/disks/7.img")
        #expect(lease?.executionAttempt?.sharedDirectoryPath == "/tmp/jobs/7")
    }

    @Test("completeAndRemove returns completed snapshot and clears active persistence")
    func completeAndRemoveClearsActivePersistence() async {
        let suiteName = makeSuiteName()
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RunnerLeaseStore(defaults: defaults)
        await store.upsert(makeLease(jobId: 9))

        let completed = await store.completeAndRemove(jobId: 9, diagnosticsPath: "/tmp/diagnostics/9")
        #expect(completed?.cleanupState == .completed)
        #expect(completed?.diagnosticsBundlePath == "/tmp/diagnostics/9")
        #expect(await store.activeLeases.isEmpty)

        let reloaded = RunnerLeaseStore(defaults: defaults)
        #expect(await reloaded.lease(jobId: 9) == nil)
    }
}
