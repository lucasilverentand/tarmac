import Foundation

@testable import Tarmac

@MainActor
final class MockVMLifecycle: VMLifecycleProtocol {
    private(set) var bootCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var lastBootConfig: VMConfiguration?
    private(set) var lastBootDiskPath: URL?
    private(set) var lastBootSharedDir: URL?
    private(set) var lastBootCacheDir: URL?

    var shouldThrowOnBoot = false
    var shouldThrowOnStop = false
    var completeBootstrapProbeOnBoot = true
    var completeWarmReadinessOnBoot = true
    var bootError: Error = VMEngineError.missingJITConfig
    var stopError: Error = VMEngineError.missingJITConfig

    private(set) var _isBooted = false
    var isBooted: Bool { _isBooted }

    func bootVM(
        vmConfig: VMConfiguration,
        diskPath: URL,
        platformStore: PlatformDataStore,
        sharedDirectoryURL: URL?,
        cacheDirectoryURL: URL?
    ) async throws {
        bootCallCount += 1
        lastBootConfig = vmConfig
        lastBootDiskPath = diskPath
        lastBootSharedDir = sharedDirectoryURL
        lastBootCacheDir = cacheDirectoryURL

        if shouldThrowOnBoot {
            throw bootError
        }

        if completeBootstrapProbeOnBoot,
            let sharedDirectoryURL,
            sharedDirectoryURL.lastPathComponent.hasPrefix("verify-")
        {
            try FileManager.default.createDirectory(at: sharedDirectoryURL, withIntermediateDirectories: true)
            try "0\n".write(
                to: sharedDirectoryURL.appendingPathComponent(GuestBootstrapContract.exitCodeFileName),
                atomically: true,
                encoding: .utf8
            )
            try #"{"exitCode":0}"#.write(
                to: sharedDirectoryURL.appendingPathComponent(GuestBootstrapContract.completionMarkerFileName),
                atomically: true,
                encoding: .utf8
            )
            try "tarmac\n".write(
                to: sharedDirectoryURL.appendingPathComponent(
                    GuestBootstrapContract.interactiveSessionReadyFileName
                ),
                atomically: true,
                encoding: .utf8
            )
        }

        if completeWarmReadinessOnBoot,
            let sharedDirectoryURL,
            FileManager.default.fileExists(
                atPath: sharedDirectoryURL.appendingPathComponent(GuestBootstrapContract.warmModeFileName).path
            )
        {
            try "ready\n".write(
                to: sharedDirectoryURL.appendingPathComponent(GuestBootstrapContract.warmReadyFileName),
                atomically: true,
                encoding: .utf8
            )
        }

        _isBooted = true
    }

    func stopVM() async throws {
        stopCallCount += 1

        if shouldThrowOnStop {
            throw stopError
        }

        _isBooted = false
    }
}
