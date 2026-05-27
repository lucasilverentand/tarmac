import Foundation

@Observable
@MainActor
final class ConfigStore {
    private let defaults: UserDefaults
    let keychainService: any KeychainServiceProtocol

    private(set) var organizations: [Organization] = []
    private(set) var appleSigningAssets: [AppleSigningAsset] = []
    var vmConfiguration: VMConfiguration = VMConfiguration()
    var cacheConfig: CacheConfiguration = CacheConfiguration()
    var warmRunnerConfig: WarmRunnerConfiguration = WarmRunnerConfiguration()
    var diagnosticsRetentionConfig: DiagnosticsRetentionConfiguration = DiagnosticsRetentionConfiguration()
    var vmControlConfiguration: VMControlConfiguration = VMControlConfiguration()
    var keepInstallerAfterVerification: Bool = false
    var storageDirectoryPath: String = ""
    var baseImagePath: String = ""
    var hasCompletedStorageSetup: Bool = false

    var cacheDirectoryPath: String {
        get { StorageManager(rootPath: storageDirectoryPath).actionsCacheDirectory.path }
        set {
            if storageDirectoryPath.isEmpty {
                storageDirectoryPath =
                    URL(fileURLWithPath: newValue)
                    .deletingLastPathComponent()
                    .standardizedFileURL
                    .path
            }
        }
    }

    var storageRootPath: String {
        get { storageDirectoryPath }
        set {
            let root = URL(fileURLWithPath: newValue).standardizedFileURL
            storageDirectoryPath = root.path
            baseImagePath = root.appendingPathComponent("BaseImage.img").path
        }
    }
    var launchAtLogin: Bool = false

    static var defaultStorageDirectoryPath: String {
        StorageManager.defaultRootDirectory.path
    }

    init(
        defaults: UserDefaults = .standard,
        keychainService: any KeychainServiceProtocol = KeychainService()
    ) {
        self.defaults = defaults
        self.keychainService = keychainService
        load()
    }

    // MARK: - Organizations

    func addOrganization(_ org: Organization) {
        organizations.append(org)
        saveOrganizations()
    }

    func removeOrganization(_ org: Organization) {
        _ = keychainService.delete(key: org.privateKeyKeychainKey)
        _ = keychainService.delete(key: org.accessTokenKeychainKey)
        organizations.removeAll { $0.id == org.id }
        saveOrganizations()
    }

    func updateOrganization(_ org: Organization) {
        guard let index = organizations.firstIndex(where: { $0.id == org.id }) else { return }
        organizations[index] = org
        saveOrganizations()
    }

    func moveOrganization(fromOffsets source: IndexSet, toOffset destination: Int) {
        organizations.move(fromOffsets: source, toOffset: destination)
        saveOrganizations()
    }

    // MARK: - Per-Org Private Keys

    func savePrivateKey(_ pemData: Data, for org: Organization) -> Bool {
        keychainService.save(key: org.privateKeyKeychainKey, data: pemData)
    }

    func loadPrivateKey(for org: Organization) -> Data? {
        keychainService.load(key: org.privateKeyKeychainKey)
    }

    func deletePrivateKey(for org: Organization) -> Bool {
        keychainService.delete(key: org.privateKeyKeychainKey)
    }

    func hasPrivateKey(for org: Organization) -> Bool {
        keychainService.load(key: org.privateKeyKeychainKey) != nil
    }

    // MARK: - Per-Account Access Tokens

    func saveAccessToken(_ token: String, for org: Organization) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return keychainService.save(key: org.accessTokenKeychainKey, data: Data(trimmed.utf8))
    }

    func loadAccessToken(for org: Organization) -> String? {
        guard let data = keychainService.load(key: org.accessTokenKeychainKey),
            let token = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func deleteAccessToken(for org: Organization) -> Bool {
        keychainService.delete(key: org.accessTokenKeychainKey)
    }

    func hasAccessToken(for org: Organization) -> Bool {
        loadAccessToken(for: org) != nil
    }

    // MARK: - Apple Signing Assets

    func saveAppleSigningAsset(
        _ asset: AppleSigningAsset,
        certificateData: Data,
        certificatePassphrase: String,
        provisioningProfileData: Data
    ) -> Bool {
        guard !certificateData.isEmpty,
            !certificatePassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !provisioningProfileData.isEmpty
        else {
            return false
        }

        var storedAsset = asset
        let now = Date()
        if appleSigningAssets.contains(where: { $0.id == asset.id }) {
            storedAsset.updatedAt = now
        } else {
            storedAsset.createdAt = now
            storedAsset.updatedAt = now
        }

        let previousCertificate = keychainService.load(key: storedAsset.certificateKeychainKey)
        let previousPassphrase = keychainService.load(key: storedAsset.passphraseKeychainKey)
        let previousProfile = keychainService.load(key: storedAsset.provisioningProfileKeychainKey)

        let savedCertificate = keychainService.save(key: storedAsset.certificateKeychainKey, data: certificateData)
        let savedPassphrase = keychainService.save(
            key: storedAsset.passphraseKeychainKey,
            data: Data(certificatePassphrase.utf8)
        )
        let savedProfile = keychainService.save(
            key: storedAsset.provisioningProfileKeychainKey,
            data: provisioningProfileData
        )

        guard savedCertificate && savedPassphrase && savedProfile else {
            restoreKeychainValue(previousCertificate, key: storedAsset.certificateKeychainKey)
            restoreKeychainValue(previousPassphrase, key: storedAsset.passphraseKeychainKey)
            restoreKeychainValue(previousProfile, key: storedAsset.provisioningProfileKeychainKey)
            return false
        }

        upsertAppleSigningAsset(storedAsset)
        return true
    }

    func deleteAppleSigningAsset(_ asset: AppleSigningAsset) -> Bool {
        let deletedCertificate = keychainService.delete(key: asset.certificateKeychainKey)
        let deletedPassphrase = keychainService.delete(key: asset.passphraseKeychainKey)
        let deletedProfile = keychainService.delete(key: asset.provisioningProfileKeychainKey)
        appleSigningAssets.removeAll { $0.id == asset.id }
        saveAppleSigningAssets()
        return deletedCertificate && deletedPassphrase && deletedProfile
    }

    func updateAppleSigningAssetSelection(assetId: UUID, selection: AppleSigningSelection) -> Bool {
        guard let index = appleSigningAssets.firstIndex(where: { $0.id == assetId }) else {
            return false
        }
        appleSigningAssets[index].selection = selection
        appleSigningAssets[index].updatedAt = Date()
        saveAppleSigningAssets()
        return true
    }

    func loadAppleSigningInjection(for asset: AppleSigningAsset) -> AppleSigningInjection? {
        guard let certificateData = keychainService.load(key: asset.certificateKeychainKey),
            let passphraseData = keychainService.load(key: asset.passphraseKeychainKey),
            let passphrase = String(data: passphraseData, encoding: .utf8),
            let provisioningProfileData = keychainService.load(key: asset.provisioningProfileKeychainKey)
        else {
            return nil
        }

        return AppleSigningInjection(
            asset: asset,
            certificateData: certificateData,
            certificatePassphrase: passphrase,
            provisioningProfileData: provisioningProfileData
        )
    }

    func loadAppleSigningInjection(
        for job: RunnerJob,
        organization: Organization,
        now: Date = Date()
    ) throws -> AppleSigningInjection? {
        guard
            let asset = appleSigningAssets.first(where: { asset in
                asset.selection.matches(job: job, organization: organization)
            })
        else {
            return nil
        }

        let validation = validateAppleSigningAsset(asset, now: now)
        guard validation.isReady else {
            throw AppleSigningDispatchError.invalidAsset(assetName: asset.displayName, issues: validation.issues)
        }

        guard let injection = loadAppleSigningInjection(for: asset) else {
            throw AppleSigningDispatchError.missingMaterial(assetName: asset.displayName)
        }

        return injection
    }

    func validateAppleSigningAsset(
        _ asset: AppleSigningAsset,
        bundleIdentifier: String? = nil,
        now: Date = Date()
    ) -> AppleSigningAssetValidation {
        var issues: [AppleSigningAssetValidationIssue] = []
        if asset.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.missingDisplayName)
        }
        if asset.teamId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.missingTeamId)
        }
        if asset.bundleIdentifierPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.missingBundleIdentifierPattern)
        }
        if keychainService.load(key: asset.certificateKeychainKey)?.isEmpty != false {
            issues.append(.missingCertificate)
        }
        if let passphraseData = keychainService.load(key: asset.passphraseKeychainKey),
            let passphrase = String(data: passphraseData, encoding: .utf8),
            !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            // Present and usable.
        } else {
            issues.append(.missingCertificatePassphrase)
        }
        if keychainService.load(key: asset.provisioningProfileKeychainKey)?.isEmpty != false {
            issues.append(.missingProvisioningProfile)
        }
        if let expiresAt = asset.certificateExpiresAt, expiresAt <= now {
            issues.append(.expiredCertificate)
        }
        if let expiresAt = asset.provisioningProfileExpiresAt, expiresAt <= now {
            issues.append(.expiredProvisioningProfile)
        }
        if let bundleIdentifier, !asset.matches(bundleIdentifier: bundleIdentifier) {
            issues.append(.bundleIdentifierMismatch)
        }
        return AppleSigningAssetValidation(assetId: asset.id, issues: issues)
    }

    // MARK: - Storage

    var resolvedBaseImagePath: String {
        if !baseImagePath.isEmpty {
            return baseImagePath
        }
        return URL(fileURLWithPath: storageDirectoryPath)
            .appendingPathComponent("BaseImage.img")
            .path
    }

    var platformDirectoryPath: String {
        URL(fileURLWithPath: storageDirectoryPath)
            .appendingPathComponent("Platform")
            .path
    }

    func configureStorage(at directory: URL) throws {
        let root = directory.standardizedFileURL
        let storage = StorageManager(rootDirectory: root)
        try storage.validateForSetup()

        storageRootPath = root.path
        hasCompletedStorageSetup = true
        save()
    }

    // MARK: - Persistence

    func save() {
        saveOrganizations()
        saveAppleSigningAssets()
        if let data = try? JSONEncoder().encode(vmConfiguration) {
            defaults.set(data, forKey: "vmConfiguration")
        }
        if let data = try? JSONEncoder().encode(cacheConfig) {
            defaults.set(data, forKey: "cacheConfiguration")
        }
        if let data = try? JSONEncoder().encode(warmRunnerConfig) {
            defaults.set(data, forKey: "warmRunnerConfiguration")
        }
        if let data = try? JSONEncoder().encode(diagnosticsRetentionConfig) {
            defaults.set(data, forKey: "diagnosticsRetentionConfiguration")
        }
        if let data = try? JSONEncoder().encode(vmControlConfiguration) {
            defaults.set(data, forKey: "vmControlConfiguration")
        }
        defaults.set(keepInstallerAfterVerification, forKey: "keepInstallerAfterVerification")
        defaults.set(storageDirectoryPath, forKey: "storageDirectoryPath")
        defaults.set(baseImagePath, forKey: "baseImagePath")
        defaults.set(cacheDirectoryPath, forKey: "cacheDirectoryPath")
        defaults.set(storageRootPath, forKey: "storageRootPath")
        defaults.set(hasCompletedStorageSetup, forKey: "hasCompletedStorageSetup")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        Log.config.debug("Configuration saved")
    }

    private func load() {
        if let data = defaults.data(forKey: "organizations"),
            let orgs = try? JSONDecoder().decode([Organization].self, from: data)
        {
            organizations = orgs
        }
        if let data = defaults.data(forKey: "appleSigningAssets"),
            let assets = try? JSONDecoder().decode([AppleSigningAsset].self, from: data)
        {
            appleSigningAssets = assets
        }
        if let data = defaults.data(forKey: "vmConfiguration"),
            let config = try? JSONDecoder().decode(VMConfiguration.self, from: data)
        {
            vmConfiguration = config
        }
        if let data = defaults.data(forKey: "cacheConfiguration"),
            let config = try? JSONDecoder().decode(CacheConfiguration.self, from: data)
        {
            cacheConfig = config
        }
        if let data = defaults.data(forKey: "warmRunnerConfiguration"),
            let config = try? JSONDecoder().decode(WarmRunnerConfiguration.self, from: data)
        {
            warmRunnerConfig = config
        }
        if let data = defaults.data(forKey: "diagnosticsRetentionConfiguration"),
            let config = try? JSONDecoder().decode(DiagnosticsRetentionConfiguration.self, from: data)
        {
            diagnosticsRetentionConfig = config
        }
        if let data = defaults.data(forKey: "vmControlConfiguration"),
            let config = try? JSONDecoder().decode(VMControlConfiguration.self, from: data)
        {
            vmControlConfiguration = config
        }
        keepInstallerAfterVerification = defaults.bool(forKey: "keepInstallerAfterVerification")
        storageDirectoryPath = defaults.string(forKey: "storageDirectoryPath") ?? ""
        baseImagePath = defaults.string(forKey: "baseImagePath") ?? ""
        let legacyStorageRootPath = defaults.string(forKey: "storageRootPath")
        let legacyCacheDirectoryPath = defaults.string(forKey: "cacheDirectoryPath")
        hasCompletedStorageSetup = defaults.bool(forKey: "hasCompletedStorageSetup")
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")

        let hasExistingConfig =
            !organizations.isEmpty
            || defaults.string(forKey: "baseImagePath") != nil
            || defaults.string(forKey: "cacheDirectoryPath") != nil

        if storageDirectoryPath.isEmpty {
            storageDirectoryPath =
                legacyStorageRootPath
                ?? legacyCacheDirectoryPath
                ?? Self.defaultStorageDirectoryPath
            hasCompletedStorageSetup = hasCompletedStorageSetup || hasExistingConfig
        }

        if baseImagePath.isEmpty {
            baseImagePath = StorageManager(rootPath: storageDirectoryPath).baseImageURL.path
        }

        Log.config.debug("Configuration loaded: \(self.organizations.count) organizations")
    }

    private func saveOrganizations() {
        if let data = try? JSONEncoder().encode(organizations) {
            defaults.set(data, forKey: "organizations")
        }
    }

    private func saveAppleSigningAssets() {
        if let data = try? JSONEncoder().encode(appleSigningAssets) {
            defaults.set(data, forKey: "appleSigningAssets")
        }
    }

    private func upsertAppleSigningAsset(_ asset: AppleSigningAsset) {
        if let index = appleSigningAssets.firstIndex(where: { $0.id == asset.id }) {
            appleSigningAssets[index] = asset
        } else {
            appleSigningAssets.append(asset)
        }
        saveAppleSigningAssets()
    }

    private func restoreKeychainValue(_ data: Data?, key: String) {
        if let data {
            _ = keychainService.save(key: key, data: data)
        } else {
            _ = keychainService.delete(key: key)
        }
    }
}
