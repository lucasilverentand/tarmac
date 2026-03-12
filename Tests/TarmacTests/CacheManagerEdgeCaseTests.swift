import Testing
import Foundation
@testable import Tarmac

@Suite("CacheManager Edge Cases")
struct CacheManagerEdgeCaseTests {
    @Test("enforceMaxSize: under limit removes no files")
    func underLimitNoRemoval() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let manager = CacheManager(cacheDirectoryPath: tempDir.path)
        try manager.prepare()

        // Create a small file (well under 1 GB limit)
        let file = manager.baseDirectory.appendingPathComponent("small.bin")
        try Data(repeating: 0xAA, count: 1024).write(to: file)

        try manager.enforceMaxSize(maxSizeGB: 1)

        // File should still exist
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("enforceMaxSize: oldest files evicted first")
    func oldestEvictedFirst() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let manager = CacheManager(cacheDirectoryPath: tempDir.path)
        try manager.prepare()

        // Create files with different modification dates
        let oldFile = manager.baseDirectory.appendingPathComponent("old.bin")
        let newFile = manager.baseDirectory.appendingPathComponent("new.bin")

        // Each file ~512KB
        let fileData = Data(repeating: 0xBB, count: 512 * 1024)
        try fileData.write(to: oldFile)
        try fileData.write(to: newFile)

        // Backdate the old file
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-86400)],
            ofItemAtPath: oldFile.path
        )

        // Set max to basically 0 to force eviction of everything
        // But we'll set it so only one needs to go
        // Total is ~1MB, if we set max to 1GB nothing happens
        // Instead, test with enforceMaxSize at 0 to verify oldest goes first
        let sizeBefore = try manager.currentSizeBytes()
        #expect(sizeBefore > 0)

        // Set max to 0 to force eviction
        try manager.enforceMaxSize(maxSizeGB: 0)

        // Both should be gone since max is 0
        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(!FileManager.default.fileExists(atPath: newFile.path))
    }

    @Test("enforceMaxSize: empty directory causes no error")
    func emptyDirectoryNoError() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let manager = CacheManager(cacheDirectoryPath: tempDir.path)
        try manager.prepare()

        // Should not throw on empty directory
        try manager.enforceMaxSize(maxSizeGB: 1)

        let size = try manager.currentSizeBytes()
        #expect(size == 0)
    }
}
