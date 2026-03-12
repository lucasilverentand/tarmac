import Foundation
import Testing

@testable import Tarmac

@Suite("JobDispatcher")
struct JobDispatcherTests {
    private func makeStore() -> JobStore {
        let suiteName = "test-dispatcher-\(UUID().uuidString)"
        return JobStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    private func makeJob(id: Int64, status: JobStatus = .pending) -> RunnerJob {
        RunnerJob(
            id: id,
            organizationName: "test-org",
            status: status,
            workflowName: "CI",
            repositoryName: "test-repo",
            queuedAt: Date()
        )
    }

    @Test("FIFO: first pending job is returned")
    func fifoOrder() async {
        let store = makeStore()
        await store.addJob(makeJob(id: 1))
        await store.addJob(makeJob(id: 2))
        await store.addJob(makeJob(id: 3))

        let dispatcher = JobDispatcher()
        let next = await dispatcher.nextJob(from: store)
        #expect(next?.id == 1)
    }

    @Test("Sequential: returns nil when a job is already running")
    func sequentialExecution() async {
        let store = makeStore()
        await store.addJob(makeJob(id: 1))
        await store.addJob(makeJob(id: 2))

        // Mark job 1 as running
        await store.updateJob(id: 1, status: .provisioning)

        let dispatcher = JobDispatcher()
        let next = await dispatcher.nextJob(from: store)
        #expect(next == nil)
    }

    @Test("Status transitions: pending → provisioning → running → completed")
    func statusTransitions() async {
        let store = makeStore()
        await store.addJob(makeJob(id: 1))

        let dispatcher = JobDispatcher()

        // Dispatch the job
        let next = await dispatcher.nextJob(from: store)
        #expect(next?.id == 1)

        await dispatcher.markStarted(jobId: 1, in: store)
        let provisioning = await store.job(byId: 1)
        #expect(provisioning?.status == .provisioning)

        await store.updateJob(id: 1, status: .running)
        let running = await store.job(byId: 1)
        #expect(running?.status == .running)

        await dispatcher.markCompleted(jobId: 1, in: store, result: .success)
        let completed = await store.job(byId: 1)
        #expect(completed?.status == .completed)
    }

    @Test("Returns nil when no pending jobs")
    func emptyQueue() async {
        let store = makeStore()
        let dispatcher = JobDispatcher()
        let next = await dispatcher.nextJob(from: store)
        #expect(next == nil)
    }

    @Test("Priority: higher-priority org dispatched first")
    func orgPriority() async {
        let store = makeStore()

        // Add job from low-priority org first, then high-priority org
        let lowPriorityJob = RunnerJob(
            id: 1,
            organizationName: "low-priority",
            status: .pending,
            queuedAt: Date(timeIntervalSince1970: 100)
        )
        let highPriorityJob = RunnerJob(
            id: 2,
            organizationName: "high-priority",
            status: .pending,
            queuedAt: Date(timeIntervalSince1970: 200)
        )
        await store.addJob(lowPriorityJob)
        await store.addJob(highPriorityJob)

        let dispatcher = JobDispatcher()
        await dispatcher.setOrgPriority(["high-priority", "low-priority"])

        let next = await dispatcher.nextJob(from: store)
        #expect(next?.id == 2)
        #expect(next?.organizationName == "high-priority")
    }

    @Test("Priority: same org falls back to FIFO")
    func sameOrgFallsBackToFifo() async {
        let store = makeStore()

        let earlier = RunnerJob(
            id: 1,
            organizationName: "org-a",
            status: .pending,
            queuedAt: Date(timeIntervalSince1970: 100)
        )
        let later = RunnerJob(
            id: 2,
            organizationName: "org-a",
            status: .pending,
            queuedAt: Date(timeIntervalSince1970: 200)
        )
        await store.addJob(later)
        await store.addJob(earlier)

        let dispatcher = JobDispatcher()
        await dispatcher.setOrgPriority(["org-a"])

        let next = await dispatcher.nextJob(from: store)
        #expect(next?.id == 1)  // earlier queued time
    }
}
