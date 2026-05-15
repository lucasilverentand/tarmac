import Foundation

struct DiagnosticsRetentionConfiguration: Codable, Equatable, Sendable {
    var maxBundleCount: Int = 100
    var maxAgeDays: Int = 14
    var maxSizeMB: Int = 512
    var keepSuccessfulJobLogs: Bool = false

    var maxSizeBytes: Int64 {
        Int64(max(1, maxSizeMB)) * 1024 * 1024
    }
}
