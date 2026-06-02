import Foundation

struct RunnerJob: Identifiable, Codable, Sendable {
    let id: Int64
    let organizationName: String
    var runnerRequestId: Int64? = nil
    var status: JobStatus
    var workflowName: String? = nil
    var repositoryName: String? = nil
    /// Runner group the scale set belongs to, discovered at polling-session
    /// creation. Used when generating the JIT runner config; nil falls back to
    /// the default group.
    var runnerGroupId: Int? = nil
    var jitConfig: String? = nil
    var registrationToken: String? = nil
    var runnerRegistrationURL: String? = nil
    var runnerRegistrationLabels: [String]? = nil
    var runnerName: String? = nil
    var runnerLease: RunnerLease? = nil
    var vmInstanceId: UUID? = nil
    var diagnosticsBundlePath: String? = nil
    let queuedAt: Date
    var startedAt: Date? = nil
    var completedAt: Date? = nil
    var failureReason: String? = nil

    var duration: TimeInterval? {
        guard let start = startedAt else { return nil }
        let end = completedAt ?? Date()
        return end.timeIntervalSince(start)
    }
}
