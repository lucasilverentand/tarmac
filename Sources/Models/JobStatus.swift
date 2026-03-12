import Foundation

enum JobStatus: String, Codable, Sendable {
    case pending
    case provisioning
    case running
    case completed
    case failed
}
