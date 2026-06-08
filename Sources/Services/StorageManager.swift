import Darwin
import Foundation

struct StorageManager: Sendable {
    let rootDirectory: URL

    init(rootPath: String) {
        self.rootDirectory = URL(fileURLWithPath: rootPath).standardizedFileURL
    }

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    static var defaultRootDirectory: URL {
        appSupportDirectory.appendingPathComponent("Storage", isDirectory: true)
    }

    static var appSupportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Tarmac", isDirectory: true)
    }

    var baseImageURL: URL { rootDirectory.appendingPathComponent("BaseImage.img") }
    var baseImageVerifiedMarkerURL: URL { platformDirectory.appendingPathComponent("baseImageVerified.json") }
    var guestBootstrapVerifiedMarkerURL: URL { platformDirectory.appendingPathComponent("guestBootstrapVerified.json") }
    var restoreIPSWURL: URL { rootDirectory.appendingPathComponent("restore.ipsw") }
    var ipswResumeDataURL: URL { rootDirectory.appendingPathComponent("ipsw-resume.json") }
    var platformDirectory: URL { rootDirectory.appendingPathComponent("Platform", isDirectory: true) }
    var runnerDirectory: URL { rootDirectory.appendingPathComponent("runner", isDirectory: true) }
    var jobsDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["TARMAC_JOBS_DIRECTORY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return rootDirectory.appendingPathComponent("jobs", isDirectory: true)
    }
    var disksDirectory: URL { rootDirectory.appendingPathComponent("disks", isDirectory: true) }
    var diagnosticsDirectory: URL { rootDirectory.appendingPathComponent("diagnostics", isDirectory: true) }
    var actionsCacheDirectory: URL { rootDirectory.appendingPathComponent("actions-cache", isDirectory: true) }
    var legacySharedCacheDirectory: URL { rootDirectory.appendingPathComponent("cache", isDirectory: true) }
    var tmpDirectory: URL { rootDirectory.appendingPathComponent("tmp", isDirectory: true) }
    var partialIPSWURL: URL { tmpDirectory.appendingPathComponent("restore.ipsw.download") }

    func storageReport() -> StorageReport {
        let health = evaluateHealth()
        return StorageReport(
            rootPath: rootDirectory.path,
            totalManagedBytes: (try? totalManagedSizeBytes()) ?? 0,
            baseImageBytes: (try? itemSize(at: baseImageURL)) ?? 0,
            platformDataBytes: (try? itemSize(at: platformDirectory)) ?? 0,
            installerArtifactBytes: health.installerArtifactSizeBytes,
            transientBytes: transientSizeBytes(),
            diagnosticsBytes: (try? itemSize(at: diagnosticsDirectory)) ?? 0,
            cacheBytes: (try? itemSize(at: actionsCacheDirectory)) ?? 0,
            freeBytes: health.volume?.availableCapacityBytes ?? availableCapacityBytes(),
            health: health
        )
    }

    func prepareBaseDirectories() throws {
        let fm = FileManager.default
        for directory in [
            rootDirectory, platformDirectory, jobsDirectory, disksDirectory, diagnosticsDirectory,
            actionsCacheDirectory, tmpDirectory,
        ] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func totalManagedSizeBytes() throws -> Int64 {
        try sizeOfItems([
            baseImageURL,
            restoreIPSWURL,
            ipswResumeDataURL,
            platformDirectory,
            runnerDirectory,
            jobsDirectory,
            disksDirectory,
            diagnosticsDirectory,
            actionsCacheDirectory,
            legacySharedCacheDirectory,
            tmpDirectory,
        ])
    }

    func availableCapacityBytes() -> Int64? {
        guard let values = try? rootDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        else {
            return nil
        }
        return values.volumeAvailableCapacityForImportantUsage
    }

    func storageWarning(minimumFreeBytes: Int64) -> String? {
        let health = evaluateHealth(minimumFreeBytes: minimumFreeBytes)
        return health.issues.first?.message
    }

    func isBaseImageVerified() -> Bool {
        FileManager.default.fileExists(atPath: baseImageVerifiedMarkerURL.path)
    }

    func isGuestBootstrapVerified() -> Bool {
        FileManager.default.fileExists(atPath: guestBootstrapVerifiedMarkerURL.path)
    }

    func markBaseImageVerified(at date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: platformDirectory, withIntermediateDirectories: true)
        let marker = BaseImageVerificationMarker(verifiedAt: date)
        let data = try JSONEncoder.iso8601.encode(marker)
        try data.write(to: baseImageVerifiedMarkerURL, options: .atomic)
    }

    func markGuestBootstrapVerified(at date: Date = Date()) throws {
        try FileManager.default.createDirectory(at: platformDirectory, withIntermediateDirectories: true)
        let marker = GuestBootstrapVerificationMarker(verifiedAt: date)
        let data = try JSONEncoder.iso8601.encode(marker)
        try data.write(to: guestBootstrapVerifiedMarkerURL, options: .atomic)
    }

    func clearBaseImageVerified() throws {
        for url in [baseImageVerifiedMarkerURL, guestBootstrapVerifiedMarkerURL] {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func clearGuestBootstrapVerified() throws {
        let url = guestBootstrapVerifiedMarkerURL
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func cleanupTransientFiles(olderThan interval: TimeInterval = 24 * 60 * 60) throws {
        let cutoff = Date().addingTimeInterval(-interval)
        try removeContents(in: jobsDirectory, olderThan: cutoff)
        try removeContents(in: disksDirectory, olderThan: cutoff)
        try removeContents(in: tmpDirectory, olderThan: cutoff)
    }

    @discardableResult
    func cleanupOrphanedJobArtifacts(activeLeases: [RunnerLease]) throws -> OrphanedJobArtifactCleanupResult {
        try prepareBaseDirectories()

        let activeDiskPaths = Set(
            activeLeases.compactMap(\.executionAttempt?.diskImagePath).map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }
        )
        let activeSharedDirectoryPaths = Set(
            activeLeases.compactMap(\.executionAttempt?.sharedDirectoryPath).map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            }
        )

        var result = OrphanedJobArtifactCleanupResult()
        try removeUnownedContents(
            in: disksDirectory,
            preserving: activeDiskPaths,
            removedKind: .disk,
            result: &result
        )
        try removeUnownedContents(
            in: jobsDirectory,
            preserving: activeSharedDirectoryPaths,
            removedKind: .jobDirectory,
            result: &result
        )
        return result
    }

    func installerArtifactSizeBytes() throws -> Int64 {
        try sizeOfItems(installerArtifactURLs(includeRestoreImage: true))
    }

    @discardableResult
    func cleanupInstallerArtifactsAfterVerification(keepRestoreImage: Bool) throws -> InstallerArtifactCleanupResult {
        var result = InstallerArtifactCleanupResult()
        let urls = installerArtifactURLs(includeRestoreImage: !keepRestoreImage)

        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            result.removedBytes += try itemSize(at: url)
            try FileManager.default.removeItem(at: url)
            result.removedItems += 1
        }

        return result
    }

    func cleanupJobScratch(olderThan interval: TimeInterval = 24 * 60 * 60) throws {
        let cutoff = Date().addingTimeInterval(-interval)
        try removeContents(in: jobsDirectory, olderThan: cutoff)
        try removeContents(in: tmpDirectory, olderThan: cutoff)
    }

    func cleanupDebugDisks(olderThan interval: TimeInterval = 24 * 60 * 60) throws {
        let cutoff = Date().addingTimeInterval(-interval)
        try removeContents(in: disksDirectory, olderThan: cutoff)
    }

    func cleanupInstallerArtifacts() throws {
        try cleanupInstallerArtifactsAfterVerification(keepRestoreImage: false)
    }

    @discardableResult
    func resetBaseImage(preserveRestoreImage: Bool = true) throws -> BaseImageResetResult {
        var result = BaseImageResetResult()
        let fm = FileManager.default

        for url in [baseImageURL, platformDirectory] {
            guard fm.fileExists(atPath: url.path) else { continue }
            result.removedBytes += (try? itemSize(at: url)) ?? 0
            try fm.removeItem(at: url)
            result.removedItems += 1
        }

        if !preserveRestoreImage, fm.fileExists(atPath: restoreIPSWURL.path) {
            result.removedBytes += (try? itemSize(at: restoreIPSWURL)) ?? 0
            try fm.removeItem(at: restoreIPSWURL)
            result.removedItems += 1
        }

        try prepareBaseDirectories()
        return result
    }

    @discardableResult
    func migrateManagedData(from oldRoot: URL?, explicitBaseImageURL: URL?) throws -> StorageMigrationResult {
        try prepareBaseDirectories()

        var result = StorageMigrationResult()
        let fm = FileManager.default
        var sources: [(URL, URL)] = []

        if let oldRoot {
            let oldStorage = StorageManager(rootDirectory: oldRoot)
            sources.append(contentsOf: [
                (oldStorage.baseImageURL, baseImageURL),
                (oldStorage.restoreIPSWURL, restoreIPSWURL),
                (oldStorage.ipswResumeDataURL, ipswResumeDataURL),
                (oldRoot.appendingPathComponent("ipsw-resume.data"), ipswResumeDataURL),
                (oldStorage.platformDirectory, platformDirectory),
                (oldStorage.runnerDirectory, runnerDirectory),
                (oldStorage.jobsDirectory, jobsDirectory),
                (oldStorage.disksDirectory, disksDirectory),
                (oldStorage.diagnosticsDirectory, diagnosticsDirectory),
                (oldStorage.actionsCacheDirectory, actionsCacheDirectory),
                (oldStorage.legacySharedCacheDirectory, legacySharedCacheDirectory),
                (oldStorage.tmpDirectory, tmpDirectory),
            ])
        }

        let legacyAppSupport = Self.appSupportDirectory
        sources.append(contentsOf: [
            (legacyAppSupport.appendingPathComponent("BaseImage.img"), baseImageURL),
            (legacyAppSupport.appendingPathComponent("restore.ipsw"), restoreIPSWURL),
            (legacyAppSupport.appendingPathComponent("ipsw-resume.data"), ipswResumeDataURL),
            (legacyAppSupport.appendingPathComponent("ipsw-resume.json"), ipswResumeDataURL),
            (legacyAppSupport.appendingPathComponent("Platform", isDirectory: true), platformDirectory),
        ])

        if let explicitBaseImageURL {
            sources.append((explicitBaseImageURL, baseImageURL))
        }

        for (source, destination) in sources {
            try moveIfPresent(from: source, to: destination, fileManager: fm, result: &result)
        }

        return result
    }

    private func moveIfPresent(
        from source: URL,
        to destination: URL,
        fileManager fm: FileManager,
        result: inout StorageMigrationResult
    ) throws {
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        guard sourcePath != destinationPath else { return }
        guard fm.fileExists(atPath: sourcePath) else { return }

        if fm.fileExists(atPath: destinationPath) {
            var sourceIsDirectory: ObjCBool = false
            var destinationIsDirectory: ObjCBool = false
            fm.fileExists(atPath: sourcePath, isDirectory: &sourceIsDirectory)
            fm.fileExists(atPath: destinationPath, isDirectory: &destinationIsDirectory)
            if sourceIsDirectory.boolValue && destinationIsDirectory.boolValue {
                let contents = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                for item in contents {
                    let childDestination = destination.appendingPathComponent(item.lastPathComponent)
                    if fm.fileExists(atPath: childDestination.path) {
                        result.skippedExistingDestination += 1
                        continue
                    }
                    try fm.moveItem(at: item, to: childDestination)
                    result.movedItems += 1
                }
                if (try? fm.contentsOfDirectory(atPath: sourcePath).isEmpty) == true {
                    try? fm.removeItem(at: source)
                }
            } else {
                result.skippedExistingDestination += 1
            }
            return
        }

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: source, to: destination)
        result.movedItems += 1
        if destinationPath == baseImageURL.standardizedFileURL.path {
            result.movedBaseImage = true
        }
    }

    private func removeContents(in directory: URL, olderThan cutoff: Date) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }

        let contents = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        for item in contents {
            let modified = try item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if modified ?? .distantPast < cutoff {
                try fm.removeItem(at: item)
            }
        }
    }

    private func sizeOfItems(_ urls: [URL]) throws -> Int64 {
        var total: Int64 = 0
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            total += try itemSize(at: url)
        }
        return total
    }

    private func itemSize(at url: URL) throws -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        if !isDirectory.boolValue {
            let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            return Int64(values.totalFileAllocatedSize ?? 0)
        }

        let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        )

        var total: Int64 = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private func installerArtifactURLs(includeRestoreImage: Bool) -> [URL] {
        var urls: [URL] = [
            ipswResumeDataURL,
            partialIPSWURL,
        ]

        if includeRestoreImage {
            urls.append(restoreIPSWURL)
        }

        if let tmpContents = try? FileManager.default.contentsOfDirectory(
            at: tmpDirectory,
            includingPropertiesForKeys: nil
        ) {
            urls.append(
                contentsOf: tmpContents.filter {
                    $0.lastPathComponent.hasPrefix("ipsw-") && $0.pathExtension == "ipsw"
                }
            )
        }

        return urls
    }

    private func transientSizeBytes() -> Int64 {
        (try? sizeOfItems([jobsDirectory, disksDirectory, tmpDirectory])) ?? 0
    }

    private func removeUnownedContents(
        in directory: URL,
        preserving preservedPaths: Set<String>,
        removedKind: OrphanedJobArtifactCleanupResult.RemovedKind,
        result: inout OrphanedJobArtifactCleanupResult
    ) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }

        let contents = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        )

        for url in contents {
            let path = url.standardizedFileURL.path
            guard !preservedPaths.contains(path) else { continue }
            result.removedBytes += (try? itemSize(at: url)) ?? 0
            try fm.removeItem(at: url)
            result.recordRemoval(kind: removedKind)
        }
    }
}

struct StorageMigrationResult: Sendable {
    var movedItems: Int = 0
    var skippedExistingDestination: Int = 0
    var movedBaseImage: Bool = false
}

struct InstallerArtifactCleanupResult: Equatable, Sendable {
    var removedItems: Int = 0
    var removedBytes: Int64 = 0
}

struct BaseImageResetResult: Equatable, Sendable {
    var removedItems: Int = 0
    var removedBytes: Int64 = 0
}

struct OrphanedJobArtifactCleanupResult: Equatable, Sendable {
    enum RemovedKind: Sendable {
        case disk
        case jobDirectory
    }

    var removedDisks: Int = 0
    var removedJobDirectories: Int = 0
    var removedBytes: Int64 = 0

    var removedItems: Int {
        removedDisks + removedJobDirectories
    }

    mutating func recordRemoval(kind: RemovedKind) {
        switch kind {
        case .disk:
            removedDisks += 1
        case .jobDirectory:
            removedJobDirectories += 1
        }
    }
}

struct StorageReport: Sendable {
    var rootPath: String
    var totalManagedBytes: Int64
    var baseImageBytes: Int64
    var platformDataBytes: Int64
    var installerArtifactBytes: Int64
    var transientBytes: Int64
    var diagnosticsBytes: Int64
    var cacheBytes: Int64
    var freeBytes: Int64?
    var health: StorageHealth
}

struct BaseImageVerificationMarker: Codable, Sendable {
    let verifiedAt: Date
}

struct GuestBootstrapVerificationMarker: Codable, Sendable {
    let verifiedAt: Date
}

extension JSONEncoder {
    fileprivate static let iso8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
