import Foundation
import Testing

@testable import Tarmac

@Suite("ImageManager")
@MainActor
struct ImageManagerTests {
    @Test("canResume reads resume files from injected storage")
    func canResumeUsesInjectedStorage() throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let storage = StorageManager(rootDirectory: tempDir)
        try storage.prepareBaseDirectories()
        try Data([0x01]).write(to: storage.ipswResumeDataURL)
        try Data([0x02]).write(to: storage.partialIPSWURL)

        let manager = ImageManager(storage: storage)

        #expect(manager.canResume)
    }
}
