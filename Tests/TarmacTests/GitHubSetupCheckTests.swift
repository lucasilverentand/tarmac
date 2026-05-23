import Foundation
import Testing

@testable import Tarmac

@Suite("GitHubSetupCheck")
struct GitHubSetupCheckTests {
    @Test("ready result exposes advertised labels and runner groups")
    func readyResult() async throws {
        let org = TestFactories.makeOrg(name: "setup-org", scaleSetId: 42)
        let (engine, _) = try await makeEngine(org: org)

        let result = await engine.runSetupCheck(for: org)

        #expect(result.isReady)
        #expect(result.advertisedLabels == ["self-hosted", "macOS", "ARM64"])
        #expect(result.runnerGroupNames == ["Default", "macOS builders"])
    }

    @Test("missing self-hosted label reports label mismatch")
    func missingSelfHostedLabel() async throws {
        let org = TestFactories.makeOrg(name: "setup-org", scaleSetId: 42, labels: ["macOS", "ARM64"])
        let (engine, _) = try await makeEngine(org: org)

        let result = await engine.runSetupCheck(for: org)

        #expect(!result.isReady)
        #expect(result.issues.contains { $0.kind == .labelMismatch })
        #expect(result.statusText.contains("self-hosted"))
    }

    @Test("profile labels are advertised when the image profile is ready")
    func profileLabelsAdvertised() async throws {
        let profile = RunnerImageProfile(
            name: "Xcode 17",
            baseMacOSVersion: "26.0",
            xcodeVersion: "17.0",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            commandLineToolsInstalled: true,
            sdks: [ApplePlatformSDK(platform: .iOS, version: "19.0")],
            simulatorRuntimes: [AppleSimulatorRuntime(platform: .iOS, version: "19.0")],
            capabilities: [.xcode, .iOS],
            preparation: BaseImagePreparation(
                inventory: ToolchainInventory(xcodeLicenseAccepted: true)
            )
        )
        let org = TestFactories.makeOrg(name: "setup-org", scaleSetId: 42, imageProfile: profile)
        let (engine, _) = try await makeEngine(org: org)

        let result = await engine.runSetupCheck(for: org)

        #expect(result.isReady)
        #expect(result.advertisedLabels == ["self-hosted", "macOS", "ARM64", "xcode", "ios"])
    }

    @Test("profile readiness failures block setup checks")
    func profileReadinessFailures() async throws {
        let profile = RunnerImageProfile(
            name: "Incomplete image",
            commandLineToolsInstalled: true,
            capabilities: [.iOS]
        )
        let org = TestFactories.makeOrg(name: "setup-org", scaleSetId: 42, imageProfile: profile)
        let (engine, _) = try await makeEngine(org: org)

        let result = await engine.runSetupCheck(for: org)

        #expect(!result.isReady)
        #expect(result.issues.contains { $0.kind == .imageProfileNotReady && $0.message.contains("iOS SDK") })
    }

    @Test("enterprise account type uses enterprise token and enterprise endpoints")
    func enterpriseAccountUsesEnterpriseToken() async throws {
        let org = TestFactories.makeOrg(name: "example-enterprise", accountType: .enterprise)
        let client = RecordingGitHubClient()
        let keychain = PreviewKeychainService()
        _ = keychain.save(key: org.accessTokenKeychainKey, data: Data("github_pat_enterprise".utf8))
        await client.addResponse(
            forPathContaining: "runner-groups",
            json: """
                {"runner_groups":[{"id":1,"name":"Default"}]}
                """.data(using: .utf8)!
        )
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }
        let engine = GitHubEngine(client: client, keychainService: keychain, cacheDirectory: tempDir)

        let result = await engine.runSetupCheck(for: org)

        #expect(result.isReady)
        let requests = await client.requests
        #expect(requests.allSatisfy { $0.headers["Authorization"] == "Bearer github_pat_enterprise" })
        #expect(requests.contains { $0.path == "/enterprises/example-enterprise/actions/runners/downloads" })
        #expect(requests.contains { $0.path == "/enterprises/example-enterprise/actions/runner-groups" })
        #expect(requests.contains { $0.path == "/enterprises/example-enterprise/actions/runner-scale-sets/42" })
        #expect(!requests.contains { $0.path == "/installation/repositories" })
    }

    @Test("enterprise account type requires an access token")
    func enterpriseAccountRequiresAccessToken() async throws {
        let org = TestFactories.makeOrg(name: "example-enterprise", accountType: .enterprise)
        let client = RecordingGitHubClient()
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }
        let engine = GitHubEngine(client: client, keychainService: PreviewKeychainService(), cacheDirectory: tempDir)

        let result = await engine.runSetupCheck(for: org)

        #expect(!result.isReady)
        #expect(
            result.issues.contains {
                $0.kind == .missingAccessToken && $0.message.contains("Enterprise access token")
            }
        )
        #expect(await client.requestCount == 0)
    }

    @Test("permission and missing scale set failures use GitHub terms")
    func permissionAndMissingScaleSetFailures() async throws {
        let org = TestFactories.makeOrg(name: "setup-org", scaleSetId: 42)
        let client = SetupStatusGitHubClient(statuses: [
            "/orgs/setup-org/actions/runner-groups": 403,
            "/orgs/setup-org/actions/runner-scale-sets/42": 404,
        ])
        let keychain = PreviewKeychainService()
        _ = keychain.save(key: org.privateKeyKeychainKey, data: try TestFactories.makeTestKeyData())
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }
        let engine = GitHubEngine(client: client, keychainService: keychain, cacheDirectory: tempDir)

        let result = await engine.runSetupCheck(for: org)

        #expect(!result.isReady)
        #expect(result.issues.contains { $0.kind == .permissionMissing && $0.message.contains("Runner group access") })
        #expect(
            result.issues.contains {
                $0.kind == .scaleSetUnavailable && $0.message.contains("Runner scale set 42")
            }
        )
    }

    private func makeEngine(org: Organization) async throws -> (GitHubEngine, RecordingGitHubClient) {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient()
        let keychain = PreviewKeychainService()
        _ = keychain.save(key: org.privateKeyKeychainKey, data: try TestFactories.makeTestKeyData())

        await client.addResponse(
            forPathContaining: "access_tokens",
            json: """
                {"token":"ghs_setup","expires_at":"\(futureDate)"}
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "runner-groups",
            json: """
                {"runner_groups":[{"id":1,"name":"Default"},{"id":2,"name":"macOS builders"}]}
                """.data(using: .utf8)!
        )

        let tempDir = try TestFactories.makeTempDir()
        let engine = GitHubEngine(client: client, keychainService: keychain, cacheDirectory: tempDir)
        return (engine, client)
    }
}

private actor SetupStatusGitHubClient: GitHubClientProtocol {
    private let statuses: [String: Int]

    init(statuses: [String: Int]) {
        self.statuses = statuses
    }

    nonisolated func request<T: Decodable & Sendable>(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String],
        timeoutInterval: TimeInterval
    ) async throws -> T {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let data = """
            {"token":"ghs_setup","expires_at":"\(futureDate)"}
            """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    nonisolated func requestRaw(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String],
        timeoutInterval: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        let status = await status(for: path)
        let data = """
            {"runner_groups":[{"id":1,"name":"Default"}]}
            """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com\(path)")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    private func status(for path: String) -> Int {
        statuses.first { path.contains($0.key) }?.value ?? 200
    }
}
