import Foundation
import Testing
import Virtualization

@testable import Tarmac

@Suite("macOS guest provisioning")
struct MacGuestProvisioningTests {
    @Test("Provisioning configuration creates validated automatic-login start options")
    func configurationCreatesStartOptions() throws {
        let configuration = MacGuestProvisioningConfiguration(password: "T27-test-password-123")

        let options = try configuration.makeStartOptions()

        #expect(options.guestProvisioningOptions?.fullName == "Tarmac Runner")
        #expect(options.guestProvisioningOptions?.username == "tarmac")
        #expect(options.guestProvisioningOptions?.logsInAutomatically == true)
        #expect(options.guestProvisioningOptions?.enablesRemoteLogin == true)
    }

    @Test("Provisioning password is generated once and persisted in Keychain")
    func credentialStorePersistsPassword() throws {
        let keychain = PreviewKeychainService()
        let store = MacGuestCredentialStore(keychainService: keychain)

        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()

        #expect(first.password == second.password)
        #expect(first.password.hasPrefix("T27-"))
        #expect(first.password.count >= 30)
    }

    @Test("DHCP parser resolves a lease with non-padded MAC components")
    func dhcpLeaseParserResolvesAddress() {
        let leases = """
            {
                name=AppleViMachine1
                ip_address=192.168.64.42
                hw_address=1,a:2b:c:4d:e:6f
                identifier=1,a:2b:c:4d:e:6f
            }
            """

        #expect(
            DHCPLeaseParser.ipv4Address(in: leases, macAddress: "0a:2b:0c:4d:0e:6f")
                == "192.168.64.42"
        )
    }

    @Test("Restore catalog prefers a supported stable macOS 27 image")
    func catalogPrefersSupportedStableImage() {
        let stableURL = URL(string: "https://example.apple/stable.ipsw")!
        let selected = MacOSRestoreCatalog.preferredRestoreURL(
            latestSupportedURL: stableURL,
            latestSupportedVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        )

        #expect(selected == stableURL)
    }

    @Test("Restore catalog uses the Apple macOS 27 beta while stable is macOS 26")
    func catalogUsesBetaForOlderStableImage() {
        let stableURL = URL(string: "https://example.apple/stable.ipsw")!
        let selected = MacOSRestoreCatalog.preferredRestoreURL(
            latestSupportedURL: stableURL,
            latestSupportedVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 2)
        )

        #expect(selected == MacOSRestoreCatalog.betaRestoreURL)
        #expect(selected.host == "updates.cdn-apple.com")
    }
}
