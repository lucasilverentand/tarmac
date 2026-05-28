import Foundation

/// Per-organization scale-set polling status exposed by `QueueEngine`.
///
/// When `isRunning` is false and `lastFailure` is a terminal kind (for example `scaleSetUnavailable`),
/// the polling loop has paused for that org until the app restarts or GitHub configuration is fixed.
struct QueuePollingState: Equatable, Sendable {
    let orgName: String
    var sessionId: String?
    var isRunning: Bool
    var lastFailure: QueuePollingFailureKind?
    /// User-facing detail for `lastFailure`; nil when polling is healthy.
    var lastFailureMessage: String?
    var retryAttempt: Int
    var nextRetryDelay: TimeInterval?
}

enum QueuePollingFailureKind: String, Equatable, Sendable {
    case missingConfiguration
    case scaleSetUnavailable
    case tokenExpired
    case permissionDenied
    case rateLimited
    case transientFailure
    case malformedResponse
    case requestFailed
    case unknown

    /// Failures that should stop the long-poll retry loop until configuration changes or the app restarts.
    var isTerminal: Bool {
        switch self {
        case .missingConfiguration, .scaleSetUnavailable:
            return true
        case .tokenExpired, .permissionDenied, .rateLimited, .transientFailure, .malformedResponse,
            .requestFailed, .unknown:
            return false
        }
    }
}

struct QueuePollingRetryPolicy: Equatable, Sendable {
    var baseDelay: TimeInterval = 5
    var maxDelay: TimeInterval = 60

    static let `default` = QueuePollingRetryPolicy()
    static let immediate = QueuePollingRetryPolicy(baseDelay: 0, maxDelay: 0)

    func delay(for failure: QueuePollingFailureKind, attempt: Int, retryAfter: TimeInterval? = nil) -> TimeInterval {
        if let retryAfter {
            return min(retryAfter, maxDelay)
        }

        switch failure {
        case .permissionDenied, .tokenExpired, .missingConfiguration, .scaleSetUnavailable:
            return maxDelay
        case .malformedResponse:
            return min(baseDelay, maxDelay)
        case .rateLimited, .transientFailure, .requestFailed, .unknown:
            let exponent = max(0, attempt - 1)
            let delay = baseDelay * pow(2, Double(exponent))
            return min(delay, maxDelay)
        }
    }
}

struct PollingSessionRecord: Codable, Equatable, Sendable {
    let orgName: String
    let scaleSetId: Int
    let sessionId: String
    let updatedAt: Date
}

final class PollingSessionStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "activePollingSessions"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(for orgName: String) -> PollingSessionRecord? {
        lock.lock()
        defer { lock.unlock() }
        return records()[orgName]
    }

    func save(_ record: PollingSessionRecord) {
        lock.lock()
        defer { lock.unlock() }
        var records = records()
        records[record.orgName] = record
        persist(records)
    }

    func remove(orgName: String) {
        lock.lock()
        defer { lock.unlock() }
        var records = records()
        records.removeValue(forKey: orgName)
        persist(records)
    }

    private func records() -> [String: PollingSessionRecord] {
        guard let data = defaults.data(forKey: key),
            let records = try? JSONDecoder().decode([String: PollingSessionRecord].self, from: data)
        else {
            return [:]
        }
        return records
    }

    private func persist(_ records: [String: PollingSessionRecord]) {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key)
        }
    }
}
