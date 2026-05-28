import Foundation

actor ScaleSetPoller {
    private let client: any GitHubClientProtocol
    private let tokenProvider: @Sendable (Organization) async throws -> String
    private let longPollTimeout: TimeInterval = 300
    private let decoder = JSONDecoder()

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

        let path = "\(org.accountPath)/actions/runners/\(scaleSetId)/sessions"

        Log.poller.info("Creating session for org \(org.name) scaleSet \(scaleSetId)")

        let (data, response) = try await client.requestRaw(
            method: "POST",
            path: path,
            body: nil as String?,
            headers: ["Authorization": "Bearer \(token)"],
            timeoutInterval: 30
        )

        try validate(response: response, data: data, org: org, operation: "create session")

        let session: ScaleSetSession
        do {
            session = try decoder.decode(ScaleSetSession.self, from: data)
        } catch {
            throw ScaleSetPollerError.malformedResponse(
                org: org.name,
                operation: "create session",
                detail: error.localizedDescription
            )
        }

        Log.poller.info("Session created: \(session.sessionId ?? "nil") for org \(org.name)")
        return session
    }

    func deleteSession(org: Organization, token: String, sessionId: String) async throws {
        guard let scaleSetId = org.scaleSetId else {
            throw ScaleSetPollerError.missingScaleSetId(org: org.name)
        }

        let path = "\(org.accountPath)/actions/runners/\(scaleSetId)/sessions/\(sessionId)"

        Log.poller.info("Deleting session \(sessionId) for org \(org.name)")

        let (_, response) = try await client.requestRaw(
            method: "DELETE",
            path: path,
            body: nil as String?,
            headers: ["Authorization": "Bearer \(token)"],
            timeoutInterval: 30
        )

        if response.statusCode == 404 {
            Log.poller.info("Session \(sessionId) already gone for org \(org.name)")
            return
        }

        try validate(response: response, data: Data(), org: org, operation: "delete session")

        Log.poller.info("Session \(sessionId) deleted for org \(org.name)")
    }

    // MARK: - Polling

    func poll(org: Organization, sessionId: String) async throws -> [ScaleSetMessage] {
        guard let scaleSetId = org.scaleSetId else {
            throw ScaleSetPollerError.missingScaleSetId(org: org.name)
        }

        let token = try await tokenProvider(org)
        let path = "\(org.accountPath)/actions/runners/\(scaleSetId)/sessions/\(sessionId)/message"

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

        try validate(response: response, data: data, org: org, operation: "poll messages")

        // Response may be a single message or an array
        if let messages = try? decoder.decode([ScaleSetMessage].self, from: data) {
            Log.poller.info("Received \(messages.count) messages for org \(org.name)")
            return messages
        }

        if let single = try? decoder.decode(ScaleSetMessage.self, from: data) {
            Log.poller.info("Received 1 message for org \(org.name)")
            return [single]
        }

        Log.poller.warning("Could not decode message response for org \(org.name)")
        throw ScaleSetPollerError.malformedResponse(
            org: org.name,
            operation: "poll messages",
            detail: String(data: data, encoding: .utf8) ?? "non-UTF-8 response"
        )
    }

    private func validate(
        response: HTTPURLResponse,
        data: Data,
        org: Organization,
        operation: String
    ) throws {
        guard !(200..<300).contains(response.statusCode) else { return }

        let message =
            String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        let retryAfter = headerValue("Retry-After", in: response).flatMap(TimeInterval.init)
        let rateLimitRemaining = headerValue("X-RateLimit-Remaining", in: response)
        let looksRateLimited = message.localizedCaseInsensitiveContains("rate limit")

        switch response.statusCode {
        case 401:
            throw ScaleSetPollerError.tokenExpired(org: org.name, operation: operation, message: message)
        case 403 where retryAfter != nil || rateLimitRemaining == "0" || looksRateLimited:
            throw ScaleSetPollerError.rateLimited(
                org: org.name,
                operation: operation,
                retryAfter: retryAfter,
                message: message
            )
        case 404, 410:
            throw ScaleSetPollerError.scaleSetUnavailable(
                org: org,
                operation: operation,
                statusCode: response.statusCode,
                message: message
            )
        case 403:
            throw ScaleSetPollerError.permissionDenied(
                org: org.name,
                operation: operation,
                statusCode: response.statusCode,
                message: message
            )
        case 429:
            throw ScaleSetPollerError.rateLimited(
                org: org.name,
                operation: operation,
                retryAfter: retryAfter,
                message: message
            )
        case 500..<600:
            throw ScaleSetPollerError.transientFailure(
                org: org.name,
                operation: operation,
                statusCode: response.statusCode,
                message: message
            )
        default:
            throw ScaleSetPollerError.requestFailed(
                org: org.name,
                operation: operation,
                statusCode: response.statusCode,
                message: message
            )
        }
    }

    private func headerValue(_ name: String, in response: HTTPURLResponse) -> String? {
        if let value = response.value(forHTTPHeaderField: name) {
            return value
        }

        return response.allHeaderFields.first { key, _ in
            String(describing: key).caseInsensitiveCompare(name) == .orderedSame
        }
        .map { String(describing: $0.value) }
    }
}

enum ScaleSetPollerError: Error, LocalizedError, Equatable, Sendable {
    case missingScaleSetId(org: String)
    case scaleSetUnavailable(org: Organization, operation: String, statusCode: Int, message: String)
    case tokenExpired(org: String, operation: String, message: String)
    case permissionDenied(org: String, operation: String, statusCode: Int, message: String)
    case rateLimited(org: String, operation: String, retryAfter: TimeInterval?, message: String)
    case transientFailure(org: String, operation: String, statusCode: Int, message: String)
    case malformedResponse(org: String, operation: String, detail: String)
    case requestFailed(org: String, operation: String, statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingScaleSetId(let org):
            "Organization '\(org)' has no scale set ID configured"
        case .scaleSetUnavailable(let org, let operation, let statusCode, _):
            ScaleSetPollingMessages.unavailable(
                organization: org,
                statusCode: statusCode,
                operation: operation
            )
        case .tokenExpired(let org, let operation, let message):
            "GitHub token expired while trying to \(operation) for '\(org)': \(message)"
        case .permissionDenied(let org, let operation, let statusCode, let message):
            "GitHub denied \(operation) for '\(org)' (HTTP \(statusCode)): \(message)"
        case .rateLimited(let org, let operation, let retryAfter, let message):
            if let retryAfter {
                "GitHub rate-limited \(operation) for '\(org)' for \(retryAfter)s: \(message)"
            } else {
                "GitHub rate-limited \(operation) for '\(org)': \(message)"
            }
        case .transientFailure(let org, let operation, let statusCode, let message):
            "GitHub transient failure during \(operation) for '\(org)' (HTTP \(statusCode)): \(message)"
        case .malformedResponse(let org, let operation, let detail):
            "GitHub returned a malformed response during \(operation) for '\(org)': \(detail)"
        case .requestFailed(let org, let operation, let statusCode, let message):
            "GitHub \(operation) failed for '\(org)' (HTTP \(statusCode)): \(message)"
        }
    }

    var retryAfter: TimeInterval? {
        if case .rateLimited(_, _, let retryAfter, _) = self {
            return retryAfter
        }
        return nil
    }
}
