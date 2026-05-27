import Foundation

struct VMControlConfiguration: Codable, Equatable, Sendable {
    static let defaultPort = 9473
    static let loopbackHost = "127.0.0.1"

    var isEnabled: Bool = false
    var port: Int = Self.defaultPort
    var authToken: String = ""

    var normalizedPort: UInt16 {
        UInt16(clamping: min(max(port, 1024), 65_535))
    }

    var baseURL: String {
        "http://\(Self.loopbackHost):\(normalizedPort)"
    }

    mutating func ensureAuthToken() {
        if authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            authToken = UUID().uuidString
        }
    }

    mutating func rotateAuthToken() {
        authToken = UUID().uuidString
    }
}
