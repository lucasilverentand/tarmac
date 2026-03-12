import Testing
import Foundation
import Security
@testable import Tarmac

@Suite("GitHubEngine")
struct GitHubEngineTests {
    /// The stable org used across tests — created once so UUID stays consistent with keychain
    private static let testOrg = TestFactories.makeOrg()

    private func makeEngine(
        client: RecordingGitHubClient
    ) throws -> (GitHubEngine, RecordingGitHubClient, PreviewKeychainService) {
        let keychain = PreviewKeychainService()
        let keyData = try TestFactories.makeTestKeyData()
        _ = keychain.save(key: Self.testOrg.privateKeyKeychainKey, data: keyData)

        let tempDir = try TestFactories.makeTempDir()
        let engine = GitHubEngine(
            client: client,
            keychainService: keychain,
            cacheDirectory: tempDir
        )
        return (engine, client, keychain)
    }

    @Test("installationToken returns valid token")
    func installationTokenReturnsToken() async throws {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient(
            defaultResponseJSON: """
            {"token":"ghs_test123","expires_at":"\(futureDate)"}
            """.data(using: .utf8)!
        )

        let (engine, _, _) = try makeEngine(client: client)
        let token = try await engine.installationToken(for: Self.testOrg)
        #expect(token == "ghs_test123")
    }

    @Test("Second installationToken call uses cache")
    func installationTokenCached() async throws {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient(
            defaultResponseJSON: """
            {"token":"ghs_cached","expires_at":"\(futureDate)"}
            """.data(using: .utf8)!
        )

        let (engine, client2, _) = try makeEngine(client: client)

        _ = try await engine.installationToken(for: Self.testOrg)
        _ = try await engine.installationToken(for: Self.testOrg)

        let count = await client2.requestCount
        #expect(count == 1)
    }

    @Test("Different installations trigger separate API calls")
    func differentInstallationsSeparateCalls() async throws {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient(
            defaultResponseJSON: """
            {"token":"ghs_multi","expires_at":"\(futureDate)"}
            """.data(using: .utf8)!
        )

        let keychain = PreviewKeychainService()
        let keyData = try TestFactories.makeTestKeyData()

        let org1 = TestFactories.makeOrg(name: "org1", installationId: 100)
        let org2 = TestFactories.makeOrg(name: "org2", installationId: 200)
        _ = keychain.save(key: org1.privateKeyKeychainKey, data: keyData)
        _ = keychain.save(key: org2.privateKeyKeychainKey, data: keyData)

        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }
        let engine = GitHubEngine(client: client, keychainService: keychain, cacheDirectory: tempDir)

        _ = try await engine.installationToken(for: org1)
        _ = try await engine.installationToken(for: org2)

        let count = await client.requestCount
        #expect(count == 2)
    }

    @Test("Missing private key throws TokenError.noPrivateKey")
    func missingPrivateKeyThrows() async throws {
        let client = RecordingGitHubClient()
        let keychain = PreviewKeychainService()

        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let engine = GitHubEngine(
            client: client,
            keychainService: keychain,
            cacheDirectory: tempDir
        )

        await #expect(throws: TokenError.noPrivateKey) {
            _ = try await engine.installationToken(for: Self.testOrg)
        }
    }

    @Test("generateJITConfig returns encoded config from response")
    func generateJITConfigReturns() async throws {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient()
        await client.addResponse(
            forPathContaining: "access_tokens",
            json: """
            {"token":"ghs_jit","expires_at":"\(futureDate)"}
            """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "generate-jitconfig",
            json: """
            {"encoded_jit_config":"base64-jit-data"}
            """.data(using: .utf8)!
        )

        let (engine, _, _) = try makeEngine(client: client)

        let config = try await engine.generateJITConfig(for: Self.testOrg, runnerName: "runner-1")
        #expect(config == "base64-jit-data")
    }

    @Test("generateJITConfig passes org labels in request body")
    func generateJITConfigPassesLabels() async throws {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient()
        await client.addResponse(
            forPathContaining: "access_tokens",
            json: """
            {"token":"ghs_labels","expires_at":"\(futureDate)"}
            """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "generate-jitconfig",
            json: """
            {"encoded_jit_config":"cfg"}
            """.data(using: .utf8)!
        )

        let (engine, client2, _) = try makeEngine(client: client)

        _ = try await engine.generateJITConfig(for: Self.testOrg, runnerName: "r1")

        let requests = await client2.requests
        let jitRequest = requests.first { $0.path.contains("generate-jitconfig") }
        #expect(jitRequest != nil)
    }
}
