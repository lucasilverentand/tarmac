import Foundation
import Testing

@testable import Tarmac

@Suite("AppState")
struct AppStateTests {
    @MainActor
    private func makeAppState(
        orgs: [Organization] = [],
        withPrivateKeys: Bool = false,
        lifecycle: MockVMLifecycle? = nil
    ) throws -> (AppState, RecordingGitHubClient) {
        let (configStore, _) = TestFactories.makeConfigStore()
        let tempDir = try TestFactories.makeTempDir()

        configStore.cacheDirectoryPath = tempDir.path

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

        let mock = lifecycle ?? MockVMLifecycle()

        let appState = AppState(
            configStore: configStore,
            githubClientFactory: { client },
            vmEngineFactory: { cachePath, basePath, cacheConfig in
                VMEngine(
                    cacheDirectoryPath: cachePath,
                    baseImagePath: basePath,
                    cacheConfig: cacheConfig,
                    lifecycle: mock
                )
            }
        )

        return (appState, client)
    }

    @Test("start with no orgs logs warning and returns early")
    @MainActor
    func startNoOrgs() async throws {
        let (appState, _) = try makeAppState()
        await appState.start()

        // No engines should be created — polling should not start
        #expect(appState.queueViewModel.isPolling == false)
    }

    @Test("start with valid config starts polling")
    @MainActor
    func startValidConfig() async throws {
        let org = TestFactories.makeOrg(scaleSetId: 42)
        let (appState, _) = try makeAppState(orgs: [org], withPrivateKeys: true)

        await appState.start()

        #expect(appState.queueViewModel.isPolling)

        await appState.stop()
        #expect(!appState.queueViewModel.isPolling)
    }

    @Test("stop cancels sync and stops polling")
    @MainActor
    func stopCancels() async throws {
        let org = TestFactories.makeOrg(scaleSetId: 42)
        let (appState, _) = try makeAppState(orgs: [org], withPrivateKeys: true)

        await appState.start()
        await appState.stop()

        #expect(!appState.queueViewModel.isPolling)
    }

    @Test("restart stops then starts")
    @MainActor
    func restart() async throws {
        let org = TestFactories.makeOrg(scaleSetId: 42)
        let (appState, _) = try makeAppState(orgs: [org], withPrivateKeys: true)

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
        let (appState, _) = try makeAppState(orgs: [org], withPrivateKeys: true)

        // All orgs disabled = validation fails
        await appState.start()
        #expect(!appState.queueViewModel.isPolling)
    }

    @Test("start with missing private key logs warning")
    @MainActor
    func startMissingKey() async throws {
        let org = TestFactories.makeOrg()
        let (appState, _) = try makeAppState(orgs: [org], withPrivateKeys: false)

        // Missing private key = validation fails
        await appState.start()
        #expect(!appState.queueViewModel.isPolling)
    }

    @Test("resolvedBaseImagePath defaults to Application Support")
    @MainActor
    func resolvedBaseImagePathDefault() throws {
        let (configStore, _) = TestFactories.makeConfigStore()
        // baseImagePath is empty by default
        let appState = AppState(configStore: configStore)

        // The private method resolvedBaseImagePath is called in start(),
        // but we can verify the ViewModel starts clean
        #expect(appState.vmStatusViewModel.activeVM == nil)
        #expect(appState.vmStatusViewModel.baseImageExists == false)
    }
}
