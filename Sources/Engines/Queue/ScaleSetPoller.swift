import Foundation

actor ScaleSetPoller {
    private let client: any GitHubClientProtocol
    private let tokenProvider: @Sendable (Organization) async throws -> String
    private let longPollTimeout: TimeInterval = 300

    init(
        client: any GitHubClientProtocol,
        tokenProvider: @escaping @Sendable (Organization) async throws -> String
    ) {
        self.client = client
        self.tokenProvider = tokenProvider
    }

    // MARK: - Session Management

    func createSession(org: Organization, token: String) async throws -> ScaleSetSession {
        guard let scaleSetId = org.scaleSetId else {
            throw ScaleSetPollerError.missingScaleSetId(org: org.name)
        }

        let path = "/orgs/\(org.name)/actions/runners/\(scaleSetId)/sessions"

        Log.poller.info("Creating session for org \(org.name) scaleSet \(scaleSetId)")

        let session: ScaleSetSession = try await client.request(
            method: "POST",
            path: path,
            body: nil as String?,
            headers: ["Authorization": "Bearer \(token)"],
            timeoutInterval: 30
        )

        Log.poller.info("Session created: \(session.sessionId ?? "nil") for org \(org.name)")
        return session
    }

    func deleteSession(org: Organization, token: String, sessionId: String) async throws {
        guard let scaleSetId = org.scaleSetId else {
            throw ScaleSetPollerError.missingScaleSetId(org: org.name)
        }

        let path = "/orgs/\(org.name)/actions/runners/\(scaleSetId)/sessions/\(sessionId)"

        Log.poller.info("Deleting session \(sessionId) for org \(org.name)")

        let (_, response) = try await client.requestRaw(
            method: "DELETE",
            path: path,
            body: nil as String?,
            headers: ["Authorization": "Bearer \(token)"],
            timeoutInterval: 30
        )

        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpError(
                statusCode: response.statusCode,
                message: "Failed to delete session \(sessionId)"
            )
        }

        Log.poller.info("Session \(sessionId) deleted for org \(org.name)")
    }

    // MARK: - Polling

    func poll(org: Organization, sessionId: String) async throws -> [ScaleSetMessage] {
        guard let scaleSetId = org.scaleSetId else {
            throw ScaleSetPollerError.missingScaleSetId(org: org.name)
        }

        let token = try await tokenProvider(org)
        let path = "/orgs/\(org.name)/actions/runners/\(scaleSetId)/sessions/\(sessionId)/message"

        Log.poller.debug("Long-polling org \(org.name) session \(sessionId)")

        let (data, response) = try await client.requestRaw(
            method: "POST",
            path: path,
            body: nil as String?,
            headers: ["Authorization": "Bearer \(token)"],
            timeoutInterval: longPollTimeout
        )

        // 202 = no messages available
        if response.statusCode == 202 {
            Log.poller.debug("No messages for org \(org.name)")
            return []
        }

        guard (200..<300).contains(response.statusCode) else {
            throw GitHubAPIError.httpError(
                statusCode: response.statusCode,
                message: String(data: data, encoding: .utf8) ?? "Unknown error"
            )
        }

        // Response may be a single message or an array
        let decoder = JSONDecoder()
        if let messages = try? decoder.decode([ScaleSetMessage].self, from: data) {
            Log.poller.info("Received \(messages.count) messages for org \(org.name)")
            return messages
        }

        if let single = try? decoder.decode(ScaleSetMessage.self, from: data) {
            Log.poller.info("Received 1 message for org \(org.name)")
            return [single]
        }

        Log.poller.warning("Could not decode message response for org \(org.name)")
        return []
    }
}

enum ScaleSetPollerError: Error, LocalizedError, Sendable {
    case missingScaleSetId(org: String)

    var errorDescription: String? {
        switch self {
        case .missingScaleSetId(let org):
            "Organization '\(org)' has no scale set ID configured"
        }
    }
}
