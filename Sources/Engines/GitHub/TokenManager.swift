import Foundation

actor TokenManager {
    private let client: any GitHubClientProtocol
    private var cachedTokens: [Int: TokenInfo] = [:]  // installationId -> token
    private var jwtCache: [String: TokenInfo] = [:]  // appId -> JWT

    init(client: any GitHubClientProtocol) {
        self.client = client
    }

    func installationToken(for org: Organization, privateKeyData: Data) async throws -> String {
        if let cached = cachedTokens[org.installationId], !cached.isExpiringSoon {
            return cached.token
        }

        let jwt = try generateJWT(appId: org.appId, privateKeyData: privateKeyData)

        let response: InstallationTokenResponse = try await client.request(
            method: "POST",
            path: "/app/installations/\(org.installationId)/access_tokens",
            body: nil as String?,
            headers: ["Authorization": "Bearer \(jwt)"],
            timeoutInterval: 30
        )

        let tokenInfo = TokenInfo(
            token: response.token,
            expiresAt: response.expiresAt
        )
        cachedTokens[org.installationId] = tokenInfo

        Log.token.info("Obtained installation token for \(org.name) (installation \(org.installationId))")
        return response.token
    }

    func invalidateTokens(for installationId: Int) {
        cachedTokens.removeValue(forKey: installationId)
    }

    func invalidateAll() {
        cachedTokens.removeAll()
        jwtCache.removeAll()
    }

    private func generateJWT(appId: String, privateKeyData: Data) throws -> String {
        if let cached = jwtCache[appId], !cached.isExpiringSoon {
            return cached.token
        }

        let generator = JWTGenerator(appId: appId, privateKeyData: privateKeyData)
        let jwt = try generator.generateJWT()

        jwtCache[appId] = TokenInfo(
            token: jwt,
            expiresAt: Date().addingTimeInterval(540)  // 9 minutes (JWT valid for 10)
        )

        return jwt
    }
}

private struct InstallationTokenResponse: Decodable, Sendable {
    let token: String
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

enum TokenError: Error, LocalizedError, Sendable {
    case noPrivateKey
    case noAppId

    var errorDescription: String? {
        switch self {
        case .noPrivateKey: "No GitHub App private key found in Keychain"
        case .noAppId: "No GitHub App ID configured"
        }
    }
}
