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

    @Test("Legacy organizations migrate to provider accounts without changing Keychain identity")
    func legacyOrganizationsMigrate() throws {
        let suiteName = "test-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = PreviewKeychainService()
        let id = UUID()
        let legacyJSON = """
            [{
              "id": "\(id.uuidString)",
              "name": "legacy-org",
              "accountType": "organization",
              "credentialMode": "githubApp",
              "appId": "123",
              "installationId": 456,
              "labels": ["self-hosted", "macOS", "ARM64"]
            }]
            """
        defaults.set(Data(legacyJSON.utf8), forKey: "organizations")

        let store = ConfigStore(defaults: defaults, keychainService: keychain)
        let account = try #require(store.organizations.first)

        #expect(account.id == id)
        #expect(account.provider == .github)
        #expect(account.serverURL == "https://github.com")
        #expect(account.scope == .organization)
        #expect(account.privateKeyKeychainKey == "github-app-private-key-\(id.uuidString)")
        #expect(defaults.data(forKey: "runnerAccounts") != nil)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("GitHub and Gitea accounts round-trip in the new account format")
    func providerAccountsRoundTrip() throws {
        let suiteName = "test-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = PreviewKeychainService()
        let store = ConfigStore(defaults: defaults, keychainService: keychain)
        store.addOrganization(Organization(name: "github-org", appId: "1", installationId: 2))
        store.addOrganization(
            Organization(
                provider: .gitea,
                serverURL: "https://git.example.test",
                scope: .repository,
                name: "owner",
                accountType: .repository,
                repositoryName: "repo",
                credentialMode: .accessToken,
                appId: "",
                installationId: 0,
                labels: ["macos-arm64:host"]
            )
        )

        let loaded = ConfigStore(defaults: defaults, keychainService: keychain).organizations
        #expect(loaded.map(\.provider) == [.github, .gitea])
        #expect(loaded.last?.normalizedServerURL?.host == "git.example.test")
        #expect(loaded.last?.giteaRunnerLabels == ["macos-arm64:host"])

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Save and load runner image preparation inventory")
    func runnerImagePreparationInventoryRoundTrip() {
        let suiteName = "test-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = PreviewKeychainService()

        let store1 = ConfigStore(defaults: defaults, keychainService: keychain)
        let profile = RunnerImageProfile(
            name: "Xcode 17",
            baseMacOSVersion: "26.0",
            xcodeVersion: "17.0",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            commandLineToolsInstalled: true,
            sdks: [ApplePlatformSDK(platform: .iOS, version: "19.0")],
            simulatorRuntimes: [AppleSimulatorRuntime(platform: .iOS, version: "19.0")],
            capabilities: [.iOS],
            preparation: BaseImagePreparation(
                baseImageIdentifier: "base-image-2026-05-16",
                steps: [
                    BaseImagePreparationStep(id: .installXcode, status: .completed),
                    BaseImagePreparationStep(id: .acceptXcodeLicense, status: .completed),
                    BaseImagePreparationStep(id: .installSimulatorRuntimes, status: .blocked),
                ],
                inventory: ToolchainInventory(
                    commandLineToolsVersion: "17.0",
                    xcodeLicenseAccepted: true,
                    nodeVersion: "24.0",
                    packageManagers: [PackageManagerInventory(manager: .bun, version: "1.2")],
                    rubyVersion: "3.3"
                )
            )
        )
        store1.addOrganization(
            Organization(name: "test-org", appId: "APP1", installationId: 12345, imageProfile: profile)
        )

        let store2 = ConfigStore(defaults: defaults, keychainService: keychain)
        let loadedPreparation = store2.organizations.first?.imageProfile?.preparation

        #expect(loadedPreparation?.baseImageIdentifier == "base-image-2026-05-16")
        #expect(loadedPreparation?.completedStepCount == 2)
        #expect(loadedPreparation?.inventory.xcodeLicenseAccepted == true)
        #expect(
            loadedPreparation?.inventory.packageManagers == [PackageManagerInventory(manager: .bun, version: "1.2")]
        )
        #expect(loadedPreparation?.inventory.rubyVersion == "3.3")

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Save and load VM config round-trip")
    func vmConfigRoundTrip() {
        let suiteName = "test-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = PreviewKeychainService()

        let store1 = ConfigStore(defaults: defaults, keychainService: keychain)
        store1.vmConfiguration = VMConfiguration(
            cpuCount: 8,
            memorySizeGB: 16,
            diskSizeGB: 120,
            runnerCompletionTimeoutSeconds: 7_200
        )
        store1.save()

        let store2 = ConfigStore(defaults: defaults, keychainService: keychain)
        #expect(store2.vmConfiguration.cpuCount == 8)
        #expect(store2.vmConfiguration.memorySizeGB == 16)
        #expect(store2.vmConfiguration.diskSizeGB == 120)
        #expect(store2.vmConfiguration.runnerCompletionTimeoutSeconds == 7_200)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Save and load warm runner configuration")
    func warmRunnerConfigRoundTrip() {
        let suiteName = "test-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = PreviewKeychainService()

        let store1 = ConfigStore(defaults: defaults, keychainService: keychain)
        store1.warmRunnerConfig = WarmRunnerConfiguration(
            isEnabled: true,
            idleShutdownSeconds: 1_200,
            maxConsecutiveJobs: 5
        )
        store1.save()

        let store2 = ConfigStore(defaults: defaults, keychainService: keychain)
        #expect(store2.warmRunnerConfig.isEnabled)
        #expect(store2.warmRunnerConfig.idleShutdownSeconds == 1_200)
        #expect(store2.warmRunnerConfig.maxConsecutiveJobs == 5)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Default values are set")
    func defaultValues() {
        let (store, defaults) = makeStore()

        #expect(store.organizations.isEmpty)
        #expect(store.warmRunnerConfig.isEnabled)
        #expect(store.vmConfiguration.cpuCount == 4)
        #expect(store.vmConfiguration.memorySizeGB == 8)
        #expect(store.vmConfiguration.diskSizeGB == 80)
        #expect(store.vmConfiguration.runnerCompletionTimeoutSeconds == 3_600)
        #expect(store.diagnosticsRetentionConfig.maxBundleCount == 100)
        #expect(store.diagnosticsRetentionConfig.maxAgeDays == 14)
        #expect(!store.keepInstallerAfterVerification)
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

    @Test("Save and load installer retention round-trip")
    func installerRetentionRoundTrip() {
        let suiteName = "test-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = PreviewKeychainService()

        let store1 = ConfigStore(defaults: defaults, keychainService: keychain)
        store1.keepInstallerAfterVerification = true
        store1.save()

        let store2 = ConfigStore(defaults: defaults, keychainService: keychain)
        #expect(store2.keepInstallerAfterVerification)

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

    @Test("Enterprise access tokens are stored in keychain")
    func enterpriseAccessTokensRoundTrip() {
        let (store, _) = makeStore()
        let org = Organization(
            name: "acme",
            accountType: .enterprise,
            appId: "",
            installationId: 0,
            labels: []
        )

        #expect(!store.hasAccessToken(for: org))
        #expect(store.saveAccessToken("  github_pat_enterprise  ", for: org))
        #expect(store.hasAccessToken(for: org))
        #expect(store.loadAccessToken(for: org) == "github_pat_enterprise")
        #expect(store.deleteAccessToken(for: org))
        #expect(!store.hasAccessToken(for: org))
    }

    @Test("Removing organization deletes enterprise access token")
    func removeOrganizationDeletesAccessToken() {
        let (store, _) = makeStore()
        let org = Organization(
            name: "acme",
            accountType: .enterprise,
            appId: "",
            installationId: 0,
            labels: []
        )
        store.addOrganization(org)
        #expect(store.saveAccessToken("github_pat_enterprise", for: org))

        store.removeOrganization(org)

        #expect(store.organizations.isEmpty)
        #expect(!store.hasAccessToken(for: org))
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

    @Test("VM control configuration persists across reloads")
    func vmControlConfigurationPersistence() {
        let suiteName = "test-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = PreviewKeychainService()

        let store1 = ConfigStore(defaults: defaults, keychainService: keychain)
        store1.vmControlConfiguration = VMControlConfiguration(
            isEnabled: true,
            port: 9480,
            authToken: "test-token"
        )
        store1.save()

        let store2 = ConfigStore(defaults: defaults, keychainService: keychain)
        #expect(store2.vmControlConfiguration.isEnabled)
        #expect(store2.vmControlConfiguration.port == 9480)
        #expect(store2.vmControlConfiguration.authToken == "test-token")

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Apple signing assets store metadata separately from keychain material")
    func appleSigningAssetStorage() {
        let suiteName = "test-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = PreviewKeychainService()
        let asset = AppleSigningAsset(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            displayName: "Distribution",
            teamId: "TEAM12345",
            bundleIdentifierPattern: "com.example.*",
            certificateCommonName: "Developer ID Application",
            provisioningProfileUUID: "profile-uuid",
            certificateExpiresAt: Date(timeIntervalSince1970: 4_102_444_800),
            provisioningProfileExpiresAt: Date(timeIntervalSince1970: 4_102_444_800)
        )

        let store1 = ConfigStore(defaults: defaults, keychainService: keychain)
        let saved = store1.saveAppleSigningAsset(
            asset,
            certificateData: Data([0x01, 0x02]),
            certificatePassphrase: "secret",
            provisioningProfileData: Data([0x03, 0x04])
        )

        #expect(saved)
        #expect(store1.appleSigningAssets.count == 1)
        #expect(store1.appleSigningAssets[0].certificateKeychainKey.hasPrefix("apple-signing-certificate-p12-"))
        let githubKey = Organization(name: "org", appId: "1", installationId: 1).privateKeyKeychainKey
        #expect(store1.appleSigningAssets[0].certificateKeychainKey != githubKey)

        let validation = store1.validateAppleSigningAsset(
            store1.appleSigningAssets[0],
            bundleIdentifier: "com.example.app",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(validation.isReady)

        let injection = store1.loadAppleSigningInjection(for: store1.appleSigningAssets[0])
        #expect(injection?.certificateData == Data([0x01, 0x02]))
        #expect(injection?.certificatePassphrase == "secret")
        #expect(injection?.provisioningProfileData == Data([0x03, 0x04]))

        let store2 = ConfigStore(defaults: defaults, keychainService: keychain)
        #expect(store2.appleSigningAssets.count == 1)
        #expect(store2.loadAppleSigningInjection(for: store2.appleSigningAssets[0]) != nil)

        #expect(store2.deleteAppleSigningAsset(store2.appleSigningAssets[0]))
        #expect(store2.appleSigningAssets.isEmpty)
        #expect(keychain.load(key: asset.certificateKeychainKey) == nil)
        #expect(keychain.load(key: asset.passphraseKeychainKey) == nil)
        #expect(keychain.load(key: asset.provisioningProfileKeychainKey) == nil)

        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("Apple signing dispatch loads only explicitly selected assets")
    func appleSigningDispatchSelection() throws {
        let (store, defaults) = makeStore()
        defer { defaults.removePersistentDomain(forName: "test-config") }

        let org = Organization(
            name: "SevenTwo",
            appId: "APP1",
            installationId: 12345,
            imageProfile: RunnerImageProfile(name: "Xcode 17")
        )
        let asset = AppleSigningAsset(
            displayName: "Distribution",
            teamId: "TEAM12345",
            bundleIdentifierPattern: "com.example.*",
            selection: AppleSigningSelection(
                mode: .selectedJobs,
                organizationNames: ["seventwo"],
                repositoryNames: ["tarmac"],
                runnerImageProfileNames: ["xcode 17"],
                workflowNames: ["release"]
            )
        )
        #expect(
            store.saveAppleSigningAsset(
                asset,
                certificateData: Data([0x01]),
                certificatePassphrase: "secret",
                provisioningProfileData: Data([0x02])
            )
        )

        let matchingJob = TestFactories.makeJob(
            id: 42,
            org: "SevenTwo",
            workflowName: "Release",
            repositoryName: "Tarmac"
        )
        let skippedJob = TestFactories.makeJob(
            id: 43,
            org: "SevenTwo",
            workflowName: "CI",
            repositoryName: "Tarmac"
        )

        let injection = try store.loadAppleSigningInjection(for: matchingJob, organization: org)
        #expect(injection?.asset.id == asset.id)
        #expect(injection?.certificatePassphrase == "secret")
        #expect(try store.loadAppleSigningInjection(for: skippedJob, organization: org) == nil)
    }

    @Test("Apple signing dispatch blocks selected invalid assets")
    func appleSigningDispatchBlocksInvalidSelection() {
        let (store, defaults) = makeStore()
        defer { defaults.removePersistentDomain(forName: "test-config") }

        let org = Organization(name: "SevenTwo", appId: "APP1", installationId: 12345)
        let asset = AppleSigningAsset(
            displayName: "Expired Distribution",
            teamId: "TEAM12345",
            bundleIdentifierPattern: "com.example.*",
            selection: AppleSigningSelection(mode: .allJobs),
            certificateExpiresAt: Date(timeIntervalSince1970: 1_000)
        )
        #expect(
            store.saveAppleSigningAsset(
                asset,
                certificateData: Data([0x01]),
                certificatePassphrase: "secret",
                provisioningProfileData: Data([0x02])
            )
        )

        let job = TestFactories.makeJob(id: 42, org: "SevenTwo")
        #expect(throws: AppleSigningDispatchError.self) {
            try store.loadAppleSigningInjection(
                for: job,
                organization: org,
                now: Date(timeIntervalSince1970: 2_000)
            )
        }
    }

    @Test("Apple signing validation catches missing material, expiry, and bundle mismatch")
    func appleSigningValidationIssues() {
        let (store, defaults) = makeStore()
        let expired = Date(timeIntervalSince1970: 1_000)
        let asset = AppleSigningAsset(
            displayName: "",
            teamId: "",
            bundleIdentifierPattern: "com.example.app",
            certificateExpiresAt: expired,
            provisioningProfileExpiresAt: expired
        )

        let validation = store.validateAppleSigningAsset(
            asset,
            bundleIdentifier: "com.other.app",
            now: Date(timeIntervalSince1970: 2_000)
        )

        #expect(validation.issues.contains(.missingDisplayName))
        #expect(validation.issues.contains(.missingTeamId))
        #expect(validation.issues.contains(.missingCertificate))
        #expect(validation.issues.contains(.missingCertificatePassphrase))
        #expect(validation.issues.contains(.missingProvisioningProfile))
        #expect(validation.issues.contains(.expiredCertificate))
        #expect(validation.issues.contains(.expiredProvisioningProfile))
        #expect(validation.issues.contains(.bundleIdentifierMismatch))

        defaults.removePersistentDomain(forName: "test-config")
    }
}
