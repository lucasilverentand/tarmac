import Foundation

struct GitHubQueuedWorkflowJob: Equatable, Sendable {
    let id: Int64
    let runId: Int64
    let name: String?
    let repositoryName: String
    let labels: [String]
    let queuedAt: Date?
    let htmlURL: String?
}
