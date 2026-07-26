import Foundation

actor JobStore {
    private(set) var jobs: [RunnerJob] = []

    private let defaults: UserDefaults
    private let historyKey = "completedJobHistory"
    private let maxHistory = 100

    var pendingJobs: [RunnerJob] {
        jobs.filter { $0.status == .pending }
    }

    var activeJob: RunnerJob? {
        jobs.first { $0.status == .provisioning || $0.status == .running }
    }

    var completedJobs: [RunnerJob] {
        jobs.filter { $0.status == .completed || $0.status == .failed }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: historyKey),
            let history = try? JSONDecoder().decode([RunnerJob].self, from: data)
        {
            self.jobs = history
        }
    }

    // MARK: - Mutations

    func addJob(_ job: RunnerJob) {
        guard !jobs.contains(where: { $0.id == job.id }) else {
            Log.queue.debug("Job \(job.id) already in store, skipping")
            return
        }

        jobs.append(job)
        Log.queue.info("Job \(job.id) added (\(job.organizationName))")
    }

    func updateJob(id: Int64, status: JobStatus, failureReason: String? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            Log.queue.warning("Job \(id) not found for status update")
            return
        }

        jobs[index].status = status
        if let failureReason {
            jobs[index].failureReason = failureReason
        }

        switch status {
        case .provisioning, .running:
            if jobs[index].startedAt == nil {
                jobs[index].startedAt = Date()
            }
        case .completed, .failed:
            jobs[index].completedAt = Date()
            persistHistory()
        case .pending:
            break
        }

        Log.queue.info("Job \(id) → \(status.rawValue)")
    }

    func updateRunnerLease(jobId: Int64, lease: RunnerLease) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else {
            Log.queue.warning("Job \(jobId) not found for runner lease update")
            return
        }

        jobs[index].runnerName = lease.runnerName
        jobs[index].runnerLease = lease
        persistIfTerminal(jobs[index])
    }

    func bindProviderJob(jobId: Int64, claimedJob: ProviderQueuedJob) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[index].accountID = claimedJob.key.accountID
        jobs[index].remoteJobID = claimedJob.key.remoteJobID
        jobs[index].runnerRequestId = claimedJob.runID
        jobs[index].workflowName = claimedJob.name
        jobs[index].repositoryName = claimedJob.repositoryName
        persistIfTerminal(jobs[index])
    }

    func updateVMInstance(jobId: Int64, vmInstanceId: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else {
            Log.queue.warning("Job \(jobId) not found for VM instance update")
            return
        }

        jobs[index].vmInstanceId = vmInstanceId
        persistIfTerminal(jobs[index])
    }

    func updateDiagnosticsBundle(jobId: Int64, path: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else {
            Log.queue.warning("Job \(jobId) not found for diagnostics update")
            return
        }

        jobs[index].diagnosticsBundlePath = path
        if var lease = jobs[index].runnerLease {
            lease.recordDiagnosticsBundle(path: path)
            jobs[index].runnerLease = lease
        }
        persistIfTerminal(jobs[index])
    }

    func removeJob(id: Int64) {
        jobs.removeAll { $0.id == id }
        Log.queue.info("Job \(id) removed")
    }

    func job(byId id: Int64) -> RunnerJob? {
        jobs.first { $0.id == id }
    }

    // MARK: - Persistence

    private func loadHistory() {
        guard let data = defaults.data(forKey: historyKey),
            let history = try? JSONDecoder().decode([RunnerJob].self, from: data)
        else {
            return
        }

        jobs = history
        Log.queue.info("Loaded \(history.count) jobs from history")
    }

    private func persistHistory() {
        let completed =
            jobs
            .filter { $0.status == .completed || $0.status == .failed }
            .suffix(maxHistory)

        if let data = try? JSONEncoder().encode(Array(completed)) {
            defaults.set(data, forKey: historyKey)
        }
    }

    private func persistIfTerminal(_ job: RunnerJob) {
        if job.status == .completed || job.status == .failed {
            persistHistory()
        }
    }
}
