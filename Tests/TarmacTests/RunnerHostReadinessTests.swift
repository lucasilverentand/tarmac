import Foundation
import Testing

@testable import Tarmac

@Suite("RunnerHostReadiness")
@MainActor
struct RunnerHostReadinessTests {
    private static let supportedHost = HostCapability(
        isVirtualizationSupported: true,
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
    )

    @Test("ready when storage, VM platform data, and GitHub config are complete")
    func readyWhenComplete() throws {
        let (store, _) = TestFactories.makeConfigStore()
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        try store.configureStorage(at: root)
        try TestFactories.prepareReadyRunnerHostStorage(for: store)
        let org = TestFactories.makeOrg()
        store.addOrganization(org)
        _ = store.savePrivateKey(Data([0x01]), for: org)

        let readiness = RunnerHostReadiness.evaluate(
            configStore: store,
            hostCapability: Self.supportedHost
        )

        #expect(readiness.isReady)
        #expect(readiness.statusText == "Ready to accept jobs")
    }

    @Test("missing base image is a VM readiness issue")
    func missingBaseImage() throws {
        let (store, _) = TestFactories.makeConfigStore()
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        try store.configureStorage(at: root)
        let org = TestFactories.makeOrg()
        store.addOrganization(org)
        _ = store.savePrivateKey(Data([0x01]), for: org)

        let readiness = RunnerHostReadiness.evaluate(
            configStore: store,
            hostCapability: Self.supportedHost
        )

        #expect(!readiness.isReady)
        #expect(readiness.issues.contains { $0.category == .vm && $0.message.contains("base image") })
    }

    @Test("partial platform data blocks VM readiness")
    func partialPlatformDataBlocksReadiness() throws {
        let (store, _) = TestFactories.makeConfigStore()
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        try store.configureStorage(at: root)
        let storage = StorageManager(rootDirectory: root)
        try storage.prepareBaseDirectories()
        try Data([0x01]).write(to: storage.baseImageURL)
        try storage.markBaseImageVerified()
        let platformStore = PlatformDataStore(storage: storage)
        try platformStore.saveHardwareModel(Data([0x02]))

        let org = TestFactories.makeOrg()
        store.addOrganization(org)
        _ = store.savePrivateKey(Data([0x01]), for: org)

        let readiness = RunnerHostReadiness.evaluate(
            configStore: store,
            hostCapability: Self.supportedHost
        )

        #expect(readiness.issues.contains { $0.category == .vm && $0.message.contains("platform data") })
    }

    @Test("GitHub credential failures stay distinguishable")
    func githubCredentialIssues() throws {
        let (store, _) = TestFactories.makeConfigStore()
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        try store.configureStorage(at: root)
        try TestFactories.prepareReadyRunnerHostStorage(for: store)
        store.addOrganization(TestFactories.makeOrg(name: "example", appId: "", scaleSetId: nil))

        let readiness = RunnerHostReadiness.evaluate(
            configStore: store,
            hostCapability: Self.supportedHost
        )

        #expect(readiness.issues.contains { $0.category == .github && $0.message.contains("App ID") })
        #expect(readiness.issues.contains { $0.category == .github && $0.message.contains("Scale set") })
        #expect(readiness.issues.contains { $0.category == .github && $0.message.contains("Private key") })
    }
}
