import Foundation
import Testing

@testable import Tarmac

@Suite("AppState")
struct AppStateTests {
    @MainActor
    private func makeAppState(
        orgs: [Organization] = [],
        withPrivateKeys: Bool = false,
        hasReadyVM: Bool = true,
        lifecycle: MockVMLifecycle? = nil
    ) async throws -> (AppState, RecordingGitHubClient) {
        let (configStore, _) = TestFactories.makeConfigStore()
        let tempDir = try TestFactories.makeTempDir()

        try configStore.configureStorage(at: tempDir)
        if hasReadyVM {
            try TestFactories.prepareReadyRunnerHostStorage(for: configStore)
        }

        // Add orgs with valid config
        for org in orgs {
            configStore.addOrganization(org)
            if withPrivateKeys {
                let keyData = try TestFactories.makeTestKeyData()
                _ = configStore.savePrivateKey(keyData, for: org)
            }
        }

        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient(
            defaultResponseJSON: """
                {"token":"ghs_test","expires_at":"\(futureDate)"}
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "runner-scale-sets/",
            json: """
                {"id":42,"name":"scale-set"}
                """.data(using: .utf8)!
        )
        await client.addRawResponse(
            forPathContaining: "/actions/runners/",
            method: "POST",
            excludingPathContaining: "/message",
            statusCode: 200,
            json: """
                {"sessionId":"poll-session","ownerName":"test-org","runnerScaleSet":{"id":42,"name":"scale-set"}}
                """.data(using: .utf8)!
        )
        await client.addRawResponse(
            forPathContaining: "/sessions/",
            method: "DELETE",
            statusCode: 204,
            json: Data()
        )
        await client.addRawResponse(
            forPathContaining: "/message",
            method: "POST",
            statusCode: 202,
            json: Data()
        )

        let mock = lifecycle ?? MockVMLifecycle()

        let appState = AppState(
            configStore: configStore,
            githubClientFactory: { client },
            vmEngineFactory: { cachePath, basePath, platformPath, cacheConfig, diagnosticsRetention in
                VMEngine(
                    cacheDirectoryPath: cachePath,
                    baseImagePath: basePath,
                    platformDirectoryPath: platformPath,
                    cacheConfig: cacheConfig,
                    diagnosticsRetention: diagnosticsRetention,
                    lifecycle: mock
                )
            }
        )

        return (appState, client)
    }

    @Test("start with no orgs logs warning and returns early")
    @MainActor
    func startNoOrgs() async throws {
        let (appState, _) = try await makeAppState()
        await appState.start()

        // No engines should be created — polling should not start
        #expect(appState.queueViewModel.isPolling == false)
    }

    @Test("start with valid config starts polling")
    @MainActor
    func startValidConfig() async throws {
        let org = TestFactories.makeOrg(scaleSetId: 42)
        let (appState, _) = try await makeAppState(orgs: [org], withPrivateKeys: true)

        await appState.start()

        #expect(appState.queueViewModel.isPolling)

        await appState.stop()
        #expect(!appState.queueViewModel.isPolling)
    }

    @Test("stop cancels sync and stops polling")
    @MainActor
    func stopCancels() async throws {
        let org = TestFactories.makeOrg(scaleSetId: 42)
        let (appState, _) = try await makeAppState(orgs: [org], withPrivateKeys: true)

        await appState.start()
        await appState.stop()

        #expect(!appState.queueViewModel.isPolling)
    }

    @Test("restart stops then starts")
    @MainActor
    func restart() async throws {
        let org = TestFactories.makeOrg(scaleSetId: 42)
        let (appState, _) = try await makeAppState(orgs: [org], withPrivateKeys: true)

        await appState.start()
        #expect(appState.queueViewModel.isPolling)

        await appState.restart()
        #expect(appState.queueViewModel.isPolling)

        await appState.stop()
    }

    @Test("start with disabled orgs logs warning")
    @MainActor
    func startDisabledOrgs() async throws {
        let org = TestFactories.makeOrg(isEnabled: false)
        let (appState, _) = try await makeAppState(orgs: [org], withPrivateKeys: true)

        // All orgs disabled = validation fails
        await appState.start()
        #expect(!appState.queueViewModel.isPolling)
    }

    @Test("start with missing private key logs warning")
    @MainActor
    func startMissingKey() async throws {
        let org = TestFactories.makeOrg()
        let (appState, _) = try await makeAppState(orgs: [org], withPrivateKeys: false)

        // Missing private key = validation fails
        await appState.start()
        #expect(!appState.queueViewModel.isPolling)
    }

    @Test("start with missing VM setup does not poll")
    @MainActor
    func startMissingVMSetup() async throws {
        let org = TestFactories.makeOrg(scaleSetId: 42)
        let (appState, _) = try await makeAppState(orgs: [org], withPrivateKeys: true, hasReadyVM: false)

        await appState.start()

        #expect(!appState.queueViewModel.isPolling)
        #expect(appState.vmStatusViewModel.readiness.nextIssue?.category == .vm)
    }

    @Test("start blocks polling when GitHub setup check fails")
    @MainActor
    func startBlocksOnGitHubSetupFailure() async throws {
        let (configStore, _) = TestFactories.makeConfigStore()
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        try configStore.configureStorage(at: tempDir)
        try TestFactories.prepareReadyRunnerHostStorage(for: configStore)
        let org = TestFactories.makeOrg(scaleSetId: 42)
        configStore.addOrganization(org)
        _ = configStore.savePrivateKey(try TestFactories.makeTestKeyData(), for: org)

        let client = AppStateSetupFailureGitHubClient(statusCode: 403)
        let appState = AppState(
            configStore: configStore,
            githubClientFactory: { client }
        )

        await appState.start()

        #expect(!appState.queueViewModel.isPolling)
        #expect(
            appState.vmStatusViewModel.readiness.issues.contains {
                $0.category == .github && $0.message.contains("Permission missing")
            }
        )
    }

    @Test("resolvedBaseImagePath defaults to configured storage root")
    @MainActor
    func resolvedBaseImagePathDefault() throws {
        let (configStore, _) = TestFactories.makeConfigStore()
        let tempDir = try TestFactories.makeTempDir()
        defer { TestFactories.cleanup(tempDir) }

        configStore.storageRootPath = tempDir.path
        let appState = AppState(configStore: configStore)

        #expect(appState.vmStatusViewModel.activeVM == nil)
        #expect(appState.vmStatusViewModel.baseImageExists == false)
        #expect(appState.vmStatusViewModel.readyForJobs == false)
    }

    @Test("Apple signing injection resolves selected dispatch asset")
    @MainActor
    func appleSigningInjectionResolvesSelectedAsset() throws {
        let org = TestFactories.makeOrg(
            name: "SevenTwo",
            imageProfile: RunnerImageProfile(name: "Xcode 17")
        )
        let (appState, _) = try await makeAppState(orgs: [org])
        let asset = AppleSigningAsset(
            displayName: "Distribution",
            teamId: "TEAM12345",
            bundleIdentifierPattern: "com.example.*",
            selection: AppleSigningSelection(
                mode: .selectedJobs,
                organizationNames: ["seventwo"],
                repositoryNames: ["tarmac"],
                runnerImageProfileNames: ["xcode 17"],
                workflowNames: ["release"]
            )
        )
        #expect(
            appState.configStore.saveAppleSigningAsset(
                asset,
                certificateData: Data([0x01]),
                certificatePassphrase: "secret",
                provisioningProfileData: Data([0x02])
            )
        )

        let job = TestFactories.makeJob(
            id: 42,
            org: "SevenTwo",
            workflowName: "Release",
            repositoryName: "Tarmac"
        )

        let injection = try appState.appleSigningInjection(for: job, organization: org)
        #expect(injection?.asset.id == asset.id)
        #expect(injection?.certificateData == Data([0x01]))
    }

    @Test("Apple signing injection skips unselected assets")
    @MainActor
    func appleSigningInjectionSkipsUnselectedAsset() throws {
        let org = TestFactories.makeOrg(name: "SevenTwo")
        let (appState, _) = try await makeAppState(orgs: [org])
        let asset = AppleSigningAsset(
            displayName: "Distribution",
            teamId: "TEAM12345",
            bundleIdentifierPattern: "com.example.*"
        )
        #expect(
            appState.configStore.saveAppleSigningAsset(
                asset,
                certificateData: Data([0x01]),
                certificatePassphrase: "secret",
                provisioningProfileData: Data([0x02])
            )
        )

        let job = TestFactories.makeJob(id: 42, org: "SevenTwo")
        #expect(try appState.appleSigningInjection(for: job, organization: org) == nil)
    }

    @Test("Apple signing injection blocks invalid selected assets")
    @MainActor
    func appleSigningInjectionBlocksInvalidAsset() throws {
        let org = TestFactories.makeOrg(name: "SevenTwo")
        let (appState, _) = try await makeAppState(orgs: [org])
        let asset = AppleSigningAsset(
            displayName: "Expired Distribution",
            teamId: "TEAM12345",
            bundleIdentifierPattern: "com.example.*",
            selection: AppleSigningSelection(mode: .allJobs),
            certificateExpiresAt: Date(timeIntervalSince1970: 1_000)
        )
        #expect(
            appState.configStore.saveAppleSigningAsset(
                asset,
                certificateData: Data([0x01]),
                certificatePassphrase: "secret",
                provisioningProfileData: Data([0x02])
            )
        )

        let job = TestFactories.makeJob(id: 42, org: "SevenTwo")
        #expect(throws: AppleSigningDispatchError.self) {
            try appState.appleSigningInjection(for: job, organization: org)
        }
    }
}

private struct AppStateSetupFailureGitHubClient: GitHubClientProtocol {
    private let statusCode: Int

    init(statusCode: Int) {
        self.statusCode = statusCode
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
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com\(path)")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(), response)
    }
}
