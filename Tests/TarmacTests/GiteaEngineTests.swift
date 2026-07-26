import Foundation
import Testing

@testable import Tarmac

@Suite("GiteaEngine", .serialized)
struct GiteaEngineTests {
    @Test("Repository polling deduplicates queued demand and filters labels")
    func repositoryPolling() async throws {
        MockURLProtocol.reset()
        let jobs =
            #"{"jobs":[{"id":42,"run_id":7,"name":"build","status":"queued","labels":["macos-arm64"],"created_at":"2026-07-16T00:00:00Z","html_url":"https://git.example.test/owner/repo/actions/runs/7/jobs/42"},{"id":43,"status":"queued","labels":["ubuntu-latest"]}],"total_count":2}"#
        MockURLProtocol.addHandler(
            matching: { request in
                request.url?.path == "/api/v1/repos/owner/repo/actions/jobs"
            },
            responseData: Data(jobs.utf8)
        )

        let account = makeAccount(scope: .repository)
        let engine = makeEngine(account: account)
        let result = try await engine.queuedJobs(for: account)

        #expect(result.count == 1)
        #expect(result.first?.key == ProviderJobKey(accountID: account.id, remoteJobID: "42"))
        #expect(result.first?.repositoryName == "owner/repo")
    }

    @Test("Claim correlation rejects multiple in-progress jobs for one runner")
    func ambiguousClaim() async {
        MockURLProtocol.reset()
        let jobs =
            #"{"jobs":[{"id":42,"status":"in_progress","labels":["macos-arm64"],"runner_name":"tarmac-test"},{"id":43,"status":"in_progress","labels":["macos-arm64"],"runner_name":"tarmac-test"}],"total_count":2}"#
        MockURLProtocol.addHandler(
            matching: { request in
                request.url?.path == "/api/v1/repos/owner/repo/actions/jobs"
            },
            responseData: Data(jobs.utf8)
        )

        let account = makeAccount(scope: .repository)
        let engine = makeEngine(account: account)
        await #expect(throws: GiteaAPIError.self) {
            _ = try await engine.claimedJob(for: account, runnerName: "tarmac-test")
        }
    }

    @Test("Instance scope uses administrator jobs endpoint")
    func instanceScope() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.addHandler(
            matching: { request in
                request.url?.path == "/api/v1/admin/actions/jobs"
            },
            responseData: Data(#"{"jobs":[],"total_count":0}"#.utf8)
        )

        let account = makeAccount(scope: .instance)
        let jobs = try await makeEngine(account: account).queuedJobs(for: account)
        #expect(jobs.isEmpty)
    }

    @Test("Terminal job conclusion is authoritative")
    func terminalResult() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.addHandler(
            forPathContaining: "/api/v1/repos/owner/repo/actions/jobs/42",
            responseData: Data(#"{"id":42,"status":"completed","conclusion":"success","labels":["macos-arm64"]}"#.utf8)
        )

        let account = makeAccount(scope: .repository)
        let result = try await makeEngine(account: account).terminalResult(
            for: account,
            remoteJobID: "42",
            repositoryName: "owner/repo"
        )
        #expect(result == .success)
    }

    @Test("Startup cleanup removes only offline Tarmac runners")
    func staleRunnerCleanup() async throws {
        MockURLProtocol.reset()
        let runners =
            #"{"runners":[{"id":1,"name":"tarmac-gitea-42","status":"offline","busy":false,"labels":[]},{"id":2,"name":"someone-else","status":"offline","busy":false,"labels":[]},{"id":3,"name":"tarmac-gitea-43","status":"online","busy":false,"labels":[]}]}"#
        MockURLProtocol.addHandler(
            matching: { request in
                request.httpMethod == "GET" && request.url?.path == "/api/v1/repos/owner/repo/actions/runners"
            },
            responseData: Data(runners.utf8)
        )
        MockURLProtocol.addHandler(
            matching: { request in
                request.httpMethod == "DELETE" && request.url?.path == "/api/v1/repos/owner/repo/actions/runners/1"
            },
            statusCode: 204
        )

        let account = makeAccount(scope: .repository)
        let report = await makeEngine(account: account).reconcileStaleRunners(for: account, leases: [])
        #expect(report.scannedRunnerCount == 3)
        #expect(report.removedRunners.map(\.runnerName) == ["tarmac-gitea-42"])
        #expect(report.skippedRunnerCount == 2)
        #expect(report.failures.isEmpty)
    }

    private func makeAccount(scope: RunnerAccountScope) -> RunnerAccount {
        Organization(
            provider: .gitea,
            serverURL: "https://git.example.test",
            scope: scope,
            name: scope == .instance ? "Local Gitea" : "owner",
            accountType: scope == .repository ? .repository : .organization,
            repositoryName: scope == .repository ? "repo" : nil,
            credentialMode: .accessToken,
            appId: "",
            installationId: 0,
            labels: ["macos-arm64:host"]
        )
    }

    private func makeEngine(account: RunnerAccount) -> GiteaEngine {
        let keychain = PreviewKeychainService()
        _ = keychain.save(key: account.accessTokenKeychainKey, data: Data("api-token".utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = GiteaClient(instanceURL: account.normalizedServerURL!, session: session)
        let storage = StorageManager(
            rootPath: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).path
        )
        return GiteaEngine(
            client: client,
            keychainService: keychain,
            runnerProvider: GiteaRunnerProvider(storage: storage, session: session)
        )
    }
}
