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
        #expect(!store.storageDirectoryPath.isEmpty)
        #expect(!store.cacheDirectoryPath.isEmpty)  // default is set
        #expect(!store.hasCompletedStorageSetup)

        defaults.removePersistentDomain(forName: "test-config")
    }

    @Test("Configure storage derives managed paths")
    func configureStorage() throws {
        let (store, _) = makeStore()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tarmac-storage-\(UUID().uuidString)")

        try store.configureStorage(at: directory)

        #expect(store.hasCompletedStorageSetup)
        #expect(store.storageDirectoryPath == directory.standardizedFileURL.path)
        #expect(store.cacheDirectoryPath == directory.appendingPathComponent("Cache").path)
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
