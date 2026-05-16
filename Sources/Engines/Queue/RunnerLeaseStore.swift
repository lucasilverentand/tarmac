import Foundation

actor RunnerLeaseStore {
    private(set) var leases: [RunnerLease] = []

    private let defaults: UserDefaults
    private let leasesKey = "activeRunnerLeases"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: leasesKey),
            let decoded = try? JSONDecoder().decode([RunnerLease].self, from: data)
        {
            self.leases = decoded
        }
    }

    var activeLeases: [RunnerLease] {
        leases.filter { $0.cleanupState != .completed }
    }

    func upsert(_ lease: RunnerLease) {
        if let index = leases.firstIndex(where: { $0.jobId == lease.jobId }) {
            leases[index] = lease
        } else {
            leases.append(lease)
        }
        persist()
    }

    func lease(jobId: Int64) -> RunnerLease? {
        leases.first { $0.jobId == jobId }
    }

    func recordVMStarted(
        jobId: Int64,
        vmInstanceId: UUID,
        diskImagePath: String,
        sharedDirectoryPath: String
    ) -> RunnerLease? {
        guard let index = leases.firstIndex(where: { $0.jobId == jobId }) else {
            Log.queue.warning("Runner lease for job \(jobId) not found for VM start update")
            return nil
        }

        leases[index].recordVMStarted(
            vmInstanceId: vmInstanceId,
            diskImagePath: diskImagePath,
            sharedDirectoryPath: sharedDirectoryPath
        )
        persist()
        return leases[index]
    }

    func recordDiagnosticsBundle(jobId: Int64, path: String) -> RunnerLease? {
        guard let index = leases.firstIndex(where: { $0.jobId == jobId }) else {
            Log.queue.warning("Runner lease for job \(jobId) not found for diagnostics update")
            return nil
        }

        leases[index].recordDiagnosticsBundle(path: path)
        persist()
        return leases[index]
    }

    func recordCleanupState(jobId: Int64, state: RunnerLeaseCleanupState) -> RunnerLease? {
        guard let index = leases.firstIndex(where: { $0.jobId == jobId }) else {
            Log.queue.warning("Runner lease for job \(jobId) not found for cleanup update")
            return nil
        }

        leases[index].recordCleanupState(state)
        persist()
        return leases[index]
    }

    func completeAndRemove(jobId: Int64, diagnosticsPath: String?) -> RunnerLease? {
        guard let index = leases.firstIndex(where: { $0.jobId == jobId }) else {
            return nil
        }

        if let diagnosticsPath {
            leases[index].recordDiagnosticsBundle(path: diagnosticsPath)
        }
        leases[index].recordCleanupState(.completed)
        let completed = leases[index]
        leases.remove(at: index)
        persist()
        return completed
    }

    private func persist() {
        let active = leases.filter { $0.cleanupState != .completed }
        if let data = try? JSONEncoder().encode(active) {
            defaults.set(data, forKey: leasesKey)
        }
    }
}
