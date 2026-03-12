import Foundation

final class PreviewKeychainService: KeychainServiceProtocol, @unchecked Sendable {
    private var store: [String: Data] = [:]

    func save(key: String, data: Data) -> Bool {
        store[key] = data
        return true
    }

    func load(key: String) -> Data? {
        store[key]
    }

    func delete(key: String) -> Bool {
        store.removeValue(forKey: key) != nil
    }
}
