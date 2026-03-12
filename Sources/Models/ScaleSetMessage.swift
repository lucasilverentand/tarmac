import Foundation

struct ScaleSetMessage: Codable, Sendable {
    let messageId: Int64
    let messageType: String
    let body: String
    let statistics: ScaleSetStatistics?
}

struct ScaleSetStatistics: Codable, Sendable {
    let totalAvailableJobs: Int
    let totalAssignedJobs: Int
    let totalRunningJobs: Int
    let totalRegisteredRunners: Int
}

struct ScaleSetSession: Codable, Sendable {
    let sessionId: String?
    let ownerName: String?
    let runnerScaleSet: RunnerScaleSet?
}

struct RunnerScaleSet: Codable, Sendable {
    let id: Int
    let name: String?
    let runnerGroupId: Int?
    let runnerGroupName: String?
}

struct JobAvailableMessage: Codable, Sendable {
    let jobMessageBase: JobMessageBase

    struct JobMessageBase: Codable, Sendable {
        let jobId: Int64
        let runnerRequestId: Int64
        let repositoryName: String?
        let ownerName: String?
        let workflowRunName: String?
    }
}

struct JobCompletedMessage: Codable, Sendable {
    let jobId: Int64
    let result: String?
}
