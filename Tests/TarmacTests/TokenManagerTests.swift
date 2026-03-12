import Testing
import Foundation
import Security
@testable import Tarmac

@Suite("TokenManager")
struct TokenManagerTests {
    private func makeTestKeyData() throws -> Data {
        try TestFactories.makeTestKeyData()
    }

    @Test("Cached token is returned without API call")
    func cachedTokenReturned() async throws {
        let futureDate = Date().addingTimeInterval(3600)
        let iso8601 = ISO8601DateFormatter().string(from: futureDate)

        let client = JSONDecodingClient(
            responseJSON: """
            {"token":"ghs_cached_test","expires_at":"\(iso8601)"}
            """.data(using: .utf8)!
        )

        let keyData = try makeTestKeyData()
        let org = TestFactories.makeOrg()

        let manager = TokenManager(client: client)

        // First call fetches from API
        let token1 = try await manager.installationToken(for: org, privateKeyData: keyData)
        #expect(token1 == "ghs_cached_test")

        // Second call should use cache (same token returned)
        let token2 = try await manager.installationToken(for: org, privateKeyData: keyData)
        #expect(token2 == "ghs_cached_test")
        #expect(await client.requestCount == 1) // only one API call
    }

    @Test("Expired token triggers refresh")
    func expiredTokenTriggersRefresh() async throws {
        let futureDate = Date().addingTimeInterval(3600)
        let iso8601 = ISO8601DateFormatter().string(from: futureDate)

        let client = JSONDecodingClient(
            responseJSON: """
            {"token":"ghs_refreshed","expires_at":"\(iso8601)"}
            """.data(using: .utf8)!
        )

        let keyData = try makeTestKeyData()
        let org = TestFactories.makeOrg(installationId: 99)

        let manager = TokenManager(client: client)

        let token = try await manager.installationToken(for: org, privateKeyData: keyData)
        #expect(token == "ghs_refreshed")
        #expect(await client.requestCount == 1)
    }

    @Test("Different installations trigger separate API calls")
    func differentInstallations() async throws {
        let futureDate = Date().addingTimeInterval(3600)
        let iso8601 = ISO8601DateFormatter().string(from: futureDate)

        let client = JSONDecodingClient(
            responseJSON: """
            {"token":"ghs_multi","expires_at":"\(iso8601)"}
            """.data(using: .utf8)!
        )

        let keyData = try makeTestKeyData()
        let orgA = TestFactories.makeOrg(name: "org-a", installationId: 100)
        let orgB = TestFactories.makeOrg(name: "org-b", installationId: 200)

        let manager = TokenManager(client: client)

        _ = try await manager.installationToken(for: orgA, privateKeyData: keyData)
        _ = try await manager.installationToken(for: orgB, privateKeyData: keyData)
        #expect(await client.requestCount == 2)
    }
}

/// A test client that decodes JSON responses, allowing private Decodable types to be returned correctly.
private actor JSONDecodingClient: GitHubClientProtocol {
    let responseJSON: Data
    private(set) var requestCount = 0

    init(responseJSON: Data) {
        self.responseJSON = responseJSON
    }

    nonisolated func request<T: Decodable & Sendable>(
        method: String, path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String],
        timeoutInterval: TimeInterval
    ) async throws -> T {
        await incrementCount()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: responseJSON)
    }

    nonisolated func requestRaw(
        method: String, path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String],
        timeoutInterval: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        await incrementCount()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (responseJSON, response)
    }

    private func incrementCount() {
        requestCount += 1
    }
}
