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

    @Test("enterpriseInstallationId uses app JWT and enterprise installation endpoint")
    func enterpriseInstallationIdUsesEnterpriseInstallationEndpoint() async throws {
        let client = RecordingGitHubClient(
            defaultResponseJSON: """
                {"id":9876}
                """.data(using: .utf8)!
        )
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let engine = GitHubEngine(client: client, keychainService: PreviewKeychainService(), cacheDirectory: tempDir)
        let id = try await engine.enterpriseInstallationId(
            enterpriseSlug: "acme",
            appId: "12345",
            privateKeyData: TestFactories.makeTestKeyData()
        )

        #expect(id == 9876)
        let requests = await client.requests
        #expect(requests.count == 1)
        #expect(requests[0].method == "GET")
        #expect(requests[0].path == "/enterprises/acme/installation")
        #expect(requests[0].headers["Authorization"]?.hasPrefix("Bearer ") == true)
        #expect(requests[0].headers["X-GitHub-Api-Version"] == "2026-03-10")
    }

    @Test("listEnterpriseInstallableOrganizations uses enterprise installation token")
    func listEnterpriseInstallableOrganizationsUsesEnterpriseInstallationToken() async throws {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient()
        await client.addResponse(
            forPathContaining: "access_tokens",
            json: """
                {"token":"ghs_enterprise","expires_at":"\(futureDate)"}
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "installable_organizations",
            json: """
                [
                  {"id":1,"login":"one"},
                  {"id":2,"login":"two"}
                ]
                """.data(using: .utf8)!
        )
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let engine = GitHubEngine(client: client, keychainService: PreviewKeychainService(), cacheDirectory: tempDir)
        let organizations = try await engine.listEnterpriseInstallableOrganizations(
            enterpriseSlug: "acme",
            enterpriseInstallationId: 9876,
            appId: "12345",
            privateKeyData: TestFactories.makeTestKeyData()
        )

        #expect(organizations.map(\.login) == ["one", "two"])
        let requests = await client.requests
        #expect(requests[0].path == "/app/installations/9876/access_tokens")
        #expect(requests[1].path == "/enterprises/acme/apps/installable_organizations?per_page=100&page=1")
        #expect(requests[1].headers["Authorization"] == "Bearer ghs_enterprise")
        #expect(requests[1].headers["X-GitHub-Api-Version"] == "2026-03-10")
    }

    @Test("installEnterpriseGitHubApp posts selected organization install request")
    func installEnterpriseGitHubAppPostsInstallRequest() async throws {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient()
        await client.addResponse(
            forPathContaining: "access_tokens",
            json: """
                {"token":"ghs_enterprise","expires_at":"\(futureDate)"}
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "/enterprises/acme/apps/organizations/octo-org/installations",
            json: """
                {"id":4242,"app_slug":"seventwo/tarmac","repository_selection":"none"}
                """.data(using: .utf8)!
        )
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        let engine = GitHubEngine(client: client, keychainService: PreviewKeychainService(), cacheDirectory: tempDir)
        let installation = try await engine.installEnterpriseGitHubApp(
            enterpriseSlug: "acme",
            organizationName: "octo-org",
            enterpriseInstallationId: 9876,
            appId: "12345",
            clientId: "Iv1.client",
            privateKeyData: TestFactories.makeTestKeyData(),
            repositorySelection: .none,
            repositories: []
        )

        #expect(installation.id == 4242)
        let requests = await client.requests
        let installRequest = try #require(requests.last)
        #expect(installRequest.method == "POST")
        #expect(installRequest.path == "/enterprises/acme/apps/organizations/octo-org/installations")
        #expect(installRequest.headers["Authorization"] == "Bearer ghs_enterprise")
        #expect(installRequest.headers["X-GitHub-Api-Version"] == "2026-03-10")

        struct InstallBody: Decodable {
            let clientId: String
            let repositorySelection: String

            enum CodingKeys: String, CodingKey {
                case clientId = "client_id"
                case repositorySelection = "repository_selection"
            }
        }
        let bodyData = try #require(installRequest.bodyData)
        let body = try JSONDecoder().decode(InstallBody.self, from: bodyData)
        #expect(body.clientId == "Iv1.client")
        #expect(body.repositorySelection == "none")
    }

    @Test("ensureScaleSet reuses an existing scale set matched by name and does not create one")
    func ensureScaleSetReusesExisting() async throws {
        let client = RecordingGitHubClient()
        await client.addRawResponse(
            forPathContaining: "/actions/runner-scale-sets",
            method: "GET",
            statusCode: 200,
            json: """
                {"count":1,"value":[{"id":5,"name":"tarmac-macos","runnerGroupId":1}]}
                """.data(using: .utf8)!
        )
        let (engine, _, _) = try makeEngine(client: client)

        let scaleSet = try await engine.ensureScaleSet(
            accountPath: "/orgs/test-org",
            token: "tok",
            name: "tarmac-macos",
            runnerGroupId: 1,
            labels: ["self-hosted"]
        )

        #expect(scaleSet.id == 5)
        let requests = await client.requests
        #expect(requests.allSatisfy { $0.method == "GET" })
        #expect(!requests.contains { $0.method == "POST" })
    }

    @Test("ensureScaleSet creates a scale set when none matches the name")
    func ensureScaleSetCreatesWhenMissing() async throws {
        let client = RecordingGitHubClient()
        await client.addRawResponse(
            forPathContaining: "/actions/runner-scale-sets",
            method: "GET",
            statusCode: 200,
            json: """
                {"count":0,"value":[]}
                """.data(using: .utf8)!
        )
        await client.addRawResponse(
            forPathContaining: "/actions/runner-scale-sets",
            method: "POST",
            statusCode: 201,
            json: """
                {"id":11,"name":"tarmac-macos","runnerGroupId":1}
                """.data(using: .utf8)!
        )
        let (engine, _, _) = try makeEngine(client: client)

        let scaleSet = try await engine.ensureScaleSet(
            accountPath: "/orgs/test-org",
            token: "tok",
            name: "tarmac-macos",
            runnerGroupId: 1,
            labels: ["self-hosted"]
        )

        #expect(scaleSet.id == 11)
        let requests = await client.requests
        #expect(requests.contains { $0.method == "POST" && $0.path == "/orgs/test-org/actions/runner-scale-sets" })
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

    @Test("queuedWorkflowJobs lists queued matching self-hosted jobs for a repository")
    func queuedWorkflowJobsListsMatchingJobs() async throws {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient()
        await client.addResponse(
            forPathContaining: "access_tokens",
            json: """
                {"token":"ghs_jobs","expires_at":"\(futureDate)"}
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "/repos/test-org/allowed-repo/actions/runs?status=queued&per_page=20",
            json: """
                {"workflow_runs":[{"id":26883117168}]}
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "/repos/test-org/allowed-repo/actions/runs/26883117168/jobs?per_page=100",
            json: """
                {
                  "jobs": [
                    {
                      "id": 79288038719,
                      "run_id": 26883117168,
                      "name": "build",
                      "status": "queued",
                      "conclusion": null,
                      "labels": ["self-hosted", "macOS", "ARM64"],
                      "started_at": "2026-06-03T11:56:03Z",
                      "html_url": "https://github.com/seventwo-studio/tarmac-e2e/actions/runs/26883117168/job/79288038719"
                    },
                    {
                      "id": 79288038720,
                      "run_id": 26883117168,
                      "name": "linux",
                      "status": "queued",
                      "conclusion": null,
                      "labels": ["ubuntu-latest"],
                      "started_at": "2026-06-03T11:56:04Z",
                      "html_url": null
                    }
                  ]
                }
                """.data(using: .utf8)!
        )

        let (engine, client2, _) = try makeEngine(client: client)
        let jobs = try await engine.queuedWorkflowJobs(for: Self.testOrg, repositoryName: "allowed-repo")

        #expect(jobs.count == 1)
        #expect(jobs.first?.id == 79288038719)
        #expect(jobs.first?.runId == 26883117168)
        #expect(jobs.first?.name == "build")
        #expect(jobs.first?.repositoryName == "allowed-repo")
        #expect(jobs.first?.labels == ["self-hosted", "macOS", "ARM64"])

        let requests = await client2.requests
        #expect(requests.contains { $0.path == "/repos/test-org/allowed-repo/actions/runs?status=queued&per_page=20" })
        #expect(
            requests.contains {
                $0.path == "/repos/test-org/allowed-repo/actions/runs/26883117168/jobs?per_page=100"
            }
        )
    }

    @Test("queuedWorkflowJobs ignores completed jobs and jobs without required labels")
    func queuedWorkflowJobsFiltersNonMatchingJobs() async throws {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient()
        await client.addResponse(
            forPathContaining: "access_tokens",
            json: """
                {"token":"ghs_jobs","expires_at":"\(futureDate)"}
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "/repos/test-org/allowed-repo/actions/runs?status=queued&per_page=20",
            json: """
                {"workflow_runs":[{"id":100}]}
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "/repos/test-org/allowed-repo/actions/runs/100/jobs?per_page=100",
            json: """
                {
                  "jobs": [
                    {
                      "id": 1,
                      "run_id": 100,
                      "name": "done",
                      "status": "completed",
                      "conclusion": "success",
                      "labels": ["self-hosted", "macOS", "ARM64"],
                      "started_at": "2026-06-03T11:56:03Z",
                      "html_url": null
                    },
                    {
                      "id": 2,
                      "run_id": 100,
                      "name": "wrong labels",
                      "status": "queued",
                      "conclusion": null,
                      "labels": ["self-hosted", "Linux", "X64"],
                      "started_at": "2026-06-03T11:56:04Z",
                      "html_url": null
                    }
                  ]
                }
                """.data(using: .utf8)!
        )

        let (engine, _, _) = try makeEngine(client: client)
        let jobs = try await engine.queuedWorkflowJobs(for: Self.testOrg, repositoryName: "allowed-repo")

        #expect(jobs.isEmpty)
    }

    @Test("queuedWorkflowJobs returns matching jobs in queue order across runs")
    func queuedWorkflowJobsSortsAcrossRuns() async throws {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient()
        await client.addResponse(
            forPathContaining: "access_tokens",
            json: """
                {"token":"ghs_jobs","expires_at":"\(futureDate)"}
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "/repos/test-org/allowed-repo/actions/runs?status=queued&per_page=20",
            json: """
                {
                  "workflow_runs": [
                    {"id": 200, "created_at": "2026-06-03T12:00:00Z"},
                    {"id": 100, "created_at": "2026-06-03T11:59:00Z"}
                  ]
                }
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "/repos/test-org/allowed-repo/actions/runs/200/jobs?per_page=100",
            json: """
                {
                  "jobs": [
                    {
                      "id": 20,
                      "run_id": 200,
                      "name": "later",
                      "status": "queued",
                      "conclusion": null,
                      "labels": ["self-hosted", "macOS", "ARM64"],
                      "started_at": "2026-06-03T12:00:00Z",
                      "html_url": null
                    }
                  ]
                }
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "/repos/test-org/allowed-repo/actions/runs/100/jobs?per_page=100",
            json: """
                {
                  "jobs": [
                    {
                      "id": 10,
                      "run_id": 100,
                      "name": "earlier",
                      "status": "queued",
                      "conclusion": null,
                      "labels": ["self-hosted", "macOS", "ARM64"],
                      "started_at": "2026-06-03T11:59:00Z",
                      "html_url": null
                    }
                  ]
                }
                """.data(using: .utf8)!
        )

        let (engine, _, _) = try makeEngine(client: client)
        let jobs = try await engine.queuedWorkflowJobs(for: Self.testOrg, repositoryName: "allowed-repo")

        #expect(jobs.map(\.id) == [10, 20])
        #expect(jobs.map(\.runId) == [100, 200])
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

    @Test("enterprise authorizationToken loads access token without app token request")
    func enterpriseAuthorizationTokenUsesSavedAccessToken() async throws {
        let client = RecordingGitHubClient()
        let keychain = PreviewKeychainService()
        let org = TestFactories.makeOrg(name: "acme", accountType: .enterprise)
        _ = keychain.save(key: org.accessTokenKeychainKey, data: Data("github_pat_enterprise".utf8))

        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }
        let engine = GitHubEngine(client: client, keychainService: keychain, cacheDirectory: tempDir)

        let token = try await engine.authorizationToken(for: org)

        #expect(token == "github_pat_enterprise")
        #expect(await client.requestCount == 0)
    }

    @Test("enterprise authorizationToken requires saved access token")
    func enterpriseAuthorizationTokenRequiresToken() async throws {
        let client = RecordingGitHubClient()
        let keychain = PreviewKeychainService()
        let org = TestFactories.makeOrg(name: "acme", accountType: .enterprise)

        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }
        let engine = GitHubEngine(client: client, keychainService: keychain, cacheDirectory: tempDir)

        await #expect(throws: GitHubEnterpriseTokenError.noAccessToken) {
            _ = try await engine.authorizationToken(for: org)
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

    @Test("generateRunnerGuestConfig falls back to registration token when JIT returns 404")
    func generateRunnerGuestConfigFallsBackOnJIT404() async throws {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient()
        await client.addResponse(
            forPathContaining: "access_tokens",
            json: """
                {"token":"ghs_fallback","expires_at":"\(futureDate)"}
                """.data(using: .utf8)!
        )
        await client.addRawResponse(
            forPathContaining: "generate-jitconfig",
            statusCode: 404,
            json: """
                {"message":"Not Found"}
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "registration-token",
            json: """
                {"token":"REGTOKEN","expires_at":"\(futureDate)"}
                """.data(using: .utf8)!
        )

        let (engine, client2, _) = try makeEngine(client: client)

        let config = try await engine.generateRunnerGuestConfig(for: Self.testOrg, runnerName: "ephemeral-9")

        guard case .registrationToken(let url, let token, let runnerName, let labels) = config else {
            Issue.record("Expected registration token fallback config")
            return
        }
        #expect(url == "https://github.com/orgs/test-org")
        #expect(token == "REGTOKEN")
        #expect(runnerName == "ephemeral-9")
        #expect(labels == Self.testOrg.runnerLabels)

        let requests = await client2.requests
        #expect(requests.contains { $0.path.contains("generate-jitconfig") })
        #expect(requests.contains { $0.path.contains("registration-token") })
    }

    @Test("generateRunnerGuestConfig uses org runner endpoints for repository polling")
    func generateRunnerGuestConfigUsesOrgRunnerEndpointsForRepositoryPolling() async throws {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let repositoryOrg = Organization(
            id: Self.testOrg.id,
            name: "lucasilverentand",
            appId: Self.testOrg.appId,
            installationId: Self.testOrg.installationId,
            scaleSetId: nil,
            filterMode: .include,
            filteredRepositories: ["mac-ephemeral-runner"]
        )
        let client = RecordingGitHubClient()
        await client.addResponse(
            forPathContaining: "access_tokens",
            json: """
                {"token":"ghs_repo","expires_at":"\(futureDate)"}
                """.data(using: .utf8)!
        )
        await client.addRawResponse(
            forPathContaining: "generate-jitconfig",
            statusCode: 404,
            json: """
                {"message":"Not Found"}
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "registration-token",
            json: """
                {"token":"REPOREGTOKEN","expires_at":"\(futureDate)"}
                """.data(using: .utf8)!
        )

        let (engine, client2, _) = try makeEngine(client: client)

        let config = try await engine.generateRunnerGuestConfig(
            for: repositoryOrg,
            runnerName: "ephemeral-9",
            repositoryName: "mac-ephemeral-runner"
        )

        guard case .registrationToken(let url, let token, let runnerName, let labels) = config else {
            Issue.record("Expected repository registration token fallback config")
            return
        }
        #expect(url == "https://github.com/orgs/lucasilverentand")
        #expect(token == "REPOREGTOKEN")
        #expect(runnerName == "ephemeral-9")
        #expect(labels == repositoryOrg.runnerLabels)

        let requests = await client2.requests
        #expect(
            requests.contains {
                $0.path == "/orgs/lucasilverentand/actions/runners/generate-jitconfig"
            }
        )
        #expect(
            requests.contains {
                $0.path == "/orgs/lucasilverentand/actions/runners/registration-token"
            }
        )
    }

    @Test("generateRunnerGuestConfig rethrows non-fallback JIT failures")
    func generateRunnerGuestConfigRethrowsAuthFailure() async throws {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient()
        await client.addResponse(
            forPathContaining: "access_tokens",
            json: """
                {"token":"ghs_auth","expires_at":"\(futureDate)"}
                """.data(using: .utf8)!
        )
        await client.addRawResponse(
            forPathContaining: "generate-jitconfig",
            statusCode: 401,
            json: """
                {"message":"Bad credentials"}
                """.data(using: .utf8)!
        )

        let (engine, _, _) = try makeEngine(client: client)

        await #expect(throws: GitHubAPIError.self) {
            _ = try await engine.generateRunnerGuestConfig(for: Self.testOrg, runnerName: "ephemeral-9")
        }
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
