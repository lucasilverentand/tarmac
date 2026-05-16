import Foundation

struct QueuePollingState: Equatable, Sendable {
    let orgName: String
    var sessionId: String?
    var isRunning: Bool
    var lastFailure: QueuePollingFailureKind?
    var retryAttempt: Int
    var nextRetryDelay: TimeInterval?
}

enum QueuePollingFailureKind: String, Equatable, Sendable {
    case missingConfiguration
    case tokenExpired
    case permissionDenied
    case rateLimited
    case transientFailure
    case malformedResponse
    case requestFailed
    case unknown
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
        case .permissionDenied, .tokenExpired, .missingConfiguration:
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
