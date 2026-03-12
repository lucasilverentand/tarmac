import Testing
import Foundation
@testable import Tarmac

@Suite("QueueViewModel")
@MainActor
struct QueueViewModelTests {
    private func makeJob(id: Int64, status: JobStatus, completedAt: Date? = nil) -> RunnerJob {
        RunnerJob(
            id: id, organizationName: "test-org", status: status,
            workflowName: "CI", repositoryName: "test-repo",
            queuedAt: Date(), completedAt: completedAt
        )
    }

    @Test("pendingJobs returns only pending status")
    func pendingJobsFilter() {
        let vm = QueueViewModel()
        vm.allJobs = [
            makeJob(id: 1, status: .pending),
            makeJob(id: 2, status: .running),
            makeJob(id: 3, status: .pending),
            makeJob(id: 4, status: .completed),
        ]

        #expect(vm.pendingJobs.count == 2)
        #expect(vm.pendingJobs.allSatisfy { $0.status == .pending })
    }

    @Test("activeJob returns first running or provisioning job")
    func activeJobFilter() {
        let vm = QueueViewModel()
        vm.allJobs = [
            makeJob(id: 1, status: .pending),
            makeJob(id: 2, status: .provisioning),
            makeJob(id: 3, status: .running),
        ]

        #expect(vm.activeJob?.id == 2)
    }

    @Test("activeJob is nil when no running jobs")
    func activeJobNil() {
        let vm = QueueViewModel()
        vm.allJobs = [
            makeJob(id: 1, status: .pending),
            makeJob(id: 2, status: .completed),
        ]

        #expect(vm.activeJob == nil)
    }

    @Test("completedJobs sorted most recent first")
    func completedJobsSorted() {
        let vm = QueueViewModel()
        let now = Date()
        vm.allJobs = [
            makeJob(id: 1, status: .completed, completedAt: now.addingTimeInterval(-300)),
            makeJob(id: 2, status: .completed, completedAt: now.addingTimeInterval(-60)),
            makeJob(id: 3, status: .failed, completedAt: now.addingTimeInterval(-180)),
            makeJob(id: 4, status: .pending),
        ]

        let completed = vm.completedJobs
        #expect(completed.count == 3)
        #expect(completed[0].id == 2) // most recent
        #expect(completed[1].id == 3)
        #expect(completed[2].id == 1) // oldest
    }

    @Test("completedTodayCount counts only today's completions")
    func completedTodayCount() {
        let vm = QueueViewModel()
        let now = Date()
        vm.allJobs = [
            makeJob(id: 1, status: .completed, completedAt: now.addingTimeInterval(-60)),
            makeJob(id: 2, status: .completed, completedAt: now.addingTimeInterval(-3600)),
            makeJob(id: 3, status: .completed, completedAt: now.addingTimeInterval(-86400 * 2)), // 2 days ago
            makeJob(id: 4, status: .failed, completedAt: now),
        ]

        // Only jobs 1 and 2 are completed (not failed) today
        // Job 3 is from 2 days ago, job 4 is failed
        let startOfDay = Calendar.current.startOfDay(for: now)
        let todayCompleted = vm.allJobs.filter { $0.status == .completed && ($0.completedAt ?? .distantPast) >= startOfDay }
        #expect(vm.completedTodayCount == todayCompleted.count)
    }

    @Test("updateJobStatus sets completedAt for terminal states")
    func updateJobStatusSetsCompletedAt() {
        let vm = QueueViewModel()
        vm.allJobs = [makeJob(id: 1, status: .pending)]

        vm.updateJobStatus(id: 1, status: .running)
        #expect(vm.allJobs[0].status == .running)
        #expect(vm.allJobs[0].startedAt != nil)

        vm.updateJobStatus(id: 1, status: .completed)
        #expect(vm.allJobs[0].status == .completed)
        #expect(vm.allJobs[0].completedAt != nil)
    }
}
