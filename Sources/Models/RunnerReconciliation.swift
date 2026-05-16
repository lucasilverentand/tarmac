import Foundation

struct GitHubRunnerLabel: Codable, Equatable, Sendable {
    let name: String
}

struct GitHubRunner: Identifiable, Codable, Equatable, Sendable {
    let id: Int64
    let name: String
    let status: String
    let busy: Bool
    let labels: [GitHubRunnerLabel]

    var labelNames: Set<String> {
        Set(labels.map(\.name))
    }

    var isOffline: Bool {
        status.localizedCaseInsensitiveCompare("offline") == .orderedSame
    }
}

struct GitHubRunnerListResponse: Codable, Sendable {
    let totalCount: Int
    let runners: [GitHubRunner]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case runners
    }
}

struct RunnerReconciliationRemoval: Identifiable, Equatable, Sendable {
    let id: UUID
    let organizationName: String
    let jobId: Int64
    let runnerId: Int64
    let runnerName: String

    init(organizationName: String, jobId: Int64, runnerId: Int64, runnerName: String) {
        self.id = UUID()
        self.organizationName = organizationName
        self.jobId = jobId
        self.runnerId = runnerId
        self.runnerName = runnerName
    }
}

struct RunnerReconciliationFailure: Identifiable, Equatable, Sendable {
    let id: UUID
    let organizationName: String
    let runnerName: String?
    let message: String

    init(organizationName: String, runnerName: String? = nil, message: String) {
        self.id = UUID()
        self.organizationName = organizationName
        self.runnerName = runnerName
        self.message = message
    }
}

struct RunnerReconciliationReport: Equatable, Sendable {
    static let empty = RunnerReconciliationReport()

    var scannedRunnerCount: Int
    var matchedLeaseCount: Int
    var removedRunners: [RunnerReconciliationRemoval]
    var skippedRunnerCount: Int
    var failures: [RunnerReconciliationFailure]

    init(
        scannedRunnerCount: Int = 0,
        matchedLeaseCount: Int = 0,
        removedRunners: [RunnerReconciliationRemoval] = [],
        skippedRunnerCount: Int = 0,
        failures: [RunnerReconciliationFailure] = []
    ) {
        self.scannedRunnerCount = scannedRunnerCount
        self.matchedLeaseCount = matchedLeaseCount
        self.removedRunners = removedRunners
        self.skippedRunnerCount = skippedRunnerCount
        self.failures = failures
    }

    var hasActivity: Bool {
        scannedRunnerCount > 0 || !removedRunners.isEmpty || !failures.isEmpty
    }

    var statusText: String {
        if !failures.isEmpty {
            return "Runner cleanup needs attention"
        }
        if removedRunners.isEmpty {
            return "No stale Tarmac runners found"
        }
        if removedRunners.count == 1 {
            return "Cleaned 1 stale Tarmac runner"
        }
        return "Cleaned \(removedRunners.count) stale Tarmac runners"
    }

    mutating func merge(_ other: RunnerReconciliationReport) {
        scannedRunnerCount += other.scannedRunnerCount
        matchedLeaseCount += other.matchedLeaseCount
        removedRunners.append(contentsOf: other.removedRunners)
        skippedRunnerCount += other.skippedRunnerCount
        failures.append(contentsOf: other.failures)
    }
}
