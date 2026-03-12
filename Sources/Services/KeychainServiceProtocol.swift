import Foundation

protocol KeychainServiceProtocol: Sendable {
    func save(key: String, data: Data) -> Bool
    func load(key: String) -> Data?
    func delete(key: String) -> Bool
}
