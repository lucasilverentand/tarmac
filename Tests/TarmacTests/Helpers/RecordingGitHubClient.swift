import Foundation

@testable import Tarmac

actor RecordingGitHubClient: GitHubClientProtocol {
    struct RecordedRequest: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let bodyData: Data?
    }

    private(set) var requests: [RecordedRequest] = []
    private var responseHandlers: [(String) -> Data?] = []
    private var defaultResponseData: Data

    var requestCount: Int { requests.count }

    init(defaultResponseJSON: Data = "{}".data(using: .utf8)!) {
        self.defaultResponseData = defaultResponseJSON
    }

    func setDefaultResponse(_ data: Data) {
        defaultResponseData = data
    }

    func addResponse(forPathContaining pathFragment: String, json: Data) {
        responseHandlers.append { path in
            path.contains(pathFragment) ? json : nil
        }
    }

    private func recordAndRespond(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String]
    ) -> Data {
        let bodyData: Data?
        if let body {
            bodyData = try? JSONEncoder().encode(body)
        } else {
            bodyData = nil
        }

        requests.append(
            RecordedRequest(
                method: method,
                path: path,
                headers: headers,
                bodyData: bodyData
            )
        )

        for handler in responseHandlers {
            if let data = handler(path) {
                return data
            }
        }

        return defaultResponseData
    }

    nonisolated func request<T: Decodable & Sendable>(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String],
        timeoutInterval: TimeInterval
    ) async throws -> T {
        let data = await recordAndRespond(method: method, path: path, body: body, headers: headers)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    nonisolated func requestRaw(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String],
        timeoutInterval: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        let data = await recordAndRespond(method: method, path: path, body: body, headers: headers)
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com\(path)")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
