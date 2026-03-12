import Foundation

actor JobDispatcher {
    private(set) var isDispatching = false

    /// Priority order of org names — first = highest priority.
    /// Set from the organizations array in ConfigStore.
    private(set) var orgPriority: [String] = []

    func setOrgPriority(_ names: [String]) {
        orgPriority = names
    }

    func nextJob(from store: JobStore) async -> RunnerJob? {
        let active = await store.activeJob
        if active != nil {
            Log.queue.debug("Job already active, skipping dispatch")
            return nil
        }

        let pending = await store.pendingJobs
        guard !pending.isEmpty else {
            return nil
        }

        // Sort by org priority (lower index = higher priority), then by queue time
        let sorted = pending.sorted { a, b in
            let aPriority = orgPriority.firstIndex(of: a.organizationName) ?? Int.max
            let bPriority = orgPriority.firstIndex(of: b.organizationName) ?? Int.max
            if aPriority != bPriority {
                return aPriority < bPriority
            }
            return a.queuedAt < b.queuedAt
        }

        let next = sorted[0]
        Log.queue.info("Next job to dispatch: \(next.id) (org: \(next.organizationName))")
        return next
    }

    func markStarted(jobId: Int64, in store: JobStore) async {
        isDispatching = true
        await store.updateJob(id: jobId, status: .provisioning)
        Log.queue.info("Job \(jobId) dispatched → provisioning")
    }

    func markCompleted(jobId: Int64, in store: JobStore, result: JobResult) async {
        switch result {
        case .success:
            await store.updateJob(id: jobId, status: .completed)
            Log.queue.info("Job \(jobId) completed successfully")
        case .failure(let reason):
            await store.updateJob(id: jobId, status: .failed)
            Log.queue.warning("Job \(jobId) failed: \(reason)")
        }

        isDispatching = false
    }
}

enum JobResult: Sendable {
    case success
    case failure(String)
}
