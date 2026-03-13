import Foundation

@Observable
@MainActor
final class ConfigStore {
    private let defaults: UserDefaults
    private let keychainService: any KeychainServiceProtocol

    private(set) var organizations: [Organization] = []
    var vmConfiguration: VMConfiguration = VMConfiguration()
    var cacheConfig: CacheConfiguration = CacheConfiguration()
    var baseImagePath: String = ""
    var cacheDirectoryPath: String = ""
    var launchAtLogin: Bool = false

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

    // MARK: - Persistence

    func save() {
        saveOrganizations()
        if let data = try? JSONEncoder().encode(vmConfiguration) {
            defaults.set(data, forKey: "vmConfiguration")
        }
        if let data = try? JSONEncoder().encode(cacheConfig) {
            defaults.set(data, forKey: "cacheConfiguration")
        }
        defaults.set(baseImagePath, forKey: "baseImagePath")
        defaults.set(cacheDirectoryPath, forKey: "cacheDirectoryPath")
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
        baseImagePath = defaults.string(forKey: "baseImagePath") ?? ""
        cacheDirectoryPath = defaults.string(forKey: "cacheDirectoryPath") ?? ""
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")

        if cacheDirectoryPath.isEmpty {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            cacheDirectoryPath = appSupport.appendingPathComponent("Tarmac/Cache").path
        }

        Log.config.debug("Configuration loaded: \(self.organizations.count) organizations")
    }

    private func saveOrganizations() {
        if let data = try? JSONEncoder().encode(organizations) {
            defaults.set(data, forKey: "organizations")
        }
    }
}
