import Foundation
import Testing

@testable import Tarmac

@Suite("PlatformDataStore")
struct PlatformDataStoreTests {
    @Test("Save and load hardwareModel round-trip")
    func hardwareModelRoundTrip() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let store = PlatformDataStore(directory: tempDir)
        let data = Data([0x01, 0x02, 0x03, 0x04])

        try store.saveHardwareModel(data)
        let loaded = store.loadHardwareModel()
        #expect(loaded == data)
    }

    @Test("Save and load machineIdentifier round-trip")
    func machineIdentifierRoundTrip() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let store = PlatformDataStore(directory: tempDir)
        let data = Data([0xAA, 0xBB, 0xCC])

        try store.saveMachineIdentifier(data)
        let loaded = store.loadMachineIdentifier()
        #expect(loaded == data)
    }

    @Test("loadHardwareModel returns nil when file doesn't exist")
    func hardwareModelNilWhenMissing() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let store = PlatformDataStore(directory: tempDir)
        #expect(store.loadHardwareModel() == nil)
    }

    @Test("loadMachineIdentifier returns nil when file doesn't exist")
    func machineIdentifierNilWhenMissing() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let store = PlatformDataStore(directory: tempDir)
        #expect(store.loadMachineIdentifier() == nil)
    }

    @Test("hasExistingPlatform true when all files present")
    func hasExistingPlatformTrue() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let store = PlatformDataStore(directory: tempDir)
        try store.saveHardwareModel(Data([0x01]))
        try store.saveMachineIdentifier(Data([0x02]))
        try Data([0x03]).write(to: store.auxiliaryStoragePath)

        #expect(store.hasExistingPlatform)
    }

    @Test("hasExistingPlatform false when only one file present")
    func hasExistingPlatformPartial() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let store = PlatformDataStore(directory: tempDir)
        try store.saveHardwareModel(Data([0x01]))

        #expect(!store.hasExistingPlatform)
    }

    @Test("storage initializer uses platform directory under root")
    func storageInitializerUsesPlatformDirectory() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let storage = StorageManager(rootDirectory: tempDir)
        let store = PlatformDataStore(storage: storage)
        try store.saveHardwareModel(Data([0x01]))

        #expect(
            FileManager.default.fileExists(
                atPath: storage.platformDirectory.appendingPathComponent("hardwareModel.bin").path
            )
        )
    }

    @Test("Auxiliary storage can be overridden for an ephemeral VM clone")
    func auxiliaryStorageCanBeOverridden() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let baseStore = PlatformDataStore(directory: tempDir)
        let cloneURL = tempDir.appendingPathComponent("runner.auxiliaryStorage")
        let cloneStore = baseStore.usingAuxiliaryStorage(at: cloneURL)

        #expect(baseStore.auxiliaryStoragePath != cloneStore.auxiliaryStoragePath)
        #expect(cloneStore.auxiliaryStoragePath == cloneURL)
        #expect(cloneStore.hardwareModelPath == baseStore.hardwareModelPath)
        #expect(cloneStore.machineIdentifierPath == baseStore.machineIdentifierPath)
    }
}
