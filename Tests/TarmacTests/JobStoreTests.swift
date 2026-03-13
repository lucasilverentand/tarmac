import Foundation
import Testing

@testable import Tarmac

@Suite("JobStore")
struct JobStoreTests {
    private func makeStore() -> JobStore {
        let suiteName = "test-jobstore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return JobStore(defaults: defaults)
    }

    private func makeJob(id: Int64 = 1, status: JobStatus = .pending) -> RunnerJob {
        RunnerJob(
            id: id,
            organizationName: "test-org",
            status: status,
            workflowName: "CI",
            repositoryName: "test-repo",
            queuedAt: Date()
        )
    }

    @Test("addJob increases count")
    func addJobIncreasesCount() async {
        let store = makeStore()
        let job = makeJob()

        await store.addJob(job)
        let jobs = await store.jobs
        #expect(jobs.count == 1)
    }

    @Test("addJob deduplicates by id")
    func addJobDeduplicates() async {
        let store = makeStore()
        let job = makeJob(id: 42)

        await store.addJob(job)
        await store.addJob(job)
        let jobs = await store.jobs
        #expect(jobs.count == 1)
    }

    @Test("updateJob changes status")
    func updateJobChangesStatus() async {
        let store = makeStore()
        await store.addJob(makeJob(id: 10))

        await store.updateJob(id: 10, status: .running)
        let job = await store.job(byId: 10)
        #expect(job?.status == .running)
        #expect(job?.startedAt != nil)
    }

    @Test("pendingJobs filters correctly")
    func pendingJobsFilter() async {
        let store = makeStore()
        await store.addJob(makeJob(id: 1, status: .pending))
        await store.addJob(makeJob(id: 2, status: .running))
        await store.addJob(makeJob(id: 3, status: .pending))

        let pending = await store.pendingJobs
        #expect(pending.count == 2)
        #expect(pending.allSatisfy { $0.status == .pending })
    }

    @Test("completedJobs filters correctly")
    func completedJobsFilter() async {
        let store = makeStore()
        await store.addJob(makeJob(id: 1, status: .pending))
        await store.addJob(makeJob(id: 2, status: .completed))
        await store.addJob(makeJob(id: 3, status: .failed))

        let completed = await store.completedJobs
        #expect(completed.count == 2)
    }

    @Test("Persistence round-trip")
    func persistenceRoundTrip() async {
        let suiteName = "test-jobstore-\(UUID().uuidString)"
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: suiteName)!

        // Write
        let store1 = JobStore(defaults: defaults)
        await store1.addJob(makeJob(id: 100, status: .pending))
        await store1.updateJob(id: 100, status: .completed)

        // Read in new store with same defaults
        let store2 = JobStore(defaults: defaults)
        let jobs = await store2.jobs
        #expect(jobs.count == 1)
        #expect(jobs.first?.id == 100)
        #expect(jobs.first?.status == .completed)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Corrupted UserDefaults data is handled gracefully")
    func corruptedDataGracefulRecovery() async {
        let suiteName = "test-jobstore-\(UUID().uuidString)"
        nonisolated(unsafe) let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Write garbage to the history key
        defaults.set("not valid json".data(using: .utf8), forKey: "completedJobHistory")

        // Store should initialize gracefully with empty jobs
        let store = JobStore(defaults: defaults)
        let jobs = await store.jobs
        #expect(jobs.isEmpty)
    }

    @Test("Remove non-existent job is a no-op")
    func removeNonExistentJob() async {
        let store = makeStore()
        await store.addJob(makeJob(id: 1))

        // Remove a job that doesn't exist
        await store.removeJob(id: 999)

        let jobs = await store.jobs
        #expect(jobs.count == 1)
        #expect(jobs.first?.id == 1)
    }

    @Test("Update non-existent job is a no-op")
    func updateNonExistentJob() async {
        let store = makeStore()
        await store.addJob(makeJob(id: 1))

        // Update a job that doesn't exist — should not crash
        await store.updateJob(id: 999, status: .completed)

        let jobs = await store.jobs
        #expect(jobs.count == 1)
        #expect(jobs.first?.status == .pending)
    }
}
