import Foundation

struct DiskImageManager: Sendable {
    func createSparseDisk(at url: URL, sizeGB: Int, overwrite: Bool = false) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        if overwrite, fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }

        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw DiskImageError.creationFailed(url)
        }

        let fileHandle = try FileHandle(forWritingTo: url)
        defer { try? fileHandle.close() }

        let sizeBytes = Int64(sizeGB) * 1024 * 1024 * 1024
        let fd = fileHandle.fileDescriptor
        guard ftruncate(fd, off_t(sizeBytes)) == 0 else {
            throw DiskImageError.truncateFailed(url, errno)
        }

        Log.vm.info("Created sparse disk at \(url.path) (\(sizeGB) GB)")
    }

    @discardableResult
    func cloneDisk(from source: URL, to destination: URL) throws -> DiskCloneResult {
        let destDir = destination.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        let startedAt = Date()
        let sourceSizeBytes = Self.logicalSizeBytes(at: source)
        var method: DiskCloneMethod = .copyOnWrite

        let result = source.path.withCString { src in
            destination.path.withCString { dst in
                Darwin.clonefile(src, dst, 0)
            }
        }

        if result != 0 {
            let cloneErrno = errno
            method = .fullCopyFallback(errno: cloneErrno)
            Log.vm.warning("clonefile failed (errno \(cloneErrno)), falling back to full copy")
            try fm.copyItem(at: source, to: destination)
        }

        let metrics = DiskCloneResult(
            source: source,
            destination: destination,
            method: method,
            duration: Date().timeIntervalSince(startedAt),
            sourceLogicalSizeBytes: sourceSizeBytes,
            destinationAllocatedSizeBytes: Self.allocatedSizeBytes(at: destination)
        )

        Log.vm.info(
            "Cloned disk from \(source.lastPathComponent) to \(destination.lastPathComponent, privacy: .public) using \(metrics.method.displayName, privacy: .public) in \(Self.formatDuration(metrics.duration), privacy: .public); source=\(Self.formatBytes(metrics.sourceLogicalSizeBytes), privacy: .public), allocated=\(Self.formatBytes(metrics.destinationAllocatedSizeBytes), privacy: .public)"
        )
        return metrics
    }

    func deleteDisk(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        Log.vm.info("Deleted disk at \(url.path)")
    }

    private static func logicalSizeBytes(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
        return values.fileSize.map { Int64($0) }
    }

    private static func allocatedSizeBytes(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]) else { return nil }
        return values.totalFileAllocatedSize.map { Int64($0) }
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3fs", duration)
    }

    private static func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "unknown" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }
}

enum DiskImageError: LocalizedError {
    case creationFailed(URL)
    case truncateFailed(URL, Int32)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let url):
            "Failed to create disk image at \(url.path)"
        case .truncateFailed(let url, let code):
            "Failed to truncate disk image at \(url.path): errno \(code)"
        }
    }
}

struct DiskCloneResult: Equatable, Sendable {
    let source: URL
    let destination: URL
    let method: DiskCloneMethod
    let duration: TimeInterval
    let sourceLogicalSizeBytes: Int64?
    let destinationAllocatedSizeBytes: Int64?
}

enum DiskCloneMethod: Equatable, Sendable {
    case copyOnWrite
    case fullCopyFallback(errno: Int32)

    var displayName: String {
        switch self {
        case .copyOnWrite:
            "APFS copy-on-write"
        case .fullCopyFallback:
            "full copy"
        }
    }
}
