import Foundation

@Observable
@MainActor
final class SettingsViewModel {
    let configStore: ConfigStore
    var onWarmRunnerConfigurationChanged: (@MainActor (WarmRunnerConfiguration) -> Void)?
    private(set) var storageHealth: StorageHealth
    private(set) var githubSetupChecks: [UUID: GitHubSetupCheckResult] = [:]
    private(set) var providerSetupChecks: [UUID: ProviderSetupResult] = [:]
    private(set) var pollingStates: [UUID: QueuePollingState] = [:]
    private(set) var githubSetupChecksInFlight: Set<UUID> = []
    private(set) var lastBaseImageResetError: String?

    init(configStore: ConfigStore) {
        self.configStore = configStore
        // Avoid requesting removable-volume access while SwiftUI is still constructing
        // the scene graph. The full probe runs from AppState.start() after launch.
        self.storageHealth = StorageManager(rootPath: configStore.storageRootPath).evaluateHealth(
            performCloneProbe: false
        )
    }

    // MARK: - Organizations

    var organizations: [Organization] {
        configStore.organizations
    }

    func addOrganization(_ org: Organization) {
        configStore.addOrganization(org)
    }

    func removeOrganization(_ org: Organization) {
        configStore.removeOrganization(org)
    }

    func updateOrganization(_ org: Organization) {
        configStore.updateOrganization(org)
    }

    func moveOrganization(fromOffsets source: IndexSet, toOffset destination: Int) {
        configStore.moveOrganization(fromOffsets: source, toOffset: destination)
    }

    func updatePollingState(_ state: QueuePollingState?, for account: RunnerAccount) {
        pollingStates[account.id] = state
    }

    func pollingState(for account: RunnerAccount) -> QueuePollingState? {
        pollingStates[account.id]
    }

    // MARK: - Per-Org Credentials

    func hasPrivateKey(for org: Organization) -> Bool {
        configStore.hasPrivateKey(for: org)
    }

    func importPrivateKey(from url: URL, for org: Organization) throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw SettingsError.fileAccessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }

        let data = try Data(contentsOf: url)
        guard configStore.savePrivateKey(data, for: org) else {
            throw SettingsError.keychainSaveFailed
        }
        Log.config.info("Private key imported for org \(org.name)")
    }

    func deletePrivateKey(for org: Organization) {
        _ = configStore.deletePrivateKey(for: org)
        Log.config.info("Private key deleted for org \(org.name)")
    }

    func hasAccessToken(for org: Organization) -> Bool {
        configStore.hasAccessToken(for: org)
    }

    func saveAccessToken(_ token: String, for org: Organization) -> Bool {
        let saved = configStore.saveAccessToken(token, for: org)
        if saved {
            Log.config.info("Access token saved for account \(org.name)")
        }
        return saved
    }

    func deleteAccessToken(for org: Organization) -> Bool {
        let deleted = configStore.deleteAccessToken(for: org)
        Log.config.info("Access token deleted for account \(org.name)")
        return deleted
    }

    /// The default name Tarmac gives the runner scale sets it creates. Stable so
    /// the create action reconciles to the same scale set instead of duplicating.
    static let defaultScaleSetName = "tarmac-macos"

    /// Find or create a runner scale set for the account currently being edited
    /// and return its numeric ID. Credentials are taken from the in-flight form
    /// values when provided, falling back to the Keychain for a saved account.
    ///
    /// GitHub has no web UI to create a runner scale set, so this is how a fresh
    /// account obtains the scale-set ID that polling requires.
    func createScaleSet(
        for org: Organization,
        scaleSetName: String,
        runnerGroupId: Int,
        inFlightAccessToken: String?,
        inFlightPrivateKey: Data?
    ) async throws -> Int {
        guard !org.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SettingsError.missingAccountName
        }

        let engine = GitHubEngine(
            keychainService: configStore.keychainService,
            storage: StorageManager(rootPath: configStore.storageRootPath)
        )

        let token: String
        if org.requiresAccessToken {
            let inFlight = inFlightAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let inFlight, !inFlight.isEmpty {
                token = inFlight
            } else if let saved = configStore.loadAccessToken(for: org) {
                token = saved
            } else {
                throw SettingsError.missingCredentials
            }
        } else {
            guard let keyData = inFlightPrivateKey ?? configStore.loadPrivateKey(for: org) else {
                throw SettingsError.missingCredentials
            }
            token = try await engine.installationToken(
                appId: org.appId,
                installationId: org.installationId,
                privateKeyData: keyData
            )
        }

        let scaleSet = try await engine.ensureScaleSet(
            accountPath: org.accountPath,
            token: token,
            name: scaleSetName,
            runnerGroupId: runnerGroupId,
            labels: org.runnerLabels
        )
        Log.config.info("Resolved runner scale set \(scaleSet.id) for account \(org.name)")
        return scaleSet.id
    }

    /// Reconcile stored Keychain credentials when an account's runner type
    /// changes, dropping secrets the new type no longer uses so stale material
    /// does not outlive its purpose.
    ///
    /// - GitHub App → access token: save the access token (when provided) and
    ///   remove the now-unused GitHub App private key.
    /// - access token → GitHub App: remove the now-unused access token.
    func reconcileCredentials(
        for org: Organization,
        newType: GitHubAccountType,
        previousType: GitHubAccountType,
        newCredentialMode: GitHubCredentialMode,
        previousCredentialMode: GitHubCredentialMode,
        accessToken: String
    ) {
        let usesToken = newType == .enterprise || newCredentialMode == .accessToken
        let previouslyUsedToken = previousType == .enterprise || previousCredentialMode == .accessToken

        if usesToken {
            if !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = saveAccessToken(accessToken, for: org)
            }
            if !previouslyUsedToken {
                deletePrivateKey(for: org)
            }
        } else {
            if previouslyUsedToken {
                _ = deleteAccessToken(for: org)
            }
        }
    }

    func findRepositoryInstallationId(
        owner: String,
        repositoryName: String,
        appId: String,
        privateKeyData: Data
    ) async throws -> Int {
        let engine = GitHubEngine(
            keychainService: configStore.keychainService,
            storage: StorageManager(rootPath: configStore.storageRootPath)
        )
        return try await engine.repositoryInstallationId(
            owner: owner,
            repositoryName: repositoryName,
            appId: appId,
            privateKeyData: privateKeyData
        )
    }

    func findOrganizationInstallationId(
        organizationName: String,
        appId: String,
        privateKeyData: Data
    ) async throws -> Int {
        let engine = GitHubEngine(
            keychainService: configStore.keychainService,
            storage: StorageManager(rootPath: configStore.storageRootPath)
        )
        return try await engine.organizationInstallationId(
            organizationName: organizationName,
            appId: appId,
            privateKeyData: privateKeyData
        )
    }

    func findEnterpriseInstallationId(
        enterpriseSlug: String,
        appId: String,
        privateKeyData: Data
    ) async throws -> Int {
        let engine = GitHubEngine(
            keychainService: configStore.keychainService,
            storage: StorageManager(rootPath: configStore.storageRootPath)
        )
        return try await engine.enterpriseInstallationId(
            enterpriseSlug: enterpriseSlug,
            appId: appId,
            privateKeyData: privateKeyData
        )
    }

    func listEnterpriseInstallableOrganizations(
        enterpriseSlug: String,
        enterpriseInstallationId: Int,
        appId: String,
        privateKeyData: Data
    ) async throws -> [EnterpriseInstallableOrganization] {
        let engine = GitHubEngine(
            keychainService: configStore.keychainService,
            storage: StorageManager(rootPath: configStore.storageRootPath)
        )
        return try await engine.listEnterpriseInstallableOrganizations(
            enterpriseSlug: enterpriseSlug,
            enterpriseInstallationId: enterpriseInstallationId,
            appId: appId,
            privateKeyData: privateKeyData
        )
    }

    func installEnterpriseGitHubApp(
        enterpriseSlug: String,
        organizationName: String,
        enterpriseInstallationId: Int,
        appId: String,
        clientId: String,
        privateKeyData: Data,
        repositorySelection: EnterpriseGitHubAppInstallRepositorySelection,
        repositories: [String]
    ) async throws -> EnterpriseOrganizationInstallation {
        let engine = GitHubEngine(
            keychainService: configStore.keychainService,
            storage: StorageManager(rootPath: configStore.storageRootPath)
        )
        return try await engine.installEnterpriseGitHubApp(
            enterpriseSlug: enterpriseSlug,
            organizationName: organizationName,
            enterpriseInstallationId: enterpriseInstallationId,
            appId: appId,
            clientId: clientId,
            privateKeyData: privateKeyData,
            repositorySelection: repositorySelection,
            repositories: repositories
        )
    }

    // MARK: - VM Configuration

    var vmConfiguration: VMConfiguration {
        get { configStore.vmConfiguration }
        set {
            configStore.vmConfiguration = newValue
            configStore.save()
        }
    }

    // MARK: - Cache Configuration

    var cacheConfig: CacheConfiguration {
        get { configStore.cacheConfig }
        set {
            configStore.cacheConfig = newValue
            configStore.save()
        }
    }

    var warmRunnerConfig: WarmRunnerConfiguration {
        get { configStore.warmRunnerConfig }
        set {
            configStore.warmRunnerConfig = newValue
            configStore.save()
            onWarmRunnerConfigurationChanged?(newValue)
        }
    }

    var diagnosticsRetentionConfig: DiagnosticsRetentionConfiguration {
        get { configStore.diagnosticsRetentionConfig }
        set {
            configStore.diagnosticsRetentionConfig = newValue
            configStore.save()
        }
    }

    var vmControlConfiguration: VMControlConfiguration {
        get { configStore.vmControlConfiguration }
        set {
            var updated = newValue
            if updated.isEnabled {
                updated.ensureAuthToken()
            }
            configStore.vmControlConfiguration = updated
            configStore.save()
        }
    }

    func rotateVMControlToken() {
        var configuration = configStore.vmControlConfiguration
        configuration.rotateAuthToken()
        configStore.vmControlConfiguration = configuration
        configStore.save()
    }

    var keepInstallerAfterVerification: Bool {
        get { configStore.keepInstallerAfterVerification }
        set {
            configStore.keepInstallerAfterVerification = newValue
            configStore.save()
            refreshStorageHealth()
        }
    }

    // MARK: - General

    var launchAtLogin: Bool {
        get { configStore.launchAtLogin }
        set {
            configStore.launchAtLogin = newValue
            configStore.save()
        }
    }

    var storageDirectoryPath: String {
        configStore.storageDirectoryPath
    }

    var cacheDirectoryPath: String {
        get { configStore.storageRootPath }
        set {
            do {
                try setStorageRoot(to: URL(fileURLWithPath: newValue))
            } catch {
                Log.config.error("Failed to migrate storage folder: \(error.localizedDescription)")
                return
            }
        }
    }

    var storageRootPath: String {
        get { cacheDirectoryPath }
        set { cacheDirectoryPath = newValue }
    }

    var resolvedCachePath: String {
        StorageManager(rootPath: configStore.storageRootPath).actionsCacheDirectory.path
    }

    var cacheSizeDescription: String {
        let manager = CacheManager(storage: StorageManager(rootPath: configStore.storageRootPath))
        return formatBytes((try? manager.currentSizeBytes()) ?? 0)
    }

    var storageUsageDescription: String {
        let report = storageReport
        let used = report.totalManagedBytes
        let free = report.freeBytes
        if let free {
            return "\(formatBytes(used)) used, \(formatBytes(free)) available"
        }
        return "\(formatBytes(used)) used"
    }

    var storageReport: StorageReport {
        StorageManager(rootPath: configStore.storageRootPath).storageReport()
    }

    var retainedInstallerDescription: String? {
        guard keepInstallerAfterVerification, storageHealth.installerArtifactSizeBytes > 0 else { return nil }
        return formatBytes(storageHealth.installerArtifactSizeBytes)
    }

    var storageWarning: String? {
        storageHealth.issues.first?.message
    }

    var baseImagePath: String {
        configStore.resolvedBaseImagePath
    }

    var platformDirectoryPath: String {
        configStore.platformDirectoryPath
    }

    var restoreImagePath: String {
        URL(fileURLWithPath: configStore.storageDirectoryPath)
            .appendingPathComponent("restore.ipsw")
            .path
    }

    func configureStorage(at url: URL) throws {
        try setStorageRoot(to: url)
    }

    func formatStorageBytes(_ bytes: Int64) -> String {
        formatBytes(bytes)
    }

    func clearCache() {
        let manager = CacheManager(storage: StorageManager(rootPath: configStore.storageRootPath))
        do {
            try manager.clear()
            try manager.prepare()
            refreshStorageHealth()
            Log.cache.info("Cache cleared from settings")
        } catch {
            Log.cache.error("Failed to clear cache: \(error.localizedDescription)")
        }
    }

    func cleanupStorage() {
        let storage = StorageManager(rootPath: configStore.storageRootPath)
        do {
            try storage.cleanupTransientFiles()
            try CacheManager(storage: storage).enforceMaxSize(maxSizeGB: configStore.cacheConfig.maxSizeGB)
            refreshStorageHealth()
            Log.cache.info("Storage cleanup completed from settings")
        } catch {
            Log.cache.error("Failed to clean storage: \(error.localizedDescription)")
        }
    }

    func cleanupJobScratch() {
        let storage = StorageManager(rootPath: configStore.storageRootPath)
        do {
            try storage.cleanupJobScratch()
            refreshStorageHealth()
            Log.cache.info("Stale job scratch cleanup completed from settings")
        } catch {
            Log.cache.error("Failed to clean stale job scratch data: \(error.localizedDescription)")
        }
    }

    func cleanupDebugDisks() {
        let storage = StorageManager(rootPath: configStore.storageRootPath)
        do {
            try storage.cleanupDebugDisks()
            refreshStorageHealth()
            Log.cache.info("Stale cloned disk cleanup completed from settings")
        } catch {
            Log.cache.error("Failed to clean stale cloned disks: \(error.localizedDescription)")
        }
    }

    func cleanupInstallerArtifacts() {
        let storage = StorageManager(rootPath: configStore.storageRootPath)
        do {
            try storage.cleanupInstallerArtifacts()
            refreshStorageHealth()
            Log.cache.info("Installer artifacts removed from settings")
        } catch {
            Log.cache.error("Failed to remove installer artifacts: \(error.localizedDescription)")
        }
    }

    func resetBaseImage(preserveRestoreImage: Bool = true) -> Bool {
        let storage = StorageManager(rootPath: configStore.storageRootPath)
        do {
            let result = try storage.resetBaseImage(preserveRestoreImage: preserveRestoreImage)
            configStore.baseImagePath = storage.baseImageURL.path
            configStore.save()
            refreshStorageHealth()
            lastBaseImageResetError = nil
            Log.image.info("Base image reset removed \(result.removedItems) item(s)")
            return true
        } catch {
            lastBaseImageResetError = error.localizedDescription
            Log.image.error("Failed to reset base image: \(error.localizedDescription)")
            return false
        }
    }

    func refreshStorageHealth(performCloneProbe: Bool = true) {
        storageHealth = StorageManager(rootPath: configStore.storageRootPath).evaluateHealth(
            performCloneProbe: performCloneProbe
        )
    }

    func scanRunnerImage(
        baseImagePath: String,
        vmConfiguration: VMConfiguration
    ) async throws -> RunnerImageInventoryReport {
        let imagePath =
            baseImagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? configStore.resolvedBaseImagePath
            : baseImagePath
        let engine = VMEngine(
            cacheDirectoryPath: configStore.storageRootPath,
            baseImagePath: configStore.resolvedBaseImagePath,
            platformDirectoryPath: configStore.platformDirectoryPath,
            cacheConfig: configStore.cacheConfig,
            diagnosticsRetention: configStore.diagnosticsRetentionConfig
        )
        return try await engine.scanRunnerImage(
            baseImagePath: imagePath,
            config: vmConfiguration
        )
    }

    // MARK: - GitHub Setup Checks

    func setupCheckResult(for org: Organization) -> GitHubSetupCheckResult? {
        githubSetupChecks[org.id]
    }

    func isSetupCheckRunning(for org: Organization) -> Bool {
        githubSetupChecksInFlight.contains(org.id)
    }

    func providerSetupCheckResult(for account: RunnerAccount) -> ProviderSetupResult? {
        providerSetupChecks[account.id]
    }

    func runAccountSetupCheck(for account: RunnerAccount) async {
        if account.provider == .github {
            await runGitHubSetupCheck(for: account)
            return
        }
        _ = await runGiteaSetupCheck(for: account)
    }

    func runGiteaSetupCheck(for account: RunnerAccount) async -> ProviderSetupResult {
        githubSetupChecksInFlight.insert(account.id)
        defer { githubSetupChecksInFlight.remove(account.id) }
        do {
            let engine = try GiteaEngine(
                account: account,
                keychainService: configStore.keychainService,
                storage: StorageManager(rootPath: configStore.storageRootPath)
            )
            let result = await engine.validate(account: account)
            providerSetupChecks[account.id] = result
            return result
        } catch {
            let result = ProviderSetupResult(
                provider: .gitea,
                accountID: account.id,
                serverVersion: nil,
                issues: [.invalidConfiguration(error.localizedDescription)]
            )
            providerSetupChecks[account.id] = result
            return result
        }
    }

    func runGitHubSetupCheck(for org: Organization) async {
        let engine = GitHubEngine(
            keychainService: configStore.keychainService,
            storage: StorageManager(rootPath: configStore.storageRootPath)
        )
        _ = await runGitHubSetupCheck(for: org, using: engine)
    }

    func runGitHubSetupCheck(for org: Organization, using engine: GitHubEngine) async -> GitHubSetupCheckResult {
        githubSetupChecksInFlight.insert(org.id)
        defer { githubSetupChecksInFlight.remove(org.id) }

        let result = await engine.runSetupCheck(for: org)
        githubSetupChecks[org.id] = result
        return result
    }

    func runGitHubSetupChecks(using engine: GitHubEngine) async -> [GitHubSetupCheckResult] {
        var results: [GitHubSetupCheckResult] = []
        for org in configStore.organizations where org.isEnabled && org.provider == .github {
            results.append(await runGitHubSetupCheck(for: org, using: engine))
        }
        return results
    }

    // MARK: - Validation

    func validateConfiguration(
        hostCapability: HostCapability = .current()
    ) -> [String] {
        refreshStorageHealth()
        return RunnerHostReadiness.evaluate(
            configStore: configStore,
            storageHealth: storageHealth,
            hostCapability: hostCapability
        )
        .issues
        .map(\.message)
    }

    private func setStorageRoot(to directory: URL) throws {
        let newStorage = StorageManager(rootDirectory: directory)
        try newStorage.validateForSetup()

        if configStore.hasCompletedStorageSetup {
            let oldRoot = URL(fileURLWithPath: configStore.storageRootPath)
            let explicitBaseImageURL =
                configStore.baseImagePath.isEmpty
                ? nil
                : URL(fileURLWithPath: configStore.baseImagePath)
            let result = try newStorage.migrateManagedData(
                from: oldRoot,
                explicitBaseImageURL: explicitBaseImageURL
            )
            if result.movedItems > 0 {
                Log.config.info("Migrated \(result.movedItems) storage item(s) to \(newStorage.rootDirectory.path)")
            }
            if result.skippedExistingDestination > 0 {
                Log.config.warning(
                    "Skipped \(result.skippedExistingDestination) storage item(s) because the destination already exists"
                )
            }
        }

        configStore.storageRootPath = newStorage.rootDirectory.path
        configStore.baseImagePath = newStorage.baseImageURL.path
        configStore.hasCompletedStorageSetup = true
        configStore.save()
        refreshStorageHealth()
        Log.config.info("Storage directory changed to \(newStorage.rootDirectory.path)")
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    return formatter.string(fromByteCount: bytes)
}

enum SettingsError: LocalizedError {
    case fileAccessDenied
    case keychainSaveFailed
    case missingCredentials
    case missingAccountName

    var errorDescription: String? {
        switch self {
        case .fileAccessDenied: "Could not access the selected file"
        case .keychainSaveFailed: "Failed to save key to keychain"
        case .missingCredentials:
            "Add the account credentials (App private key or runner access token) before creating a scale set."
        case .missingAccountName:
            "Enter the repository owner, organization name, or enterprise slug before creating a scale set."
        }
    }
}
