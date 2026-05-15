import Foundation

@Observable
@MainActor
final class ConfigStore {
    private let defaults: UserDefaults
    private let keychainService: any KeychainServiceProtocol

    private(set) var organizations: [Organization] = []
    var vmConfiguration: VMConfiguration = VMConfiguration()
    var cacheConfig: CacheConfiguration = CacheConfiguration()
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
        if let data = try? JSONEncoder().encode(vmConfiguration) {
            defaults.set(data, forKey: "vmConfiguration")
        }
        if let data = try? JSONEncoder().encode(cacheConfig) {
            defaults.set(data, forKey: "cacheConfiguration")
        }
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
}
