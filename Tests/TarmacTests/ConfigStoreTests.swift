import Foundation
import Testing

@testable import Tarmac

@Suite("ConfigStore")
@MainActor
struct ConfigStoreTests {
    private func makeStore() -> (ConfigStore, UserDefaults) {
        let suiteName = "test-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = PreviewKeychainService()
        let store = ConfigStore(defaults: defaults, keychainService: keychain)
        return (store, defaults)
    }

    @Test("Save and load organizations round-trip")
    func organizationsRoundTrip() {
        let suiteName = "test-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = PreviewKeychainService()

        let store1 = ConfigStore(defaults: defaults, keychainService: keychain)
        let org = Organization(name: "test-org", appId: "APP1", installationId: 12345, labels: ["self-hosted"])
        store1.addOrganization(org)
        #expect(store1.organizations.count == 1)

        // Load in a new store instance
        let store2 = ConfigStore(defaults: defaults, keychainService: keychain)
        #expect(store2.organizations.count == 1)
        #expect(store2.organizations.first?.name == "test-org")
        #expect(store2.organizations.first?.installationId == 12345)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Save and load VM config round-trip")
    func vmConfigRoundTrip() {
        let suiteName = "test-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = PreviewKeychainService()

        let store1 = ConfigStore(defaults: defaults, keychainService: keychain)
        store1.vmConfiguration = VMConfiguration(cpuCount: 8, memorySizeGB: 16, diskSizeGB: 120)
        store1.save()

        let store2 = ConfigStore(defaults: defaults, keychainService: keychain)
        #expect(store2.vmConfiguration.cpuCount == 8)
        #expect(store2.vmConfiguration.memorySizeGB == 16)
        #expect(store2.vmConfiguration.diskSizeGB == 120)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Default values are set")
    func defaultValues() {
        let (store, defaults) = makeStore()

        #expect(store.organizations.isEmpty)
        #expect(store.vmConfiguration.cpuCount == 4)
        #expect(store.vmConfiguration.memorySizeGB == 8)
        #expect(store.vmConfiguration.diskSizeGB == 80)
        #expect(store.diagnosticsRetentionConfig.maxBundleCount == 100)
        #expect(store.diagnosticsRetentionConfig.maxAgeDays == 14)
        #expect(!store.storageDirectoryPath.isEmpty)
        #expect(store.storageRootPath == store.storageDirectoryPath)
        #expect(store.cacheDirectoryPath == StorageManager(rootPath: store.storageRootPath).actionsCacheDirectory.path)
        #expect(!store.hasCompletedStorageSetup)

        defaults.removePersistentDomain(forName: "test-config")
    }

    @Test("Save and load diagnostics retention round-trip")
    func diagnosticsRetentionRoundTrip() {
        let suiteName = "test-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = PreviewKeychainService()

        let store1 = ConfigStore(defaults: defaults, keychainService: keychain)
        store1.diagnosticsRetentionConfig = DiagnosticsRetentionConfiguration(
            maxBundleCount: 20,
            maxAgeDays: 7,
            maxSizeMB: 128,
            keepSuccessfulJobLogs: true
        )
        store1.save()

        let store2 = ConfigStore(defaults: defaults, keychainService: keychain)
        #expect(store2.diagnosticsRetentionConfig.maxBundleCount == 20)
        #expect(store2.diagnosticsRetentionConfig.maxAgeDays == 7)
        #expect(store2.diagnosticsRetentionConfig.maxSizeMB == 128)
        #expect(store2.diagnosticsRetentionConfig.keepSuccessfulJobLogs)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("storageRootPath loads legacy cacheDirectoryPath")
    func storageRootLoadsLegacyCacheDirectoryPath() {
        let suiteName = "test-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = PreviewKeychainService()
        let legacyPath = "/tmp/tarmac-legacy-\(UUID().uuidString)"
        defaults.set(legacyPath, forKey: "cacheDirectoryPath")

        let store = ConfigStore(defaults: defaults, keychainService: keychain)

        #expect(store.storageRootPath == legacyPath)
        #expect(store.cacheDirectoryPath == StorageManager(rootPath: legacyPath).actionsCacheDirectory.path)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("save persists storage root to new and legacy keys")
    func storageRootPersists() {
        let suiteName = "test-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = PreviewKeychainService()
        let path = "/tmp/tarmac-storage-\(UUID().uuidString)"

        let store = ConfigStore(defaults: defaults, keychainService: keychain)
        store.storageRootPath = path
        store.save()

        #expect(defaults.string(forKey: "storageRootPath") == path)
        #expect(
            defaults.string(forKey: "cacheDirectoryPath") == StorageManager(rootPath: path).actionsCacheDirectory.path
        )

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Configure storage derives managed paths")
    func configureStorage() throws {
        let (store, _) = makeStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tarmac-storage-\(UUID().uuidString)")

        try store.configureStorage(at: directory)

        #expect(store.hasCompletedStorageSetup)
        #expect(store.storageDirectoryPath == directory.standardizedFileURL.path)
        #expect(store.cacheDirectoryPath == StorageManager(rootDirectory: directory).actionsCacheDirectory.path)
        #expect(store.resolvedBaseImagePath == directory.appendingPathComponent("BaseImage.img").path)
        #expect(store.platformDirectoryPath == directory.appendingPathComponent("Platform").path)

        try? FileManager.default.removeItem(at: directory)
    }

    @Test("Remove organization")
    func removeOrganization() {
        let (store, _) = makeStore()
        let org = Organization(name: "to-remove", appId: "1", installationId: 1, labels: [])
        store.addOrganization(org)
        #expect(store.organizations.count == 1)

        store.removeOrganization(org)
        #expect(store.organizations.isEmpty)
    }

    @Test("Update organization")
    func updateOrganization() {
        let (store, _) = makeStore()
        var org = Organization(name: "original", appId: "1", installationId: 1, labels: [])
        store.addOrganization(org)

        org.name = "updated"
        store.updateOrganization(org)
        #expect(store.organizations.first?.name == "updated")
    }
}
