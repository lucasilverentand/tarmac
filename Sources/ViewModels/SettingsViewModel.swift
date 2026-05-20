import Foundation

@Observable
@MainActor
final class SettingsViewModel {
    let configStore: ConfigStore
    private(set) var storageHealth: StorageHealth
    private(set) var githubSetupChecks: [UUID: GitHubSetupCheckResult] = [:]
    private(set) var githubSetupChecksInFlight: Set<UUID> = []
    private(set) var lastBaseImageResetError: String?

    init(configStore: ConfigStore) {
        self.configStore = configStore
        self.storageHealth = StorageManager(rootPath: configStore.storageRootPath).evaluateHealth()
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

    var diagnosticsRetentionConfig: DiagnosticsRetentionConfiguration {
        get { configStore.diagnosticsRetentionConfig }
        set {
            configStore.diagnosticsRetentionConfig = newValue
            configStore.save()
        }
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

    func refreshStorageHealth() {
        storageHealth = StorageManager(rootPath: configStore.storageRootPath).evaluateHealth()
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
        for org in configStore.organizations where org.isEnabled {
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

    var errorDescription: String? {
        switch self {
        case .fileAccessDenied: "Could not access the selected file"
        case .keychainSaveFailed: "Failed to save key to keychain"
        }
    }
}
