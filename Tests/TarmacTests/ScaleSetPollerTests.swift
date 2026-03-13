import Foundation
import Testing

@testable import Tarmac

@Suite("ScaleSetPoller")
struct ScaleSetPollerTests {
    @Test("Parses ScaleSetMessage from JSON")
    func parseMessage() throws {
        let json = """
            {
                "messageId": 42,
                "messageType": "JobAvailable",
                "body": "{\\"jobMessageBase\\":{\\"jobId\\":100,\\"runnerRequestId\\":1,\\"repositoryName\\":\\"my-repo\\",\\"ownerName\\":\\"my-org\\",\\"workflowRunName\\":\\"CI\\"}}",
                "statistics": {
                    "totalAvailableJobs": 1,
                    "totalAssignedJobs": 0,
                    "totalRunningJobs": 0,
                    "totalRegisteredRunners": 1
                }
            }
            """.data(using: .utf8)!

        let message = try JSONDecoder().decode(ScaleSetMessage.self, from: json)
        #expect(message.messageId == 42)
        #expect(message.messageType == "JobAvailable")
        #expect(message.statistics?.totalAvailableJobs == 1)

        // Parse the nested body
        let bodyData = message.body.data(using: .utf8)!
        let body = try JSONDecoder().decode(JobAvailableMessage.self, from: bodyData)
        #expect(body.jobMessageBase.jobId == 100)
        #expect(body.jobMessageBase.repositoryName == "my-repo")
        #expect(body.jobMessageBase.workflowRunName == "CI")
    }

    @Test("Parses JobCompletedMessage from body")
    func parseJobCompleted() throws {
        let json = """
            {"jobId": 200, "result": "succeeded"}
            """.data(using: .utf8)!

        let message = try JSONDecoder().decode(JobCompletedMessage.self, from: json)
        #expect(message.jobId == 200)
        #expect(message.result == "succeeded")
    }

    @Test("202 response returns empty array")
    func emptyOnNoContent() async throws {
        var client = PreviewGitHubClient()
        // Configure client to return 202
        client.nextResponse = nil as String?

        // Create a custom client that returns 202
        let emptyClient = Empty202Client()

        let poller = ScaleSetPoller(client: emptyClient) { _ in "test-token" }
        let org = Organization(
            name: "test-org",
            appId: "1",
            installationId: 1,
            scaleSetId: 42,
            labels: ["self-hosted"]
        )

        let messages = try await poller.poll(org: org, sessionId: "session-1")
        #expect(messages.isEmpty)
    }
}

/// Client that returns 202 No Content for raw requests
private struct Empty202Client: GitHubClientProtocol {
    func request<T: Decodable & Sendable>(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String],
        timeoutInterval: TimeInterval
    ) async throws -> T {
        throw GitHubAPIError.httpError(statusCode: 202, message: "No content")
    }

    func requestRaw(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String],
        timeoutInterval: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 202,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(), response)
    }
}
