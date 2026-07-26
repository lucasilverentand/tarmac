import Foundation

enum JobStatus: String, Codable, Equatable, Sendable {
    case pending
    case provisioning
    case running
    case completed
    case failed
}
