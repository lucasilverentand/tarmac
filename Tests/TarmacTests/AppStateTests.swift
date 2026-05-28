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
        lifecycle: MockVMLifecycle? = nil,
        warmRunnerConfig: WarmRunnerConfiguration? = nil,
        warmRunnerIdleShutdownSecondsOverride: Int? = nil
    ) async throws -> (AppState, RecordingGitHubClient, MockVMLifecycle) {
        let (configStore, _) = TestFactories.makeConfigStore()
        let tempDir = try TestFactories.makeTempDir()

        try configStore.configureStorage(at: tempDir)
        if let warmRunnerConfig {
            configStore.warmRunnerConfig = warmRunnerConfig
        }
        if hasReadyVM {
            try TestFactories.prepareReadyRunnerHostStorage(for: configStore)
        }
        try prepareCachedRunnerBinary(at: configStore.storageRootPath)

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
                {"encoded_jit_config":"test-jit-config"}
                """.data(using: .utf8)!
        )
        await configureGitHubSetupStubs(client: client, futureDate: futureDate)

        let mock = lifecycle ?? MockVMLifecycle()
        let jobStore = TestFactories.makeJobStore()
        let runnerLeaseStore = RunnerLeaseStore(
            defaults: UserDefaults(suiteName: "appstate-leases-\(UUID().uuidString)")!
        )
        let sessionStore = PollingSessionStore(
            defaults: UserDefaults(suiteName: "appstate-sessions-\(UUID().uuidString)")!
        )

        let appState = AppState(
            configStore: configStore,
            githubClientFactory: { client },
            queueEngineFactory: { github, client in
                QueueEngine(
                    github: github,
                    client: client,
                    jobStore: jobStore,
                    runnerLeaseStore: runnerLeaseStore,
                    sessionStore: sessionStore
                )
            },
            vmEngineFactory: { cachePath, basePath, platformPath, cacheConfig, diagnosticsRetention in
                VMEngine(
                    cacheDirectoryPath: cachePath,
                    baseImagePath: basePath,
                    platformDirectoryPath: platformPath,
                    cacheConfig: cacheConfig,
                    diagnosticsRetention: diagnosticsRetention,
                    lifecycle: mock
                )
            },
            warmRunnerIdleShutdownSecondsOverride: warmRunnerIdleShutdownSecondsOverride
        )

        return (appState, client, mock)
    }

    private func configureGitHubSetupStubs(client: RecordingGitHubClient, futureDate: String) async {
        await client.addResponse(
            forPathContaining: "access_tokens",
            json: """
                {"token":"ghs_test","expires_at":"\(futureDate)"}
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "runner-groups",
            json: """
                {"runner_groups":[{"id":1,"name":"Default"}]}
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "runner-scale-sets",
            json: """
                {"id":42,"name":"test-scale-set"}
                """.data(using: .utf8)!
        )
        await client.addRawResponse(
            forPathContaining: "/actions/runners/42/sessions",
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
            statusCode: 404,
            json: """
                {"message":"Not Found"}
                """.data(using: .utf8)!
        )
        await client.addResponse(
            forPathContaining: "runners/downloads",
            json: """
                [{"os":"osx","architecture":"arm64","download_url":"https://example.com/runner.tar.gz","filename":"runner.tar.gz"}]
                """.data(using: .utf8)!
        )
    }

    private func prepareCachedRunnerBinary(at storageRootPath: String) throws {
        let runnerDir = StorageManager(rootPath: storageRootPath).runnerDirectory
        try FileManager.default.createDirectory(at: runnerDir, withIntermediateDirectories: true)
        let runScript = runnerDir.appendingPathComponent("run.sh")
        try "#!/bin/bash".write(to: runScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runScript.path
        )
    }

    private func jobAvailableMessage(jobId: Int64, org: String = "test-org") -> ScaleSetMessage {
        let body = """
            {"jobMessageBase":{"jobId":\(jobId),"runnerRequestId":1,"repositoryName":"test-repo","ownerName":"\(org)","workflowRunName":"CI"}}
            """
        return ScaleSetMessage(
            messageId: jobId,
            messageType: "JobAvailable",
            body: body,
            statistics: nil
        )
    }

    private func jobCompletedMessage(jobId: Int64, result: String = "success") -> ScaleSetMessage {
        let body = """
            {"jobId":\(jobId),"result":"\(result)"}
            """
        return ScaleSetMessage(
            messageId: jobId + 1_000,
            messageType: "JobCompleted",
            body: body,
            statistics: nil
        )
    }

    @MainActor
    private func waitForRunningJob(
        appState: AppState,
        jobId: Int64,
        timeout: Duration = .seconds(5)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let job = appState.queueViewModel.allJobs.first(where: { $0.id == jobId })
            if job?.status == .running, appState.vmStatusViewModel.activeVM != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out waiting for job \(jobId) to reach running state with an active VM")
    }

    @Test("start with no orgs logs warning and returns early")
    @MainActor
    func startNoOrgs() async throws {
        let (appState, _, _) = try await makeAppState()
        await appState.start()

        // No engines should be created — polling should not start
        #expect(appState.queueViewModel.isPolling == false)
    }

    @Test("start with valid config starts polling")
    @MainActor
    func startValidConfig() async throws {
        let org = TestFactories.makeOrg(scaleSetId: 42)
        let (appState, _, _) = try await makeAppState(orgs: [org], withPrivateKeys: true)

        await appState.start()

        #expect(appState.queueViewModel.isPolling)

        await appState.stop()
        #expect(!appState.queueViewModel.isPolling)
    }

    @Test("stop cancels sync and stops polling")
    @MainActor
    func stopCancels() async throws {
        let org = TestFactories.makeOrg(scaleSetId: 42)
        let (appState, _, _) = try await makeAppState(orgs: [org], withPrivateKeys: true)

        await appState.start()
        await appState.stop()

        #expect(!appState.queueViewModel.isPolling)
    }

    @Test("restart stops then starts")
    @MainActor
    func restart() async throws {
        let org = TestFactories.makeOrg(scaleSetId: 42)
        let (appState, _, _) = try await makeAppState(orgs: [org], withPrivateKeys: true)

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
        let (appState, _, _) = try await makeAppState(orgs: [org], withPrivateKeys: true)

        // All orgs disabled = validation fails
        await appState.start()
        #expect(!appState.queueViewModel.isPolling)
    }

    @Test("start with missing private key logs warning")
    @MainActor
    func startMissingKey() async throws {
        let org = TestFactories.makeOrg()
        let (appState, _, _) = try await makeAppState(orgs: [org], withPrivateKeys: false)

        // Missing private key = validation fails
        await appState.start()
        #expect(!appState.queueViewModel.isPolling)
    }

    @Test("start with missing VM setup does not poll")
    @MainActor
    func startMissingVMSetup() async throws {
        let org = TestFactories.makeOrg(scaleSetId: 42)
        let (appState, _, _) = try await makeAppState(orgs: [org], withPrivateKeys: true, hasReadyVM: false)

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
    func appleSigningInjectionResolvesSelectedAsset() async throws {
        let org = TestFactories.makeOrg(
            name: "SevenTwo",
            imageProfile: RunnerImageProfile(name: "Xcode 17")
        )
        let (appState, _, _) = try await makeAppState(orgs: [org])
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
    func appleSigningInjectionSkipsUnselectedAsset() async throws {
        let org = TestFactories.makeOrg(name: "SevenTwo")
        let (appState, _, _) = try await makeAppState(orgs: [org])
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
    func appleSigningInjectionBlocksInvalidAsset() async throws {
        let org = TestFactories.makeOrg(name: "SevenTwo")
        let (appState, _, _) = try await makeAppState(orgs: [org])
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

    @Test("keepWarmRunner teardown schedules warm runner idle release")
    @MainActor
    func keepWarmRunnerTeardownSchedulesIdleRelease() async throws {
        let org = TestFactories.makeOrg(scaleSetId: 42)
        let warmConfig = WarmRunnerConfiguration(isEnabled: true, idleShutdownSeconds: 60)
        let (appState, _, mock) = try await makeAppState(
            orgs: [org],
            withPrivateKeys: true,
            warmRunnerConfig: warmConfig,
            warmRunnerIdleShutdownSecondsOverride: 30
        )

        await appState.start()

        await appState.testing_handleScaleSetMessages([jobAvailableMessage(jobId: 501, org: org.name)], org: org)
        try await waitForRunningJob(appState: appState, jobId: 501)

        await appState.testing_handleScaleSetMessages([jobCompletedMessage(jobId: 501)], org: org)

        #expect(appState.isWarmRunnerIdleReleaseScheduled)
        #expect(appState.vmStatusViewModel.activeVM != nil)
        #expect(mock.stopCallCount == 0)

        await appState.stop()
    }

    @Test("warm runner idle release shuts down VM after idle timeout")
    @MainActor
    func warmRunnerIdleReleaseAfterTimeout() async throws {
        let org = TestFactories.makeOrg(scaleSetId: 42)
        let warmConfig = WarmRunnerConfiguration(isEnabled: true, idleShutdownSeconds: 60)
        let (appState, _, mock) = try await makeAppState(
            orgs: [org],
            withPrivateKeys: true,
            warmRunnerConfig: warmConfig,
            warmRunnerIdleShutdownSecondsOverride: 1
        )

        await appState.start()

        await appState.testing_handleScaleSetMessages([jobAvailableMessage(jobId: 502, org: org.name)], org: org)
        try await waitForRunningJob(appState: appState, jobId: 502)

        await appState.testing_handleScaleSetMessages([jobCompletedMessage(jobId: 502)], org: org)
        #expect(appState.isWarmRunnerIdleReleaseScheduled)

        try await Task.sleep(for: .milliseconds(1_500))

        #expect(!appState.isWarmRunnerIdleReleaseScheduled)
        #expect(appState.vmStatusViewModel.activeVM == nil)
        #expect(mock.stopCallCount == 1)

        await appState.stop()
    }

    @Test("full teardown does not schedule warm runner idle release")
    @MainActor
    func fullTeardownDoesNotScheduleIdleRelease() async throws {
        let org = TestFactories.makeOrg(scaleSetId: 42)
        let (appState, _, mock) = try await makeAppState(
            orgs: [org],
            withPrivateKeys: true,
            warmRunnerConfig: WarmRunnerConfiguration(isEnabled: false)
        )

        await appState.start()

        await appState.testing_handleScaleSetMessages([jobAvailableMessage(jobId: 503, org: org.name)], org: org)
        try await waitForRunningJob(appState: appState, jobId: 503)

        await appState.testing_handleScaleSetMessages([jobCompletedMessage(jobId: 503)], org: org)

        #expect(!appState.isWarmRunnerIdleReleaseScheduled)
        #expect(appState.vmStatusViewModel.activeVM == nil)
        #expect(mock.stopCallCount == 1)

        await appState.stop()
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
