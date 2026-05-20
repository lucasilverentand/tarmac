import Foundation

struct VMConfiguration: Codable, Equatable, Hashable, Sendable {
    var cpuCount: Int = 4
    var memorySizeGB: Int = 8
    var diskSizeGB: Int = 80
    var runnerCompletionTimeoutSeconds: Int = 3_600

    init(
        cpuCount: Int = 4,
        memorySizeGB: Int = 8,
        diskSizeGB: Int = 80,
        runnerCompletionTimeoutSeconds: Int = 3_600
    ) {
        self.cpuCount = cpuCount
        self.memorySizeGB = memorySizeGB
        self.diskSizeGB = diskSizeGB
        self.runnerCompletionTimeoutSeconds = runnerCompletionTimeoutSeconds
    }

    enum CodingKeys: String, CodingKey {
        case cpuCount
        case memorySizeGB
        case diskSizeGB
        case runnerCompletionTimeoutSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpuCount = try container.decodeIfPresent(Int.self, forKey: .cpuCount) ?? 4
        memorySizeGB = try container.decodeIfPresent(Int.self, forKey: .memorySizeGB) ?? 8
        diskSizeGB = try container.decodeIfPresent(Int.self, forKey: .diskSizeGB) ?? 80
        runnerCompletionTimeoutSeconds =
            try container.decodeIfPresent(Int.self, forKey: .runnerCompletionTimeoutSeconds) ?? 3_600
    }

    var memorySize: UInt64 {
        UInt64(memorySizeGB) * 1024 * 1024 * 1024
    }
}
