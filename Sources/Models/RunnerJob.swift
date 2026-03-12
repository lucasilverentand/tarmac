import Foundation

struct RunnerJob: Identifiable, Codable, Sendable {
    let id: Int64
    let organizationName: String
    var status: JobStatus
    var workflowName: String?
    var repositoryName: String?
    var jitConfig: String?
    let queuedAt: Date
    var startedAt: Date?
    var completedAt: Date?
    var failureReason: String?

    var duration: TimeInterval? {
        guard let start = startedAt else { return nil }
        let end = completedAt ?? Date()
        return end.timeIntervalSince(start)
    }
}
