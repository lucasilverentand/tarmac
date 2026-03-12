import Foundation
import Testing

@testable import Tarmac

@Suite("KeychainService")
struct KeychainServiceTests {
    /// Use a unique key prefix per test to avoid collisions with other test runs.
    private func uniqueKey(_ base: String = "test") -> String {
        "tarmac-test-\(UUID().uuidString)-\(base)"
    }

    private let service = KeychainService()

    @Test("Save and load round-trip")
    func saveAndLoad() {
        let key = uniqueKey()
        defer { _ = service.delete(key: key) }

        let data = "hello-keychain".data(using: .utf8)!
        let saved = service.save(key: key, data: data)
        #expect(saved)

        let loaded = service.load(key: key)
        #expect(loaded == data)
    }

    @Test("Load missing key returns nil")
    func loadMissing() {
        let key = uniqueKey("missing")
        let loaded = service.load(key: key)
        #expect(loaded == nil)
    }

    @Test("Delete existing key succeeds")
    func deleteExisting() {
        let key = uniqueKey()
        let data = "to-delete".data(using: .utf8)!
        _ = service.save(key: key, data: data)

        let deleted = service.delete(key: key)
        #expect(deleted)

        let loaded = service.load(key: key)
        #expect(loaded == nil)
    }

    @Test("Delete missing key returns true (errSecItemNotFound is acceptable)")
    func deleteMissing() {
        let key = uniqueKey("never-saved")
        let result = service.delete(key: key)
        // KeychainService.delete returns true for both errSecSuccess and errSecItemNotFound
        #expect(result)
    }

    @Test("Overwrite existing key with new data")
    func overwriteExisting() {
        let key = uniqueKey()
        defer { _ = service.delete(key: key) }

        let data1 = "first-value".data(using: .utf8)!
        let data2 = "second-value".data(using: .utf8)!

        _ = service.save(key: key, data: data1)
        let saved = service.save(key: key, data: data2)
        #expect(saved)

        let loaded = service.load(key: key)
        #expect(loaded == data2)
    }
}
