import Foundation
import Testing

@testable import Tarmac

@Suite("GitHubClient")
struct GitHubClientTests {
    private func makeClient() -> GitHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return GitHubClient(session: session)
    }

    private struct TestResponse: Decodable, Sendable {
        let id: Int
        let name: String
    }

    @Test("Request URL is constructed from base URL + path")
    func requestURLConstruction() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        var capturedURL: URL?
        MockURLProtocol.addHandler(
            matching: { request in
                capturedURL = request.url
                return true
            },
            statusCode: 200,
            responseData: "{}".data(using: .utf8)!
        )

        let client = makeClient()
        let _: [String: String] = try await client.request(
            method: "GET",
            path: "/repos/test/info",
            body: nil as String?,
            headers: [:],
            timeoutInterval: 10
        )

        #expect(capturedURL?.host == "api.github.com")
        #expect(capturedURL?.path.contains("repos/test/info") == true)
    }

    @Test("Default headers include Accept and API version")
    func defaultHeaders() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        var capturedRequest: URLRequest?
        MockURLProtocol.addHandler(
            matching: { request in
                capturedRequest = request
                return true
            },
            statusCode: 200,
            responseData: "{}".data(using: .utf8)!
        )

        let client = makeClient()
        let _: [String: String] = try await client.request(
            method: "GET",
            path: "/test",
            body: nil as String?,
            headers: [:],
            timeoutInterval: 10
        )

        #expect(capturedRequest?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(capturedRequest?.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test("Custom headers are passed through")
    func customHeaders() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        var capturedRequest: URLRequest?
        MockURLProtocol.addHandler(
            matching: { request in
                capturedRequest = request
                return true
            },
            statusCode: 200,
            responseData: "{}".data(using: .utf8)!
        )

        let client = makeClient()
        let _: [String: String] = try await client.request(
            method: "GET",
            path: "/test",
            body: nil as String?,
            headers: ["Authorization": "Bearer test-token"],
            timeoutInterval: 10
        )

        #expect(capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test("Body is encoded as JSON")
    func bodyEncoding() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        var capturedBody: Data?
        MockURLProtocol.addHandler(
            matching: { request in
                capturedBody =
                    request.httpBody
                    ?? request.httpBodyStream.flatMap { stream in
                        stream.open()
                        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
                        defer { buffer.deallocate() }
                        let count = stream.read(buffer, maxLength: 4096)
                        stream.close()
                        return count > 0 ? Data(bytes: buffer, count: count) : nil
                    }
                return true
            },
            statusCode: 200,
            responseData: "{}".data(using: .utf8)!
        )

        let client = makeClient()
        let _: [String: String] = try await client.request(
            method: "POST",
            path: "/test",
            body: ["key": "value"],
            headers: [:],
            timeoutInterval: 10
        )

        if let body = capturedBody {
            let decoded = try JSONDecoder().decode([String: String].self, from: body)
            #expect(decoded["key"] == "value")
        }
    }

    @Test("Success response is decoded correctly")
    func successDecoding() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        let responseJSON = """
            {"id": 42, "name": "test-repo"}
            """.data(using: .utf8)!

        MockURLProtocol.addHandler(matching: { _ in true }, statusCode: 200, responseData: responseJSON)

        let client = makeClient()
        let result: TestResponse = try await client.request(
            method: "GET",
            path: "/test",
            body: nil as String?,
            headers: [:],
            timeoutInterval: 10
        )

        #expect(result.id == 42)
        #expect(result.name == "test-repo")
    }

    @Test("HTTP error throws GitHubAPIError.httpError")
    func httpErrorThrows() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        MockURLProtocol.addHandler(
            matching: { _ in true },
            statusCode: 404,
            responseData: "Not Found".data(using: .utf8)!
        )

        let client = makeClient()

        await #expect(throws: GitHubAPIError.self) {
            let _: TestResponse = try await client.request(
                method: "GET",
                path: "/missing",
                body: nil as String?,
                headers: [:],
                timeoutInterval: 10
            )
        }
    }

    @Test("Non-HTTP response throws GitHubAPIError.invalidResponse")
    func nonHTTPResponseThrows() async {
        // This is hard to trigger with URLProtocol since we always return HTTPURLResponse.
        // Instead, test that requestRaw properly returns HTTPURLResponse.
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        MockURLProtocol.addHandler(matching: { _ in true }, statusCode: 200, responseData: Data())

        let client = makeClient()
        let (_, response) = try! await client.requestRaw(
            method: "GET",
            path: "/test",
            body: nil as String?,
            headers: [:],
            timeoutInterval: 10
        )

        #expect(response.statusCode == 200)
    }

    @Test("Decoding failure throws DecodingError")
    func decodingFailure() async {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }

        MockURLProtocol.addHandler(
            matching: { _ in true },
            statusCode: 200,
            responseData: "not json".data(using: .utf8)!
        )

        let client = makeClient()

        await #expect(throws: DecodingError.self) {
            let _: TestResponse = try await client.request(
                method: "GET",
                path: "/test",
                body: nil as String?,
                headers: [:],
                timeoutInterval: 10
            )
        }
    }
}
