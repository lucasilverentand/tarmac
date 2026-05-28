import Foundation

@testable import Tarmac

actor RecordingGitHubClient: GitHubClientProtocol {
    struct RecordedRequest: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let bodyData: Data?
    }

    struct StubbedResponse: Sendable {
        let data: Data
        let statusCode: Int
        let headers: [String: String]
    }

    private(set) var requests: [RecordedRequest] = []
    private var responseHandlers: [@Sendable (String, String) -> StubbedResponse?] = []
    private var defaultResponse: StubbedResponse

    var requestCount: Int { requests.count }

    init(defaultResponseJSON: Data = "{}".data(using: .utf8)!) {
        self.defaultResponse = StubbedResponse(data: defaultResponseJSON, statusCode: 200, headers: [:])
    }

    func setDefaultResponse(_ data: Data) {
        defaultResponse = StubbedResponse(data: data, statusCode: 200, headers: [:])
    }

    func addResponse(forPathContaining pathFragment: String, json: Data) {
        addRawResponse(forPathContaining: pathFragment, statusCode: 200, json: json)
    }

    func addRawResponse(
        forPathContaining pathFragment: String,
        method: String? = nil,
        excludingPathContaining excludedPathFragment: String? = nil,
        statusCode: Int,
        headers: [String: String] = [:],
        json: Data
    ) {
        responseHandlers.append { requestMethod, path in
            guard path.contains(pathFragment), method == nil || method == requestMethod else {
                return nil
            }
            if let excludedPathFragment, path.contains(excludedPathFragment) {
                return nil
            }
            return StubbedResponse(data: json, statusCode: statusCode, headers: headers)
        }
    }

    private func recordAndRespond(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String]
    ) -> StubbedResponse {
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
            if let response = handler(method, path) {
                return response
            }
        }

        return defaultResponse
    }

    nonisolated func request<T: Decodable & Sendable>(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String],
        timeoutInterval: TimeInterval
    ) async throws -> T {
        let response = await recordAndRespond(method: method, path: path, body: body, headers: headers)
        guard (200..<300).contains(response.statusCode) else {
            let message = String(data: response.data, encoding: .utf8) ?? "Unknown error"
            throw GitHubAPIError.httpError(statusCode: response.statusCode, message: message)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: response.data)
    }

    nonisolated func requestRaw(
        method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        headers: [String: String],
        timeoutInterval: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        let stub = await recordAndRespond(method: method, path: path, body: body, headers: headers)
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com\(path)")!,
            statusCode: stub.statusCode,
            httpVersion: nil,
            headerFields: stub.headers
        )!
        return (stub.data, response)
    }
}
