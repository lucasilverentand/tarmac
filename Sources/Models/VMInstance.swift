import Foundation

struct VMInstance: Sendable {
    let id: UUID
    var jobId: Int64
    let diskImagePath: URL
    let startedAt: Date
    var state: VMState

    enum VMState: String, Sendable {
        case booting
        case running
        case stopping
        case stopped
        case failed
    }
}
