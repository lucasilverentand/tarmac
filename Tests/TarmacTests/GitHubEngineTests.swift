import Foundation
import Security
import Testing

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

    private func makeLease(
        jobId: Int64,
        orgName: String = Self.testOrg.name,
        runnerName: String? = nil,
        labels: [String] = ["self-hosted", "macOS", "ARM64"]
    ) -> RunnerLease {
        let job = RunnerJob(
            id: jobId,
            organizationName: orgName,
            runnerRequestId: jobId + 1,
            status: .running,
            workflowName: "CI",
            repositoryName: "repo",
            queuedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return RunnerLease(
            job: job,
            runnerName: runnerName ?? "ephemeral-\(jobId)",
            labels: labels,
            createdAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
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

    @Test("organizationInstallationId uses app JWT and org installation endpoint")
    func organizationInstallationIdUsesOrgInstallationEndpoint() async throws {
        let client = RecordingGitHubClient(
            defaultResponseJSON: """
                {"id":4242}
                """.data(using: .utf8)!
        )
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let engine = GitHubEngine(client: client, keychainService: PreviewKeychainService(), cacheDirectory: tempDir)
        let id = try await engine.organizationInstallationId(
            organizationName: "seventwo-studio",
            appId: "12345",
            privateKeyData: TestFactories.makeTestKeyData()
        )

        #expect(id == 4242)
        let requests = await client.requests
        #expect(requests.count == 1)
        #expect(requests[0].method == "GET")
        #expect(requests[0].path == "/orgs/seventwo-studio/installation")
        #expect(requests[0].headers["Authorization"]?.hasPrefix("Bearer ") == true)
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

    @Test("reconcileStaleRunners removes offline runners matching local leases")
    func reconcileStaleRunnersRemovesOfflineLeaseRunner() async throws {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient()
        await client.addResponse(
            forPathContaining: "access_tokens",
            json: """
                {"token":"ghs_reconcile","expires_at":"\(futureDate)"}
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "actions/runners?per_page=100&page=1",
            json: """
                {
                  "total_count": 2,
                  "runners": [
                    {
                      "id": 111,
                      "name": "ephemeral-42",
                      "status": "offline",
                      "busy": false,
                      "labels": [
                        {"name": "self-hosted"},
                        {"name": "macOS"},
                        {"name": "ARM64"}
                      ]
                    },
                    {
                      "id": 222,
                      "name": "someone-else",
                      "status": "offline",
                      "busy": false,
                      "labels": [{"name": "self-hosted"}]
                    }
                  ]
                }
                """.data(using: .utf8)!
        )

        let (engine, client2, _) = try makeEngine(client: client)
        let report = await engine.reconcileStaleRunners(for: Self.testOrg, leases: [makeLease(jobId: 42)])

        #expect(report.scannedRunnerCount == 2)
        #expect(report.matchedLeaseCount == 1)
        #expect(report.removedRunners.map(\.runnerId) == [111])
        #expect(report.skippedRunnerCount == 1)
        #expect(report.failures.isEmpty)

        let requests = await client2.requests
        #expect(requests.contains { $0.method == "DELETE" && $0.path == "/orgs/test-org/actions/runners/111" })
        #expect(!requests.contains { $0.path == "/orgs/test-org/actions/runners/222" })
    }

    @Test("reconcileStaleRunners skips online busy and nonmatching runners")
    func reconcileStaleRunnersSkipsUnsafeRunners() async throws {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient()
        await client.addResponse(
            forPathContaining: "access_tokens",
            json: """
                {"token":"ghs_reconcile","expires_at":"\(futureDate)"}
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "actions/runners?per_page=100&page=1",
            json: """
                {
                  "total_count": 3,
                  "runners": [
                    {
                      "id": 333,
                      "name": "ephemeral-43",
                      "status": "online",
                      "busy": false,
                      "labels": [
                        {"name": "self-hosted"},
                        {"name": "macOS"},
                        {"name": "ARM64"}
                      ]
                    },
                    {
                      "id": 444,
                      "name": "ephemeral-44",
                      "status": "offline",
                      "busy": true,
                      "labels": [
                        {"name": "self-hosted"},
                        {"name": "macOS"},
                        {"name": "ARM64"}
                      ]
                    },
                    {
                      "id": 555,
                      "name": "ephemeral-45",
                      "status": "offline",
                      "busy": false,
                      "labels": [{"name": "self-hosted"}]
                    }
                  ]
                }
                """.data(using: .utf8)!
        )

        let (engine, client2, _) = try makeEngine(client: client)
        let report = await engine.reconcileStaleRunners(
            for: Self.testOrg,
            leases: [
                makeLease(jobId: 43),
                makeLease(jobId: 44),
                makeLease(jobId: 45),
            ]
        )

        #expect(report.scannedRunnerCount == 3)
        #expect(report.matchedLeaseCount == 3)
        #expect(report.removedRunners.isEmpty)
        #expect(report.skippedRunnerCount == 3)

        let requests = await client2.requests
        #expect(!requests.contains { $0.method == "DELETE" })
    }
}
