import Foundation

@Observable
@MainActor
final class SettingsViewModel {
    let configStore: ConfigStore

    init(configStore: ConfigStore) {
        self.configStore = configStore
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

    // MARK: - General

    var launchAtLogin: Bool {
        get { configStore.launchAtLogin }
        set {
            configStore.launchAtLogin = newValue
            configStore.save()
        }
    }

    var cacheDirectoryPath: String {
        get { configStore.storageRootPath }
        set {
            let oldRoot = URL(fileURLWithPath: configStore.storageRootPath)
            let newStorage = StorageManager(rootPath: newValue)
            do {
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
                configStore.storageRootPath = newStorage.rootDirectory.path
                configStore.baseImagePath = newStorage.baseImageURL.path
            } catch {
                Log.config.error("Failed to migrate storage folder: \(error.localizedDescription)")
                return
            }
            configStore.save()
        }
    }

    var storageRootPath: String {
        get { cacheDirectoryPath }
        set { cacheDirectoryPath = newValue }
    }

    var resolvedCachePath: String {
        StorageManager(rootPath: configStore.storageRootPath).actionsCacheDirectory.path
    }

    var storageUsageDescription: String {
        let storage = StorageManager(rootPath: configStore.storageRootPath)
        let used = (try? storage.totalManagedSizeBytes()) ?? 0
        let free = storage.availableCapacityBytes()
        if let free {
            return "\(formatBytes(used)) used, \(formatBytes(free)) available"
        }
        return "\(formatBytes(used)) used"
    }

    var storageWarning: String? {
        StorageManager(rootPath: configStore.storageRootPath)
            .storageWarning(minimumFreeBytes: 25 * 1024 * 1024 * 1024)
    }

    func clearCache() {
        let manager = CacheManager(storage: StorageManager(rootPath: configStore.storageRootPath))
        do {
            try manager.clear()
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
            Log.cache.info("Storage cleanup completed from settings")
        } catch {
            Log.cache.error("Failed to clean storage: \(error.localizedDescription)")
        }
    }

    // MARK: - Validation

    func validateConfiguration() -> [String] {
        var issues: [String] = []
        if configStore.organizations.isEmpty {
            issues.append("No organizations configured")
        }
        let enabled = configStore.organizations.filter(\.isEnabled)
        if enabled.isEmpty && !configStore.organizations.isEmpty {
            issues.append("All organizations are disabled")
        }
        for org in enabled {
            if org.appId.isEmpty {
                issues.append("\(org.name): GitHub App ID is not configured")
            }
            if !configStore.hasPrivateKey(for: org) {
                issues.append("\(org.name): Private key is not imported")
            }
        }
        return issues
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
