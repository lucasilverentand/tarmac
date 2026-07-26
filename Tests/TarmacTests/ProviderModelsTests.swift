import Foundation
import Testing

@testable import Tarmac

@Suite("Provider models")
struct ProviderModelsTests {
    @Test("Remote job IDs are namespaced by account")
    func providerJobIdentity() {
        let remoteID = "42"
        let first = ProviderJobKey(accountID: UUID(), remoteJobID: remoteID)
        let second = ProviderJobKey(accountID: UUID(), remoteJobID: remoteID)

        #expect(first != second)
        #expect(first.localID != second.localID)
        #expect(first.localID > 0)
        #expect(first.localID == ProviderJobKey(accountID: first.accountID, remoteJobID: remoteID).localID)
    }

    @Test("Gitea host labels are normalized and deduplicated")
    func giteaLabels() {
        let account = Organization(
            provider: .gitea,
            serverURL: "https://git.example.test",
            name: "owner",
            appId: "",
            installationId: 0,
            labels: ["macos-arm64", "macos-arm64:host", "MACOS-ARM64"]
        )

        #expect(account.giteaRunnerLabels == ["macos-arm64:host"])
    }

    @Test("Semantic version enforces the Gitea runner minimum")
    func semanticVersion() throws {
        #expect(try #require(SemanticVersion("v0.2.12")) >= GiteaRunnerProvider.minimumVersion)
        #expect(try #require(SemanticVersion("0.2.11")) < GiteaRunnerProvider.minimumVersion)
        #expect(SemanticVersion("not-a-version") == nil)
    }
}
