import Darwin
import Foundation

enum StorageHealthStatus: String, Sendable {
    case fast
    case degraded
    case blocked

    var displayName: String {
        switch self {
        case .fast: "Fast"
        case .degraded: "Degraded"
        case .blocked: "Blocked"
        }
    }
}

enum StorageHealthIssueSeverity: String, Sendable {
    case warning
    case blocking
}

struct StorageHealthIssue: Equatable, Identifiable, Sendable {
    let severity: StorageHealthIssueSeverity
    let message: String

    var id: String { "\(severity.rawValue):\(message)" }
}

enum StorageCloneBehavior: Equatable, Sendable {
    case copyOnWrite
    case fullCopyFallback(reason: String)

    var isFastPath: Bool {
        if case .copyOnWrite = self {
            return true
        }
        return false
    }

    var displayName: String {
        switch self {
        case .copyOnWrite:
            "APFS copy-on-write"
        case .fullCopyFallback:
            "Full-copy fallback"
        }
    }
}

struct StorageVolumeInfo: Equatable, Sendable {
    let fileSystemType: String?
    let localizedFormatDescription: String?
    let mountPoint: String?
    let isLocal: Bool
    let isReadOnly: Bool
    let isRemovable: Bool
    let isEjectable: Bool
    let isInternal: Bool?
    let totalCapacityBytes: Int64?
    let availableCapacityBytes: Int64?

    var isAPFS: Bool {
        fileSystemType?.lowercased() == "apfs"
            || localizedFormatDescription?.localizedCaseInsensitiveContains("apfs") == true
    }

    var formatDisplayName: String {
        if let fileSystemType, !fileSystemType.isEmpty {
            return fileSystemType.uppercased()
        }
        return localizedFormatDescription ?? "Unknown"
    }

    var isExternalRemovable: Bool {
        isInternal == false && (isRemovable || isEjectable)
    }
}

struct StorageHealth: Equatable, Sendable {
    let rootDirectory: URL
    let isReachable: Bool
    let isCloudSyncedPath: Bool
    let volume: StorageVolumeInfo?
    let cloneBehavior: StorageCloneBehavior
    let installerArtifactSizeBytes: Int64
    let issues: [StorageHealthIssue]

    var status: StorageHealthStatus {
        if issues.contains(where: { $0.severity == .blocking }) {
            return .blocked
        }
        if !cloneBehavior.isFastPath || issues.contains(where: { $0.severity == .warning }) {
            return .degraded
        }
        return .fast
    }

    var isReadyForJobs: Bool {
        status != .blocked
    }

    var blockingIssues: [StorageHealthIssue] {
        issues.filter { $0.severity == .blocking }
    }

    var warnings: [StorageHealthIssue] {
        issues.filter { $0.severity == .warning }
    }

    var summary: String {
        switch status {
        case .fast:
            "Fast APFS clone path verified."
        case .degraded:
            warnings.map(\.message).joined(separator: " ")
        case .blocked:
            blockingIssues.map(\.message).joined(separator: " ")
        }
    }
}

enum StorageValidationError: LocalizedError {
    case unsuitable(StorageHealth)

    var errorDescription: String? {
        switch self {
        case .unsuitable(let health):
            "Storage location is not suitable for VM images: \(health.summary)"
        }
    }
}

extension StorageManager {
    static let minimumSetupFreeBytes: Int64 = 25 * 1024 * 1024 * 1024

    func evaluateHealth(
        minimumFreeBytes: Int64? = minimumSetupFreeBytes,
        lowCapacitySeverity: StorageHealthIssueSeverity = .warning
    ) -> StorageHealth {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let reachable = fm.fileExists(atPath: rootDirectory.path, isDirectory: &isDirectory)
        var issues: [StorageHealthIssue] = []

        if !reachable {
            issues.append(.blocking("Storage root is not reachable."))
        } else if !isDirectory.boolValue {
            issues.append(.blocking("Storage root is not a directory."))
        }

        let volume = reachable && isDirectory.boolValue ? Self.volumeInfo(for: rootDirectory) : nil
        if reachable && isDirectory.boolValue && volume == nil {
            issues.append(.blocking("Storage volume metadata could not be read."))
        }

        if let volume {
            if !volume.isLocal {
                issues.append(.blocking("Storage volume is not local."))
            }
            if volume.isReadOnly {
                issues.append(.blocking("Storage volume is read-only."))
            }
            if !volume.isAPFS {
                issues.append(.blocking("Storage volume uses \(volume.formatDisplayName) instead of APFS."))
            }
            if volume.isExternalRemovable {
                issues.append(
                    .warning("External removable storage detected; verify it is a fast Thunderbolt NVMe SSD.")
                )
            }
            if let minimumFreeBytes,
                let available = volume.availableCapacityBytes,
                available < minimumFreeBytes
            {
                issues.append(
                    StorageHealthIssue(
                        severity: lowCapacitySeverity,
                        message:
                            "Storage volume has \(Self.formatBytes(available)) available; \(Self.formatBytes(minimumFreeBytes)) required."
                    )
                )
            }
        }

        let cloudSynced = Self.isCloudSyncedPath(rootDirectory)
        if cloudSynced {
            issues.append(.blocking("Storage root appears to be inside a cloud-synced folder."))
        }

        let cloneBehavior: StorageCloneBehavior
        if reachable && isDirectory.boolValue {
            cloneBehavior = probeCloneBehavior()
        } else {
            cloneBehavior = .fullCopyFallback(reason: "Storage root is not reachable.")
        }

        if case .fullCopyFallback(let reason) = cloneBehavior {
            issues.append(.warning("APFS clone probe failed; VM disks would use full-copy fallback. \(reason)"))
        }

        return StorageHealth(
            rootDirectory: rootDirectory,
            isReachable: reachable && isDirectory.boolValue,
            isCloudSyncedPath: cloudSynced,
            volume: volume,
            cloneBehavior: cloneBehavior,
            installerArtifactSizeBytes: (try? installerArtifactSizeBytes()) ?? 0,
            issues: issues
        )
    }

    func validateForSetup() throws {
        try prepareBaseDirectories()
        let health = evaluateHealth()
        if !health.blockingIssues.isEmpty {
            throw StorageValidationError.unsuitable(health)
        }
    }

    func probeCloneBehavior() -> StorageCloneBehavior {
        let probeID = UUID().uuidString
        let source = tmpDirectory.appendingPathComponent("clone-probe-\(probeID).source")
        let destination = tmpDirectory.appendingPathComponent("clone-probe-\(probeID).clone")

        do {
            try FileManager.default.createDirectory(at: tmpDirectory, withIntermediateDirectories: true)
            try Data(repeating: 0xA5, count: 4096).write(to: source, options: .atomic)
        } catch {
            return .fullCopyFallback(reason: "Could not create probe file: \(error.localizedDescription)")
        }

        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let result = source.path.withCString { src in
            destination.path.withCString { dst in
                Darwin.clonefile(src, dst, 0)
            }
        }

        if result == 0 {
            return .copyOnWrite
        }

        return .fullCopyFallback(reason: POSIXError(.init(rawValue: errno) ?? .EIO).localizedDescription)
    }

    private static func volumeInfo(for url: URL) -> StorageVolumeInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .volumeIsRemovableKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey,
        ]

        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let stat = statfsInfo(for: url)
        let isLocal = values.volumeIsLocal ?? stat?.isLocal ?? false

        return StorageVolumeInfo(
            fileSystemType: stat?.fileSystemType,
            localizedFormatDescription: values.volumeLocalizedFormatDescription,
            mountPoint: stat?.mountPoint,
            isLocal: isLocal,
            isReadOnly: values.volumeIsReadOnly ?? false,
            isRemovable: values.volumeIsRemovable ?? false,
            isEjectable: values.volumeIsEjectable ?? false,
            isInternal: values.volumeIsInternal,
            totalCapacityBytes: values.volumeTotalCapacity.map { Int64($0) },
            availableCapacityBytes: values.volumeAvailableCapacityForImportantUsage.map { Int64($0) }
        )
    }

    private static func statfsInfo(for url: URL) -> (fileSystemType: String, mountPoint: String, isLocal: Bool)? {
        var stats = statfs()
        guard statfs(url.path, &stats) == 0 else { return nil }

        return (
            fileSystemType: string(from: stats.f_fstypename),
            mountPoint: string(from: stats.f_mntonname),
            isLocal: (stats.f_flags & UInt32(MNT_LOCAL)) != 0
        )
    }

    private static func string<T>(from tuple: T) -> String {
        withUnsafePointer(to: tuple) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { buffer in
                String(cString: buffer)
            }
        }
    }

    private static func isCloudSyncedPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let components = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        let cloudComponents = [
            "dropbox",
            "google drive",
            "onedrive",
            "box sync",
            "creative cloud files",
        ]
        if components.contains(where: { component in
            cloudComponents.contains { component == $0 || component.hasPrefix($0) }
        }) {
            return true
        }

        let cloudMarkers = [
            "/Library/Mobile Documents/",
            "/Library/CloudStorage/",
            "/Dropbox/",
            "/Google Drive/",
            "/OneDrive/",
            "/Box Sync/",
            "/Creative Cloud Files/",
        ]

        return cloudMarkers.contains { path.localizedCaseInsensitiveContains($0) }
    }

    fileprivate static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }
}

private extension StorageHealthIssue {
    static func blocking(_ message: String) -> StorageHealthIssue {
        StorageHealthIssue(severity: .blocking, message: message)
    }

    static func warning(_ message: String) -> StorageHealthIssue {
        StorageHealthIssue(severity: .warning, message: message)
    }
}
