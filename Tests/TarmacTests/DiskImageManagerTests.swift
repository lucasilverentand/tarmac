import Foundation
import Testing

@testable import Tarmac

@Suite("DiskImageManager")
struct DiskImageManagerTests {
    @Test("createSparseDisk creates file at path")
    func createSparseDisk() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let manager = DiskImageManager()
        let diskPath = tempDir.appendingPathComponent("disk.img")

        try manager.createSparseDisk(at: diskPath, sizeGB: 1)

        #expect(FileManager.default.fileExists(atPath: diskPath.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: diskPath.path)
        let size = attrs[.size] as! UInt64
        // Sparse disk: logical size should be 1GB but physical allocation is minimal
        #expect(size == 1 * 1024 * 1024 * 1024)
    }

    @Test("createSparseDisk creates parent directories")
    func createSparseDiskCreatesParentDirs() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let manager = DiskImageManager()
        let diskPath =
            tempDir
            .appendingPathComponent("nested/deep/disk.img")

        try manager.createSparseDisk(at: diskPath, sizeGB: 1)

        #expect(FileManager.default.fileExists(atPath: diskPath.path))
    }

    @Test("cloneDisk produces identical copy")
    func cloneDiskProducesCopy() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let manager = DiskImageManager()
        let source = tempDir.appendingPathComponent("source.img")
        let dest = tempDir.appendingPathComponent("clones/clone.img")

        // Create a small file as source
        let content = Data(repeating: 0x42, count: 4096)
        try content.write(to: source)

        try manager.cloneDisk(from: source, to: dest)

        #expect(FileManager.default.fileExists(atPath: dest.path))
        let clonedContent = try Data(contentsOf: dest)
        #expect(clonedContent == content)
    }

    @Test("deleteDisk removes file")
    func deleteDiskRemovesFile() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let manager = DiskImageManager()
        let diskPath = tempDir.appendingPathComponent("to-delete.img")
        try Data([0x01]).write(to: diskPath)

        try manager.deleteDisk(at: diskPath)

        #expect(!FileManager.default.fileExists(atPath: diskPath.path))
    }

    @Test("deleteDisk is idempotent on missing file")
    func deleteDiskIdempotent() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let manager = DiskImageManager()
        let diskPath = tempDir.appendingPathComponent("nonexistent.img")

        // Should not throw
        try manager.deleteDisk(at: diskPath)
    }
}
