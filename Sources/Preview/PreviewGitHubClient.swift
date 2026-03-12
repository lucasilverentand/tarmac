import Foundation

struct PreviewGitHubClient: GitHubClientProtocol {
    var nextResponse: (any Sendable)?

    func request<T: Decodable & Sendable>(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String],
        timeoutInterval: TimeInterval
    ) async throws -> T {
        if let response = nextResponse as? T { return response }
        throw GitHubAPIError.httpError(statusCode: 404, message: "Preview: no response configured")
    }

    func requestRaw(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String],
        timeoutInterval: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        (Data(), HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
