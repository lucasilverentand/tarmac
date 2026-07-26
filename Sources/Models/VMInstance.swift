import Foundation

struct VMInstance: Equatable, Sendable {
    let id: UUID
    var jobId: Int64?
    let diskImagePath: URL
    let startedAt: Date
    var state: VMState

    enum VMState: String, Equatable, Sendable {
        case booting
        case running
        case stopping
        case stopped
        case failed
    }
}
