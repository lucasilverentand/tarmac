import Foundation
import Testing

@testable import Tarmac

@Suite("StorageManager")
struct StorageManagerTests {
    @Test("resolves managed paths under root")
    func resolvesManagedPaths() throws {
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        let storage = StorageManager(rootDirectory: root)

        #expect(storage.baseImageURL.path == root.appendingPathComponent("BaseImage.img").path)
        #expect(storage.restoreIPSWURL.path == root.appendingPathComponent("restore.ipsw").path)
        #expect(storage.platformDirectory.path == root.appendingPathComponent("Platform").path)
        #expect(storage.runnerDirectory.path == root.appendingPathComponent("runner").path)
        #expect(storage.jobsDirectory.path == root.appendingPathComponent("jobs").path)
        #expect(storage.disksDirectory.path == root.appendingPathComponent("disks").path)
        #expect(storage.diagnosticsDirectory.path == root.appendingPathComponent("diagnostics").path)
        #expect(storage.actionsCacheDirectory.path == root.appendingPathComponent("actions-cache").path)
        #expect(storage.tmpDirectory.path == root.appendingPathComponent("tmp").path)
    }

    @Test("prepareBaseDirectories creates expected folders")
    func prepareCreatesFolders() throws {
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        let storage = StorageManager(rootDirectory: root)
        try storage.prepareBaseDirectories()

        #expect(FileManager.default.fileExists(atPath: storage.platformDirectory.path))
        #expect(FileManager.default.fileExists(atPath: storage.jobsDirectory.path))
        #expect(FileManager.default.fileExists(atPath: storage.disksDirectory.path))
        #expect(FileManager.default.fileExists(atPath: storage.diagnosticsDirectory.path))
        #expect(FileManager.default.fileExists(atPath: storage.actionsCacheDirectory.path))
        #expect(FileManager.default.fileExists(atPath: storage.tmpDirectory.path))
    }

    @Test("evaluateHealth reports volume and clone behavior for reachable storage")
    func evaluateHealthReportsVolumeAndCloneBehavior() throws {
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        let storage = StorageManager(rootDirectory: root)
        try storage.prepareBaseDirectories()

        let health = storage.evaluateHealth(minimumFreeBytes: nil)

        #expect(health.isReachable)
        #expect(health.volume != nil)
        #expect(!health.cloneBehavior.displayName.isEmpty)
    }

    @Test("evaluateHealth blocks unreachable storage root")
    func evaluateHealthBlocksUnreachableRoot() throws {
        let root = try TestFactories.makeTempDir()
        let missing = root.appendingPathComponent("missing")
        defer { TestFactories.cleanup(root) }

        let health = StorageManager(rootDirectory: missing).evaluateHealth(minimumFreeBytes: nil)

        #expect(health.status == .blocked)
        #expect(health.blockingIssues.contains { $0.message.contains("not reachable") })
    }

    @Test("migrateManagedData moves old root artifacts into new root")
    func migrateMovesOldRootArtifacts() throws {
        let oldRoot = try TestFactories.makeTempDir()
        let newRoot = try TestFactories.makeTempDir()
        let explicitBase = try TestFactories.makeTempDir().appendingPathComponent("old-base.img")
        defer {
            TestFactories.cleanup(oldRoot)
            TestFactories.cleanup(newRoot)
            TestFactories.cleanup(explicitBase.deletingLastPathComponent())
        }

        let oldStorage = StorageManager(rootDirectory: oldRoot)
        try FileManager.default.createDirectory(at: oldStorage.runnerDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oldStorage.actionsCacheDirectory, withIntermediateDirectories: true)
        try "runner".write(
            to: oldStorage.runnerDirectory.appendingPathComponent("run.sh"),
            atomically: true,
            encoding: .utf8
        )
        try "cache".write(
            to: oldStorage.actionsCacheDirectory.appendingPathComponent("entry"),
            atomically: true,
            encoding: .utf8
        )
        try Data([0x01]).write(to: explicitBase)

        let newStorage = StorageManager(rootDirectory: newRoot)
        let result = try newStorage.migrateManagedData(from: oldRoot, explicitBaseImageURL: explicitBase)

        #expect(result.movedItems >= 3)
        #expect(
            FileManager.default.fileExists(atPath: newStorage.runnerDirectory.appendingPathComponent("run.sh").path)
        )
        #expect(
            FileManager.default.fileExists(
                atPath: newStorage.actionsCacheDirectory.appendingPathComponent("entry").path
            )
        )
        #expect(FileManager.default.fileExists(atPath: newStorage.baseImageURL.path))
        #expect(!FileManager.default.fileExists(atPath: explicitBase.path))
    }

    @Test("base image verification marker lifecycle")
    func baseImageVerifiedMarkerLifecycle() throws {
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        let storage = StorageManager(rootDirectory: root)
        #expect(!storage.isBaseImageVerified())

        try storage.markBaseImageVerified()
        #expect(storage.isBaseImageVerified())
        #expect(FileManager.default.fileExists(atPath: storage.baseImageVerifiedMarkerURL.path))

        try storage.clearBaseImageVerified()
        #expect(!storage.isBaseImageVerified())
        #expect(!FileManager.default.fileExists(atPath: storage.baseImageVerifiedMarkerURL.path))
    }

    @Test("cleanupTransientFiles removes stale transient data")
    func cleanupTransientFiles() throws {
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        let storage = StorageManager(rootDirectory: root)
        try storage.prepareBaseDirectories()

        let staleDisk = storage.disksDirectory.appendingPathComponent("stale.img")
        let freshDisk = storage.disksDirectory.appendingPathComponent("fresh.img")
        try Data([0x01]).write(to: staleDisk)
        try Data([0x02]).write(to: freshDisk)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-48 * 60 * 60)],
            ofItemAtPath: staleDisk.path
        )

        try storage.cleanupTransientFiles()

        #expect(!FileManager.default.fileExists(atPath: staleDisk.path))
        #expect(FileManager.default.fileExists(atPath: freshDisk.path))
    }

    @Test("cleanupInstallerArtifactsAfterVerification removes restore image by default")
    func cleanupInstallerArtifactsAfterVerificationRemovesRestoreImageByDefault() throws {
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        let storage = StorageManager(rootDirectory: root)
        try storage.prepareBaseDirectories()
        try Data([0x01]).write(to: storage.baseImageURL)
        try Data([0x02]).write(to: storage.restoreIPSWURL)
        try Data([0x03]).write(to: storage.ipswResumeDataURL)
        try Data([0x04]).write(to: storage.partialIPSWURL)
        let tempIPSW = storage.tmpDirectory.appendingPathComponent("ipsw-\(UUID().uuidString).ipsw")
        try Data([0x05]).write(to: tempIPSW)

        let result = try storage.cleanupInstallerArtifactsAfterVerification(keepRestoreImage: false)

        #expect(result.removedItems == 4)
        #expect(!FileManager.default.fileExists(atPath: storage.restoreIPSWURL.path))
        #expect(!FileManager.default.fileExists(atPath: storage.ipswResumeDataURL.path))
        #expect(!FileManager.default.fileExists(atPath: storage.partialIPSWURL.path))
        #expect(!FileManager.default.fileExists(atPath: tempIPSW.path))
        #expect(FileManager.default.fileExists(atPath: storage.baseImageURL.path))
    }

    @Test("cleanupInstallerArtifactsAfterVerification can retain restore image")
    func cleanupInstallerArtifactsAfterVerificationCanRetainRestoreImage() throws {
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        let storage = StorageManager(rootDirectory: root)
        try storage.prepareBaseDirectories()
        try Data([0x01]).write(to: storage.baseImageURL)
        try Data([0x02]).write(to: storage.restoreIPSWURL)
        try Data([0x03]).write(to: storage.ipswResumeDataURL)
        try Data([0x04]).write(to: storage.partialIPSWURL)

        let result = try storage.cleanupInstallerArtifactsAfterVerification(keepRestoreImage: true)
        let health = storage.evaluateHealth(minimumFreeBytes: nil)

        #expect(result.removedItems == 2)
        #expect(FileManager.default.fileExists(atPath: storage.restoreIPSWURL.path))
        #expect(FileManager.default.fileExists(atPath: storage.baseImageURL.path))
        #expect(!FileManager.default.fileExists(atPath: storage.ipswResumeDataURL.path))
        #expect(!FileManager.default.fileExists(atPath: storage.partialIPSWURL.path))
        #expect(health.installerArtifactSizeBytes > 0)
    }
}
