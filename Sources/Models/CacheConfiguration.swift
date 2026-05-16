import Foundation

struct CacheConfiguration: Codable, Sendable {
    var isEnabled: Bool = true
    var maxSizeGB: Int = 20
    var retentionDays: Int = 14

    /// The directory on the host where persistent caches are stored.
    /// Resolved at runtime from ConfigStore.storageRootPath + "/actions-cache".
    var hostCachePath: String = ""

    /// The mount point inside the guest VM where the cache directory appears.
    static let guestMountTag = "actions-cache"
    static let guestMountPoint = "/Volumes/actions-cache"

    static let swiftPMDirectoryName = "swiftpm"
    static let xcodeDerivedDataDirectoryName = "xcode-derived-data"
    static let cocoaPodsDirectoryName = "cocoapods"
    static let npmDirectoryName = "npm"

    static var guestCacheTargets: [GuestCacheTarget] {
        [
            GuestCacheTarget(
                name: "SwiftPM",
                directoryName: swiftPMDirectoryName,
                guestPath: "\(guestMountPoint)/\(swiftPMDirectoryName)",
                environmentVariable: "TARMAC_SWIFTPM_CACHE_PATH"
            ),
            GuestCacheTarget(
                name: "Xcode DerivedData",
                directoryName: xcodeDerivedDataDirectoryName,
                guestPath: "\(guestMountPoint)/\(xcodeDerivedDataDirectoryName)",
                environmentVariable: "TARMAC_XCODE_DERIVED_DATA_PATH"
            ),
            GuestCacheTarget(
                name: "CocoaPods",
                directoryName: cocoaPodsDirectoryName,
                guestPath: "\(guestMountPoint)/\(cocoaPodsDirectoryName)",
                environmentVariable: "TARMAC_COCOAPODS_CACHE_PATH"
            ),
            GuestCacheTarget(
                name: "npm",
                directoryName: npmDirectoryName,
                guestPath: "\(guestMountPoint)/\(npmDirectoryName)",
                environmentVariable: "NPM_CONFIG_CACHE"
            ),
        ]
    }
}

struct GuestCacheTarget: Equatable, Sendable {
    let name: String
    let directoryName: String
    let guestPath: String
    let environmentVariable: String
}
