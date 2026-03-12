import Foundation

struct PlatformDataStore: Sendable {
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = appSupport.appendingPathComponent("Tarmac/Platform")
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    var hardwareModelPath: URL { directory.appendingPathComponent("hardwareModel.bin") }
    var machineIdentifierPath: URL { directory.appendingPathComponent("machineIdentifier.bin") }
    var auxiliaryStoragePath: URL { directory.appendingPathComponent("auxiliaryStorage.bin") }

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
    }
}
