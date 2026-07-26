import Foundation

protocol GiteaClientProtocol: Sendable {
    func request<T: Decodable & Sendable>(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        token: String?,
        timeoutInterval: TimeInterval
    ) async throws -> T

    func requestRaw(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        token: String?,
        timeoutInterval: TimeInterval
    ) async throws -> (Data, HTTPURLResponse)
}

struct GiteaClient: GiteaClientProtocol {
    let instanceURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    init(instanceURL: URL, session: URLSession = .shared) {
        self.instanceURL = instanceURL
        self.session = session
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func request<T: Decodable & Sendable>(
        method: String,
        path: String,
        body: (any Encodable & Sendable)? = nil,
        token: String? = nil,
        timeoutInterval: TimeInterval = 30
    ) async throws -> T {
        let (data, response) = try await requestRaw(
            method: method,
            path: path,
            body: body,
            token: token,
            timeoutInterval: timeoutInterval
        )
        guard (200..<300).contains(response.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GiteaAPIError.httpError(statusCode: response.statusCode, message: message)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GiteaAPIError.decodingError(error.localizedDescription)
        }
    }

    func requestRaw(
        method: String,
        path: String,
        body: (any Encodable & Sendable)? = nil,
        token: String? = nil,
        timeoutInterval: TimeInterval = 30
    ) async throws -> (Data, HTTPURLResponse) {
        let apiRoot = instanceURL.appendingPathComponent("api/v1", isDirectory: true)
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: normalizedPath, relativeTo: apiRoot)?.absoluteURL else {
            throw GiteaAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw GiteaAPIError.invalidResponse
        }
        return (data, response)
    }
}

enum GiteaAPIError: Error, LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case missingToken
    case httpError(statusCode: Int, message: String)
    case decodingError(String)
    case unsupportedVersion(String)
    case noCompatibleRunner
    case missingChecksum
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed
    case ambiguousClaim(String)
    case jobCancelledBeforeClaim(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The Gitea instance URL is invalid."
        case .invalidResponse: "Gitea returned an invalid response."
        case .missingToken: "No Gitea API token is stored in Keychain."
        case .httpError(let statusCode, let message): "Gitea HTTP \(statusCode): \(message)"
        case .decodingError(let detail): "Could not decode the Gitea response: \(detail)"
        case .unsupportedVersion(let version): "Gitea \(version) is unsupported; version 1.25 or newer is required."
        case .noCompatibleRunner: "No stable macOS ARM64 act_runner release is available."
        case .missingChecksum: "The act_runner release does not publish a usable SHA-256 checksum."
        case .checksumMismatch(let expected, let actual):
            "act_runner checksum mismatch (expected \(expected), got \(actual))."
        case .extractionFailed: "Could not install the Gitea act_runner artifact."
        case .ambiguousClaim(let runnerName): "More than one Gitea job is assigned to runner \(runnerName)."
        case .jobCancelledBeforeClaim(let jobID): "Gitea job \(jobID) left the queue before a runner claimed it."
        }
    }
}
