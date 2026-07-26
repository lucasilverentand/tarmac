import Foundation

struct PlatformDataStore: Sendable {
    private let directory: URL
    private let auxiliaryStorageOverride: URL?

    init(directory: URL? = nil, auxiliaryStorageURL: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = StorageManager.defaultRootDirectory.appendingPathComponent("Platform")
        }
        self.auxiliaryStorageOverride = auxiliaryStorageURL
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    init(storage: StorageManager) {
        self.directory = storage.platformDirectory
        self.auxiliaryStorageOverride = nil
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    var hardwareModelPath: URL { directory.appendingPathComponent("hardwareModel.bin") }
    var machineIdentifierPath: URL { directory.appendingPathComponent("machineIdentifier.bin") }
    var auxiliaryStoragePath: URL {
        auxiliaryStorageOverride ?? directory.appendingPathComponent("auxiliaryStorage.bin")
    }

    func usingAuxiliaryStorage(at url: URL) -> PlatformDataStore {
        PlatformDataStore(directory: directory, auxiliaryStorageURL: url)
    }

    func saveHardwareModel(_ data: Data) throws {
        try data.write(to: hardwareModelPath)
    }

    func loadHardwareModel() -> Data? {
        try? Data(contentsOf: hardwareModelPath)
    }

    func saveMachineIdentifier(_ data: Data) throws {
        try data.write(to: machineIdentifierPath)
    }

    func loadMachineIdentifier() -> Data? {
        try? Data(contentsOf: machineIdentifierPath)
    }

    var hasExistingPlatform: Bool {
        FileManager.default.fileExists(atPath: hardwareModelPath.path)
            && FileManager.default.fileExists(atPath: machineIdentifierPath.path)
            && FileManager.default.fileExists(atPath: auxiliaryStoragePath.path)
    }
}
