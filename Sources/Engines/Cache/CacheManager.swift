import Foundation

struct CacheManager: Sendable {
    let baseDirectory: URL

    init(cacheDirectoryPath: String) {
        self.baseDirectory = URL(fileURLWithPath: cacheDirectoryPath)
            .appendingPathComponent("actions-cache")
    }

    /// Ensure the persistent cache directory structure exists on the host.
    func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        Log.cache.info("Actions cache directory ready at \(baseDirectory.path)")
    }

    /// Evict cache entries older than the retention period.
    func evict(retentionDays: Int) throws {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)

        guard fm.fileExists(atPath: baseDirectory.path) else { return }

        let contents = try fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var evictedCount = 0
        for item in contents {
            let values = try item.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values.contentModificationDate, modified < cutoff {
                try fm.removeItem(at: item)
                evictedCount += 1
            }
        }

        if evictedCount > 0 {
            Log.cache.info("Evicted \(evictedCount) stale cache entries (older than \(retentionDays) days)")
        }
    }

    /// Enforce maximum cache size by removing oldest entries first.
    func enforceMaxSize(maxSizeGB: Int) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDirectory.path) else { return }

        let maxBytes = Int64(maxSizeGB) * 1024 * 1024 * 1024
        let currentSize = try directorySize(at: baseDirectory)

        guard currentSize > maxBytes else { return }

        let contents = try fm.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        )

        // Sort oldest first
        let sorted = try contents.sorted { a, b in
            let aDate = try a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let bDate = try b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return aDate < bDate
        }

        var remaining = currentSize
        for item in sorted {
            guard remaining > maxBytes else { break }
            let size = try itemSize(at: item)
            try fm.removeItem(at: item)
            remaining -= size
            Log.cache.debug("Evicted \(item.lastPathComponent) (\(size / 1024 / 1024) MB)")
        }

        Log.cache.info("Cache trimmed from \(currentSize / 1024 / 1024) MB to \(remaining / 1024 / 1024) MB")
    }

    /// Current cache size in bytes.
    func currentSizeBytes() throws -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDirectory.path) else { return 0 }
        return try directorySize(at: baseDirectory)
    }

    /// Remove the entire cache directory.
    func clear() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: baseDirectory.path) else { return }
        try fm.removeItem(at: baseDirectory)
        try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        Log.cache.info("Cache cleared")
    }

    // MARK: - Private

    private func directorySize(at url: URL) throws -> Int64 {
        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        )

        var total: Int64 = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            total += try itemSize(at: fileURL)
        }
        return total
    }

    private func itemSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(values.totalFileAllocatedSize ?? 0)
    }
}
