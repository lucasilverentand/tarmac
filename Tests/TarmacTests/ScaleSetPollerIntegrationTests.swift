import Foundation
import Testing

@testable import Tarmac

@Suite("ScaleSetPoller Integration")
struct ScaleSetPollerIntegrationTests {
    @Test("createSession sends POST to correct path with scaleSetId")
    func createSessionPath() async throws {
        let client = RecordingGitHubClient(
            defaultResponseJSON: """
                {"sessionId":"sess-1","ownerName":"my-org","runnerScaleSet":{"id":42,"name":"scale-set"}}
                """.data(using: .utf8)!
        )

        let poller = ScaleSetPoller(client: client) { _ in "test-token" }
        let org = TestFactories.makeOrg(name: "my-org", scaleSetId: 42)

        _ = try await poller.createSession(org: org, token: "test-token")

        let requests = await client.requests
        #expect(requests.count == 1)
        #expect(requests[0].method == "POST")
        #expect(requests[0].path == "/orgs/my-org/actions/runners/42/sessions")
    }

    @Test("createSession throws missingScaleSetId for org without scaleSetId")
    func createSessionMissingScaleSetId() async {
        let client = RecordingGitHubClient()
        let poller = ScaleSetPoller(client: client) { _ in "test-token" }
        let org = TestFactories.makeOrg(name: "no-ss", scaleSetId: nil)

        await #expect(throws: ScaleSetPollerError.self) {
            _ = try await poller.createSession(org: org, token: "test-token")
        }
    }

    @Test("deleteSession sends DELETE to correct path")
    func deleteSessionPath() async throws {
        let client = RecordingGitHubClient()
        let poller = ScaleSetPoller(client: client) { _ in "test-token" }
        let org = TestFactories.makeOrg(name: "del-org", scaleSetId: 7)

        try await poller.deleteSession(org: org, token: "test-token", sessionId: "sess-abc")

        let requests = await client.requests
        #expect(requests.count == 1)
        #expect(requests[0].method == "DELETE")
        #expect(requests[0].path == "/orgs/del-org/actions/runners/7/sessions/sess-abc")
    }

    @Test("poll wraps single-object response into array")
    func pollWrapsSingleObject() async throws {
        let singleMessageJSON = """
            {"messageId":1,"messageType":"JobAvailable","body":"{}","statistics":{"totalAvailableJobs":1,"totalAssignedJobs":0,"totalRunningJobs":0,"totalRegisteredRunners":1}}
            """.data(using: .utf8)!

        let client = RecordingGitHubClient(defaultResponseJSON: singleMessageJSON)
        let poller = ScaleSetPoller(client: client) { _ in "test-token" }
        let org = TestFactories.makeOrg(name: "poll-org", scaleSetId: 5)

        let messages = try await poller.poll(org: org, sessionId: "sess-1")
        #expect(messages.count == 1)
        #expect(messages[0].messageId == 1)
    }
}
