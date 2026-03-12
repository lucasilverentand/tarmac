import Foundation

struct GitHubClient: GitHubClientProtocol {
    private let baseURL = URL(string: "https://api.github.com")!
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func request<T: Decodable & Sendable>(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String],
        timeoutInterval: TimeInterval = 30
    ) async throws -> T {
        let (data, response) = try await requestRaw(
            method: method,
            path: path,
            body: body,
            headers: headers,
            timeoutInterval: timeoutInterval
        )

        guard (200..<300).contains(response.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            Log.github.error("GitHub API error \(response.statusCode): \(message)")
            throw GitHubAPIError.httpError(statusCode: response.statusCode, message: message)
        }

        return try decoder.decode(T.self, from: data)
    }

    func requestRaw(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String],
        timeoutInterval: TimeInterval = 30
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval

        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubAPIError.invalidResponse
        }

        return (data, httpResponse)
    }
}

enum GitHubAPIError: Error, LocalizedError, Sendable {
    case httpError(statusCode: Int, message: String)
    case invalidResponse
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let message): "HTTP \(code): \(message)"
        case .invalidResponse: "Invalid response from GitHub API"
        case .decodingError(let detail): "Decoding error: \(detail)"
        }
    }
}
