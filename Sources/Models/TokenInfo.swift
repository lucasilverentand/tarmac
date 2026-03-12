import Foundation

struct TokenInfo: Sendable {
    let token: String
    let expiresAt: Date

    var isExpired: Bool {
        Date() >= expiresAt
    }

    var isExpiringSoon: Bool {
        Date().addingTimeInterval(60) >= expiresAt
    }
}
