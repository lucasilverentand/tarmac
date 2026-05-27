import Foundation

struct WarmRunnerConfiguration: Codable, Equatable, Sendable {
    /// When enabled, completed jobs leave the VM running for reuse instead of full teardown.
    var isEnabled: Bool = false
    /// Shut down a warm VM after this many seconds without a dispatched job.
    var idleShutdownSeconds: Int = 600
    /// Recycle the warm VM after this many consecutive jobs. `0` means no limit.
    var maxConsecutiveJobs: Int = 0

    init(
        isEnabled: Bool = false,
        idleShutdownSeconds: Int = 600,
        maxConsecutiveJobs: Int = 0
    ) {
        self.isEnabled = isEnabled
        self.idleShutdownSeconds = idleShutdownSeconds
        self.maxConsecutiveJobs = maxConsecutiveJobs
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case idleShutdownSeconds
        case maxConsecutiveJobs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        idleShutdownSeconds = try container.decodeIfPresent(Int.self, forKey: .idleShutdownSeconds) ?? 600
        maxConsecutiveJobs = try container.decodeIfPresent(Int.self, forKey: .maxConsecutiveJobs) ?? 0
    }

    var normalizedIdleShutdownSeconds: Int {
        max(60, idleShutdownSeconds)
    }

    func shouldRecycleWarmRunner(jobsServed: Int) -> Bool {
        guard maxConsecutiveJobs > 0 else { return false }
        return jobsServed >= maxConsecutiveJobs
    }
}
