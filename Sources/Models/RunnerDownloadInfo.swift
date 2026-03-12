import Foundation

struct RunnerDownloadInfo: Codable, Sendable {
    let os: String
    let architecture: String
    let downloadUrl: String
    let filename: String
    let sha256Checksum: String?

    enum CodingKeys: String, CodingKey {
        case os
        case architecture
        case downloadUrl = "download_url"
        case filename
        case sha256Checksum = "sha256_checksum"
    }
}
