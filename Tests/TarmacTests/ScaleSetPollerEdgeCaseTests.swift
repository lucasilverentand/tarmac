import Foundation
import Testing

@testable import Tarmac

@Suite("ScaleSetPoller Edge Cases")
struct ScaleSetPollerEdgeCaseTests {
    @Test("Poll timeout returns empty array (202)")
    func pollTimeoutReturnsEmpty() async throws {
        let client = Timeout202Client()
        let poller = ScaleSetPoller(client: client) { _ in "test-token" }
        let org = TestFactories.makeOrg(scaleSetId: 42)

        let messages = try await poller.poll(org: org, sessionId: "session-1")
        #expect(messages.isEmpty)
    }

    @Test("401 from poll is classified as token expiry")
    func pollTokenExpired() async {
        let client = ErrorClient(statusCode: 401, message: "Unauthorized")
        let poller = ScaleSetPoller(client: client) { _ in "test-token" }
        let org = TestFactories.makeOrg(scaleSetId: 42)

        do {
            _ = try await poller.poll(org: org, sessionId: "session-1")
            Issue.record("Expected token expiry")
        } catch let error as ScaleSetPollerError {
            guard case .tokenExpired(let orgName, let operation, _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(orgName == org.name)
            #expect(operation == "poll messages")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("403 rate limit response is classified")
    func pollRateLimited() async {
        let client = ErrorClient(
            statusCode: 403,
            message: "rate limited",
            headers: ["X-RateLimit-Remaining": "0", "Retry-After": "12"]
        )
        let poller = ScaleSetPoller(client: client) { _ in "test-token" }
        let org = TestFactories.makeOrg(scaleSetId: 42)

        do {
            _ = try await poller.poll(org: org, sessionId: "session-1")
            Issue.record("Expected rate limit")
        } catch let error as ScaleSetPollerError {
            guard case .rateLimited = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Concurrent polls for different orgs do not interfere")
    func concurrentPollsDifferentOrgs() async throws {
        let client = RecordingGitHubClient(
            defaultResponseJSON: """
                [{"messageId":1,"messageType":"JobAvailable","body":"{}","statistics":null}]
                """.data(using: .utf8)!
        )

        let poller = ScaleSetPoller(client: client) { _ in "test-token" }
        let orgA = TestFactories.makeOrg(name: "org-a", scaleSetId: 1)
        let orgB = TestFactories.makeOrg(name: "org-b", scaleSetId: 2)

        async let messagesA = poller.poll(org: orgA, sessionId: "session-a")
        async let messagesB = poller.poll(org: orgB, sessionId: "session-b")

        let (resultA, resultB) = try await (messagesA, messagesB)
        #expect(resultA.count == 1)
        #expect(resultB.count == 1)

        let requests = await client.requests
        #expect(requests.count == 2)

        // Verify requests went to different paths
        let paths = requests.map(\.path)
        #expect(paths.contains { $0.contains("org-a") })
        #expect(paths.contains { $0.contains("org-b") })
    }

    @Test("Poll with non-decodable response is classified as malformed")
    func nonDecodableResponse() async {
        let client = RecordingGitHubClient(
            defaultResponseJSON: "not json at all".data(using: .utf8)!
        )
        let poller = ScaleSetPoller(client: client) { _ in "test-token" }
        let org = TestFactories.makeOrg(scaleSetId: 42)

        do {
            _ = try await poller.poll(org: org, sessionId: "session-1")
            Issue.record("Expected malformed response")
        } catch let error as ScaleSetPollerError {
            guard case .malformedResponse(let orgName, let operation, _) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(orgName == org.name)
            #expect(operation == "poll messages")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

/// Client that returns 202 No Content to simulate poll timeout
private struct Timeout202Client: GitHubClientProtocol {
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

/// Client that returns a specific HTTP error
private struct ErrorClient: GitHubClientProtocol {
    let statusCode: Int
    let message: String
    var headers: [String: String] = [:]

    func request<T: Decodable & Sendable>(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String],
        timeoutInterval: TimeInterval
    ) async throws -> T {
        throw GitHubAPIError.httpError(statusCode: statusCode, message: message)
    }

    func requestRaw(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String],
        timeoutInterval: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        let url = URL(string: "https://api.github.com")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headers
        )!
        return (message.data(using: .utf8)!, response)
    }
}
