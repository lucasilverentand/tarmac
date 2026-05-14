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

    @Test("verification success marks base image ready")
    func verificationSuccessMarksReady() async throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let storage = StorageManager(rootDirectory: tempDir)
        try storage.prepareBaseDirectories()
        try Data([0x01]).write(to: storage.baseImageURL)

        let manager = ImageManager(storage: storage)
        let verifier = MockBaseImageBootVerifier()

        try await manager.verifyBaseImageBoot(
            diskPath: storage.baseImageURL,
            config: VMConfiguration(),
            platformStore: PlatformDataStore(storage: storage),
            verifier: verifier
        )

        #expect(verifier.verifyCallCount == 1)
        #expect(manager.setupState == .ready)
        #expect(manager.verificationProgress == 1)
        #expect(storage.isBaseImageReady(at: storage.baseImageURL))
    }

    @Test("verification failure stays retryable and does not mark ready")
    func verificationFailureDoesNotMarkReady() async throws {
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let storage = StorageManager(rootDirectory: tempDir)
        try storage.prepareBaseDirectories()
        try Data([0x01]).write(to: storage.baseImageURL)

        let manager = ImageManager(storage: storage)
        let verifier = MockBaseImageBootVerifier()
        verifier.error = TestVerificationError.bootFailed

        await #expect(throws: ImageManagerError.self) {
            try await manager.verifyBaseImageBoot(
                diskPath: storage.baseImageURL,
                config: VMConfiguration(),
                platformStore: PlatformDataStore(storage: storage),
                verifier: verifier
            )
        }

        #expect(verifier.verifyCallCount == 1)
        #expect(manager.setupState == .verificationFailed)
        #expect(FileManager.default.fileExists(atPath: storage.baseImageURL.path))
        #expect(!storage.isBaseImageReady(at: storage.baseImageURL))
    }
}

@MainActor
private final class MockBaseImageBootVerifier: BaseImageBootVerifying {
    private(set) var verifyCallCount = 0
    var error: Error?

    func verifyBaseImageBoot(
        config: VMConfiguration,
        diskPath: URL,
        platformStore: PlatformDataStore,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        verifyCallCount += 1
        progress(0.5)
        if let error {
            throw error
        }
        progress(1.0)
    }
}

private enum TestVerificationError: Error {
    case bootFailed
}
