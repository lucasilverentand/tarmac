import Foundation
import Testing

@testable import Tarmac

@Suite("CacheManager")
struct CacheManagerTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tarmac-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test("prepare creates cache directory")
    func prepareCreatesDir() throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let manager = CacheManager(cacheDirectoryPath: tempDir.path)
        try manager.prepare()

        #expect(FileManager.default.fileExists(atPath: manager.baseDirectory.path))
    }

    @Test("clear removes all cache contents")
    func clearRemovesContents() throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let manager = CacheManager(cacheDirectoryPath: tempDir.path)
        try manager.prepare()

        // Create some dummy files
        let file1 = manager.baseDirectory.appendingPathComponent("file1.txt")
        let file2 = manager.baseDirectory.appendingPathComponent("file2.txt")
        try "hello".write(to: file1, atomically: true, encoding: .utf8)
        try "world".write(to: file2, atomically: true, encoding: .utf8)

        let sizeBefore = try manager.currentSizeBytes()
        #expect(sizeBefore > 0)

        try manager.clear()

        let sizeAfter = try manager.currentSizeBytes()
        #expect(sizeAfter == 0)
        // Directory should still exist after clear
        #expect(FileManager.default.fileExists(atPath: manager.baseDirectory.path))
    }

    @Test("evict removes old entries")
    func evictRemovesOldEntries() throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let manager = CacheManager(cacheDirectoryPath: tempDir.path)
        try manager.prepare()

        // Create a file and backdate it
        let oldFile = manager.baseDirectory.appendingPathComponent("old-cache.txt")
        try "stale data".write(to: oldFile, atomically: true, encoding: .utf8)

        let pastDate = Date().addingTimeInterval(-86400 * 30)  // 30 days ago
        try FileManager.default.setAttributes(
            [.modificationDate: pastDate],
            ofItemAtPath: oldFile.path
        )

        let recentFile = manager.baseDirectory.appendingPathComponent("recent-cache.txt")
        try "fresh data".write(to: recentFile, atomically: true, encoding: .utf8)

        try manager.evict(retentionDays: 14)

        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(FileManager.default.fileExists(atPath: recentFile.path))
    }

    @Test("currentSizeBytes returns correct size")
    func currentSizeBytesWorks() throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let manager = CacheManager(cacheDirectoryPath: tempDir.path)
        try manager.prepare()

        let emptySize = try manager.currentSizeBytes()
        #expect(emptySize == 0)

        let file = manager.baseDirectory.appendingPathComponent("data.bin")
        let data = Data(repeating: 0xAB, count: 4096)
        try data.write(to: file)

        let afterSize = try manager.currentSizeBytes()
        #expect(afterSize > 0)
    }

    @Test("Directory with nested subdirectories counts size correctly")
    func nestedSubdirectoriesSize() throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let manager = CacheManager(cacheDirectoryPath: tempDir.path)
        try manager.prepare()

        // Create nested directories with files
        let subdir = manager.baseDirectory.appendingPathComponent("subdir/nested")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let file1 = manager.baseDirectory.appendingPathComponent("top.bin")
        let file2 = subdir.appendingPathComponent("deep.bin")
        try Data(repeating: 0xCC, count: 2048).write(to: file1)
        try Data(repeating: 0xDD, count: 2048).write(to: file2)

        let size = try manager.currentSizeBytes()
        #expect(size > 0)

        // Clear should remove everything including nested dirs
        try manager.clear()
        let afterClear = try manager.currentSizeBytes()
        #expect(afterClear == 0)
    }

    @Test("Symbolic links in cache directory are handled")
    func symbolicLinksHandled() throws {
        let tempDir = try makeTempDir()
        defer { cleanup(tempDir) }

        let manager = CacheManager(cacheDirectoryPath: tempDir.path)
        try manager.prepare()

        // Create a real file and a symlink to it
        let realFile = tempDir.appendingPathComponent("real-file.txt")
        try "real content".write(to: realFile, atomically: true, encoding: .utf8)

        let symlink = manager.baseDirectory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realFile)

        // Should not crash when calculating size
        let size = try manager.currentSizeBytes()
        #expect(size >= 0)

        // Clear should handle symlinks gracefully
        try manager.clear()
        #expect(FileManager.default.fileExists(atPath: manager.baseDirectory.path))
        // The real file outside the cache should still exist
        #expect(FileManager.default.fileExists(atPath: realFile.path))
    }
}
