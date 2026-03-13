import Foundation
import Testing

@testable import Tarmac

@Suite("SettingsViewModel")
@MainActor
struct SettingsViewModelTests {
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
    func validateFullyConfigured() {
        let (vm, _, keychain) = makeVM()

        let org = TestFactories.makeOrg()
        vm.addOrganization(org)
        _ = keychain.save(key: org.privateKeyKeychainKey, data: Data([0x01]))

        let issues = vm.validateConfiguration()
        #expect(issues.isEmpty)
    }

    @Test("validateConfiguration returns issues when nothing configured")
    func validateNothingConfigured() {
        let (vm, _, _) = makeVM()

        let issues = vm.validateConfiguration()
        #expect(issues.contains { $0.contains("No organizations") })
    }

    @Test("validateConfiguration detects missing credentials per org")
    func validateMissingCredentials() {
        let (vm, _, _) = makeVM()

        let org = TestFactories.makeOrg(name: "my-org", appId: "")
        vm.addOrganization(org)

        let issues = vm.validateConfiguration()
        #expect(issues.contains { $0.contains("my-org") && $0.contains("App ID") })
        #expect(issues.contains { $0.contains("my-org") && $0.contains("Private key") })
    }

    @Test("validateConfiguration detects all orgs disabled")
    func validateAllOrgsDisabled() {
        let (vm, _, _) = makeVM()

        let org = TestFactories.makeOrg(isEnabled: false)
        vm.addOrganization(org)

        let issues = vm.validateConfiguration()
        #expect(issues.contains { $0.contains("disabled") })
    }

    @Test("vmConfiguration setter persists")
    func vmConfigPersists() {
        let (vm, store, _) = makeVM()

        vm.vmConfiguration = VMConfiguration(cpuCount: 12, memorySizeGB: 32, diskSizeGB: 200)
        #expect(store.vmConfiguration.cpuCount == 12)
        #expect(store.vmConfiguration.memorySizeGB == 32)
    }
}
