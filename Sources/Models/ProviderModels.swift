import Foundation

enum ProviderKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case github
    case gitea

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github: "GitHub"
        case .gitea: "Gitea"
        }
    }
}

enum RunnerAccountScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case repository
    case organization
    case instance

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .repository: "Repository"
        case .organization: "Organization"
        case .instance: "Instance"
        }
    }
}

struct ProviderJobKey: Codable, Hashable, Sendable {
    let accountID: UUID
    let remoteJobID: String
}

struct ProviderQueuedJob: Equatable, Sendable {
    let key: ProviderJobKey
    let localID: Int64
    let runID: Int64?
    let name: String?
    let repositoryName: String?
    let labels: [String]
    let queuedAt: Date
    let htmlURL: URL?
}

struct PreparedRunner: Sendable {
    let runnerPath: URL
    let guestConfig: RunnerGuestConfig
}

enum ProviderSetupIssue: Equatable, Sendable {
    case unsupportedVersion(required: String, actual: String)
    case authentication(String)
    case permissions(String)
    case actionsUnavailable
    case runnerUnavailable(String)
    case invalidConfiguration(String)

    var message: String {
        switch self {
        case .unsupportedVersion(let required, let actual):
            "Requires version \(required) or newer; the server reports \(actual)."
        case .authentication(let detail), .permissions(let detail), .runnerUnavailable(let detail),
            .invalidConfiguration(let detail):
            detail
        case .actionsUnavailable:
            "Actions are unavailable for this account."
        }
    }
}

struct ProviderSetupResult: Equatable, Sendable {
    let provider: ProviderKind
    let accountID: UUID
    let serverVersion: String?
    let issues: [ProviderSetupIssue]

    var isReady: Bool { issues.isEmpty }
}

protocol ActionsProvider: Actor {
    var kind: ProviderKind { get }

    func validate(account: RunnerAccount) async -> ProviderSetupResult
    func queuedJobs(for account: RunnerAccount) async throws -> [ProviderQueuedJob]
    func prepareRunner(for account: RunnerAccount, runnerName: String) async throws -> PreparedRunner
    func claimedJob(for account: RunnerAccount, runnerName: String) async throws -> ProviderQueuedJob?
    func terminalResult(for account: RunnerAccount, remoteJobID: String, repositoryName: String?) async throws
        -> JobResult?
    func reconcileStaleRunners(for account: RunnerAccount, leases: [RunnerLease]) async
        -> RunnerReconciliationReport
}

extension ProviderJobKey {
    /// Stable positive local identifier used by the existing queue and VM storage layout.
    var localID: Int64 {
        let bytes = Array("\(accountID.uuidString.lowercased()):\(remoteJobID)".utf8)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int64(hash & 0x7fff_ffff_ffff_ffff)
    }
}
