import Foundation

struct VMConfiguration: Codable, Sendable {
    var cpuCount: Int = 4
    var memorySizeGB: Int = 8
    var diskSizeGB: Int = 80

    var memorySize: UInt64 {
        UInt64(memorySizeGB) * 1024 * 1024 * 1024
    }
}
