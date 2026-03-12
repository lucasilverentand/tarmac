import Foundation

@MainActor
protocol VMLifecycleProtocol: AnyObject, Sendable {
    func bootVM(
        vmConfig: VMConfiguration,
        diskPath: URL,
        platformStore: PlatformDataStore,
        sharedDirectoryURL: URL?,
        cacheDirectoryURL: URL?
    ) async throws

    func stopVM() async throws

    var isBooted: Bool { get }
}
