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
        get { configStore.cacheDirectoryPath }
        set {
            configStore.cacheDirectoryPath = newValue
            configStore.save()
        }
    }

    var resolvedCachePath: String {
        let base = configStore.cacheDirectoryPath
        return URL(fileURLWithPath: base).appendingPathComponent("actions-cache").path
    }

    func clearCache() {
        let manager = CacheManager(cacheDirectoryPath: configStore.cacheDirectoryPath)
        do {
            try manager.clear()
            Log.cache.info("Cache cleared from settings")
        } catch {
            Log.cache.error("Failed to clear cache: \(error.localizedDescription)")
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
