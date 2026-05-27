import Foundation

enum VMControlHTTPRouter {
    static func handle(
        request: VMControlHTTPRequest,
        configuration: VMControlConfiguration,
        handler: VMControlHandling
    ) async -> VMControlHTTPResponse {
        let normalizedPath = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path

        switch (request.method, normalizedPath) {
        case ("GET", "/health"):
            return .json(handler.health())

        case ("GET", "/vm"):
            return .json(handler.vmState())

        case ("POST", "/vm/boot"):
            return await mutate(
                request: request,
                configuration: configuration,
                handler: handler
            ) {
                try await handler.boot()
            }

        case ("POST", "/vm/stop"):
            return await mutate(
                request: request,
                configuration: configuration,
                handler: handler
            ) {
                try await handler.stop()
            }

        case ("POST", "/vm/teardown"):
            return await mutate(
                request: request,
                configuration: configuration,
                handler: handler
            ) {
                try await handler.teardown()
            }

        default:
            return .error("Not found", statusCode: 404)
        }
    }

    private static func mutate(
        request: VMControlHTTPRequest,
        configuration: VMControlConfiguration,
        handler: VMControlHandling,
        operation: () async throws -> VMControlVMResponse
    ) async -> VMControlHTTPResponse {
        guard isAuthorized(request: request, token: configuration.authToken) else {
            return .error("Unauthorized", statusCode: 401)
        }

        do {
            return .json(try await operation())
        } catch let error as VMControlError {
            return .error(error.localizedDescription ?? "VM control failed", statusCode: statusCode(for: error))
        } catch {
            return .error(error.localizedDescription, statusCode: 500)
        }
    }

    static func isAuthorized(request: VMControlHTTPRequest, token: String) -> Bool {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return false }

        let authorization = request.headers["authorization"] ?? request.headers["Authorization"] ?? ""
        if authorization == "Bearer \(trimmedToken)" {
            return true
        }
        return authorization == trimmedToken
    }

    static func statusCode(for error: VMControlError) -> Int {
        switch error {
        case .vmAlreadyRunning, .queueBusy:
            409
        case .vmNotRunning, .baseImageMissing:
            409
        case .vmEngineUnavailable:
            503
        }
    }

    static func parseRequest(from data: Data) -> VMControlHTTPRequest? {
        guard let headerSection = String(data: data, encoding: .utf8) else { return nil }
        guard let headerEnd = headerSection.range(of: "\r\n\r\n") else { return nil }

        let headerLines = headerSection[..<headerEnd.lowerBound].split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = headerLines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            headers[name.lowercased()] = value
        }

        let bodyStart = data.distance(from: data.startIndex, to: headerEnd.upperBound)
        let body = bodyStart < data.count ? data.subdata(in: bodyStart..<data.count) : Data()

        return VMControlHTTPRequest(method: method, path: path, headers: headers, body: body)
    }
}
