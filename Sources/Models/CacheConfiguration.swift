import Foundation

struct CacheConfiguration: Codable, Sendable {
    var isEnabled: Bool = true
    var maxSizeGB: Int = 20
    var retentionDays: Int = 14

    /// The directory on the host where persistent caches are stored.
    /// Resolved at runtime from ConfigStore.cacheDirectoryPath + "/actions-cache".
    var hostCachePath: String = ""

    /// The mount point inside the guest VM where the cache directory appears.
    static let guestMountTag = "actions-cache"
    static let guestMountPoint = "/Volumes/actions-cache"
}
