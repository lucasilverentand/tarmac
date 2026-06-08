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
    static let cocoaPodsDirectoryName = "cocoapods"
    static let pubCacheDirectoryName = "pub-cache"
    static let npmDirectoryName = "npm"
    static let yarnDirectoryName = "yarn"
    static let pnpmDirectoryName = "pnpm-store"
    static let bunDirectoryName = "bun-install-cache"

    static var guestCacheTargets: [GuestCacheTarget] {
        [
            GuestCacheTarget(
                name: "SwiftPM",
                directoryName: swiftPMDirectoryName,
                guestPath: "\(guestMountPoint)/\(swiftPMDirectoryName)",
                environmentVariable: "TARMAC_SWIFTPM_CACHE_PATH"
            ),
            GuestCacheTarget(
                name: "CocoaPods",
                directoryName: cocoaPodsDirectoryName,
                guestPath: "\(guestMountPoint)/\(cocoaPodsDirectoryName)",
                environmentVariable: "TARMAC_COCOAPODS_CACHE_PATH"
            ),
            GuestCacheTarget(
                name: "Flutter pub",
                directoryName: pubCacheDirectoryName,
                guestPath: "\(guestMountPoint)/\(pubCacheDirectoryName)",
                environmentVariable: "PUB_CACHE"
            ),
            GuestCacheTarget(
                name: "npm",
                directoryName: npmDirectoryName,
                guestPath: "\(guestMountPoint)/\(npmDirectoryName)",
                environmentVariable: "NPM_CONFIG_CACHE"
            ),
            GuestCacheTarget(
                name: "Yarn",
                directoryName: yarnDirectoryName,
                guestPath: "\(guestMountPoint)/\(yarnDirectoryName)",
                environmentVariable: "YARN_CACHE_FOLDER"
            ),
            GuestCacheTarget(
                name: "pnpm",
                directoryName: pnpmDirectoryName,
                guestPath: "\(guestMountPoint)/\(pnpmDirectoryName)",
                environmentVariable: "PNPM_STORE_PATH"
            ),
            GuestCacheTarget(
                name: "Bun",
                directoryName: bunDirectoryName,
                guestPath: "\(guestMountPoint)/\(bunDirectoryName)",
                environmentVariable: "BUN_INSTALL_CACHE_DIR"
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
