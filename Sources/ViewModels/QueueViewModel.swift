import Foundation

@Observable
@MainActor
final class QueueViewModel {
    var allJobs: [RunnerJob] = []
    var isPolling: Bool = false

    var pendingJobs: [RunnerJob] {
        allJobs.filter { $0.status == .pending }
    }

    var activeJob: RunnerJob? {
        allJobs.first { $0.status == .provisioning || $0.status == .running }
    }

    var completedJobs: [RunnerJob] {
        allJobs
            .filter { $0.status == .completed || $0.status == .failed }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(50)
            .map { $0 }
    }

    var completedTodayCount: Int {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return allJobs.count { job in
            job.status == .completed && (job.completedAt ?? .distantPast) >= startOfDay
        }
    }

    func startPolling() {
        isPolling = true
        Log.queue.info("Queue polling started")
    }

    func stopPolling() {
        isPolling = false
        Log.queue.info("Queue polling stopped")
    }

    func addJob(_ job: RunnerJob) {
        allJobs.append(job)
        Log.queue.debug("Job \(job.id) added to queue")
    }

    func updateJobStatus(id: Int64, status: JobStatus) {
        guard let index = allJobs.firstIndex(where: { $0.id == id }) else { return }
        allJobs[index].status = status
        if status == .running && allJobs[index].startedAt == nil {
            allJobs[index].startedAt = Date()
        }
        if status == .completed || status == .failed {
            allJobs[index].completedAt = Date()
        }
        Log.queue.debug("Job \(id) status updated to \(status.rawValue)")
    }
}
