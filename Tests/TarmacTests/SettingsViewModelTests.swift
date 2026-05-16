import Foundation
import Testing

@testable import Tarmac

@Suite("SettingsViewModel")
@MainActor
struct SettingsViewModelTests {
    private static let supportedHost = HostCapability(
        isVirtualizationSupported: true,
        operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
    )

    private func makeVM() -> (SettingsViewModel, ConfigStore, PreviewKeychainService) {
        let suiteName = "test-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = PreviewKeychainService()
        let store = ConfigStore(defaults: defaults, keychainService: keychain)
        let vm = SettingsViewModel(configStore: store)
        return (vm, store, keychain)
    }

    @Test("Organizations passthrough from ConfigStore")
    func organizationsPassthrough() {
        let (vm, _, _) = makeVM()
        let org = TestFactories.makeOrg(name: "passthrough-org")

        vm.addOrganization(org)
        #expect(vm.organizations.count == 1)
        #expect(vm.organizations.first?.name == "passthrough-org")
    }

    @Test("Remove organization")
    func removeOrganization() {
        let (vm, _, _) = makeVM()
        let org = TestFactories.makeOrg(name: "to-remove")

        vm.addOrganization(org)
        vm.removeOrganization(org)
        #expect(vm.organizations.isEmpty)
    }

    @Test("Update organization")
    func updateOrganization() {
        let (vm, _, _) = makeVM()
        var org = TestFactories.makeOrg(name: "original")
        vm.addOrganization(org)

        org.name = "updated"
        vm.updateOrganization(org)
        #expect(vm.organizations.first?.name == "updated")
    }

    @Test("Per-org hasPrivateKey reflects keychain state")
    func hasPrivateKeyReflectsKeychain() {
        let (vm, _, keychain) = makeVM()
        let org = TestFactories.makeOrg()

        #expect(!vm.hasPrivateKey(for: org))

        _ = keychain.save(key: org.privateKeyKeychainKey, data: Data([0x01]))
        #expect(vm.hasPrivateKey(for: org))
    }

    @Test("deletePrivateKey removes from keychain for org")
    func deletePrivateKeyRemoves() {
        let (vm, _, keychain) = makeVM()
        let org = TestFactories.makeOrg()

        _ = keychain.save(key: org.privateKeyKeychainKey, data: Data([0x01]))
        #expect(vm.hasPrivateKey(for: org))

        vm.deletePrivateKey(for: org)
        #expect(!vm.hasPrivateKey(for: org))
    }

    @Test("validateConfiguration returns empty when fully configured")
    func validateFullyConfigured() throws {
        let (vm, _, keychain) = makeVM()
        let storage = try TestFactories.makeTempDir()
        try vm.configureStorage(at: storage)
        try TestFactories.prepareReadyRunnerHostStorage(for: vm.configStore)

        let org = TestFactories.makeOrg()
        vm.addOrganization(org)
        _ = keychain.save(key: org.privateKeyKeychainKey, data: Data([0x01]))

        let issues = vm.validateConfiguration(hostCapability: Self.supportedHost)
        #expect(issues.isEmpty)
        TestFactories.cleanup(storage)
    }

    @Test("validateConfiguration returns issues when nothing configured")
    func validateNothingConfigured() {
        let (vm, _, _) = makeVM()

        let issues = vm.validateConfiguration(hostCapability: Self.supportedHost)
        #expect(issues.contains { $0.contains("GitHub organization") })
        #expect(issues.contains { $0.contains("storage location") })
        #expect(issues.contains { $0.contains("base image") })
    }

    @Test("validateConfiguration detects missing credentials per org")
    func validateMissingCredentials() {
        let (vm, _, _) = makeVM()

        let org = TestFactories.makeOrg(name: "my-org", appId: "")
        vm.addOrganization(org)

        let issues = vm.validateConfiguration(hostCapability: Self.supportedHost)
        #expect(issues.contains { $0.contains("my-org") && $0.contains("App ID") })
        #expect(issues.contains { $0.contains("my-org") && $0.contains("Private key") })
    }

    @Test("validateConfiguration detects missing scale set ID")
    func validateMissingScaleSet() {
        let (vm, _, keychain) = makeVM()

        let org = TestFactories.makeOrg(name: "my-org", scaleSetId: nil)
        vm.addOrganization(org)
        _ = keychain.save(key: org.privateKeyKeychainKey, data: Data([0x01]))

        let issues = vm.validateConfiguration(hostCapability: Self.supportedHost)
        #expect(issues.contains { $0.contains("my-org") && $0.contains("Scale set ID") })
    }

    @Test("validateConfiguration detects all orgs disabled")
    func validateAllOrgsDisabled() {
        let (vm, _, _) = makeVM()

        let org = TestFactories.makeOrg(isEnabled: false)
        vm.addOrganization(org)

        let issues = vm.validateConfiguration(hostCapability: Self.supportedHost)
        #expect(issues.contains { $0.contains("Enable at least one") })
    }

    @Test("validateConfiguration surfaces blocked storage health")
    func validateBlockedStorageHealth() throws {
        let (vm, store, keychain) = makeVM()
        let root = try TestFactories.makeTempDir()
        let missing = root.appendingPathComponent("missing")
        defer { TestFactories.cleanup(root) }

        store.storageRootPath = missing.path
        store.hasCompletedStorageSetup = true

        let org = TestFactories.makeOrg()
        vm.addOrganization(org)
        _ = keychain.save(key: org.privateKeyKeychainKey, data: Data([0x01]))

        let issues = vm.validateConfiguration(hostCapability: Self.supportedHost)

        #expect(issues.contains { $0.contains("Storage") && $0.contains("not reachable") })
    }

    @Test("validateConfiguration surfaces unsupported host issues")
    func validateUnsupportedHostSurfacesIssues() {
        let (vm, _, keychain) = makeVM()
        let org = TestFactories.makeOrg()
        vm.addOrganization(org)
        _ = keychain.save(key: org.privateKeyKeychainKey, data: Data([0x01]))

        let unsupported = HostCapability(
            isVirtualizationSupported: false,
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 5, patchVersion: 0)
        )
        let issues = vm.validateConfiguration(hostCapability: unsupported)
        #expect(issues.contains { $0.contains("Virtualization") })
        #expect(issues.contains { $0.contains("macOS 26") })
    }

    @Test("vmConfiguration setter persists")
    func vmConfigPersists() {
        let (vm, store, _) = makeVM()

        vm.vmConfiguration = VMConfiguration(cpuCount: 12, memorySizeGB: 32, diskSizeGB: 200)
        #expect(store.vmConfiguration.cpuCount == 12)
        #expect(store.vmConfiguration.memorySizeGB == 32)
    }

    @Test("storageRootPath setter migrates managed artifacts")
    func storageRootMigratesArtifacts() throws {
        let (vm, store, _) = makeVM()
        let oldRoot = try TestFactories.makeTempDir()
        let newRoot = try TestFactories.makeTempDir()
        defer {
            TestFactories.cleanup(oldRoot)
            TestFactories.cleanup(newRoot)
        }

        store.storageRootPath = oldRoot.path
        let oldStorage = StorageManager(rootDirectory: oldRoot)
        try FileManager.default.createDirectory(at: oldStorage.runnerDirectory, withIntermediateDirectories: true)
        try "runner".write(
            to: oldStorage.runnerDirectory.appendingPathComponent("run.sh"),
            atomically: true,
            encoding: .utf8
        )

        vm.storageRootPath = newRoot.path

        let newStorage = StorageManager(rootDirectory: newRoot)
        #expect(store.storageRootPath == newStorage.rootDirectory.path)
        #expect(store.baseImagePath == newStorage.baseImageURL.path)
        #expect(
            FileManager.default.fileExists(atPath: newStorage.runnerDirectory.appendingPathComponent("run.sh").path)
        )
    }

    @Test("storageReport reflects configured storage root")
    func storageReportReflectsConfiguredRoot() throws {
        let (vm, store, _) = makeVM()
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        let storage = StorageManager(rootDirectory: root)
        try storage.prepareBaseDirectories()
        try Data(repeating: 0x01, count: 256).write(to: storage.restoreIPSWURL)
        store.storageRootPath = root.path

        let report = vm.storageReport

        #expect(report.rootPath == root.path)
        #expect(report.installerArtifactBytes > 0)
        #expect(vm.storageUsageDescription.contains("used"))
    }

    @Test("cleanupInstallerArtifacts uses configured storage root")
    func cleanupInstallerArtifactsUsesConfiguredRoot() throws {
        let (vm, store, _) = makeVM()
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        let storage = StorageManager(rootDirectory: root)
        try storage.prepareBaseDirectories()
        try Data([0x01]).write(to: storage.restoreIPSWURL)
        store.storageRootPath = root.path

        vm.cleanupInstallerArtifacts()

        #expect(!FileManager.default.fileExists(atPath: storage.restoreIPSWURL.path))
    }

    @Test("cache size description reflects cache contents and clear resets targets")
    func cacheSizeDescriptionAndClear() throws {
        let (vm, _, _) = makeVM()
        let root = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(root) }

        try vm.configureStorage(at: root)
        let manager = CacheManager(storage: StorageManager(rootDirectory: root))
        try manager.prepare()
        try Data(repeating: 0xAB, count: 4096)
            .write(to: manager.baseDirectory.appendingPathComponent("artifact.bin"))

        #expect(vm.cacheSizeDescription != "Zero KB")

        vm.clearCache()

        #expect(vm.cacheSizeDescription == "Zero KB")
        for target in CacheConfiguration.guestCacheTargets {
            #expect(
                FileManager.default.fileExists(
                    atPath: manager.baseDirectory.appendingPathComponent(target.directoryName).path
                )
            )
        }
    }
}
