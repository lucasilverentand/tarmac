import Foundation
import Testing

@testable import Tarmac

@Suite("GiteaClient", .serialized)
struct GiteaClientTests {
    private struct Version: Decodable, Sendable { let version: String }

    @Test("Requests use the instance API root and token authentication")
    func requestConstruction() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.addHandler(
            matching: { request in
                request.url?.absoluteString == "https://git.example.test/api/v1/version"
                    && request.value(forHTTPHeaderField: "Authorization") == "token secret"
                    && request.value(forHTTPHeaderField: "Accept") == "application/json"
            },
            responseData: Data(#"{"version":"1.25.1"}"#.utf8)
        )

        let result: Version = try await makeClient().request(
            method: "GET",
            path: "/version",
            body: nil,
            token: "secret",
            timeoutInterval: 5
        )
        #expect(result.version == "1.25.1")
    }

    @Test("Authentication errors preserve the HTTP status")
    func authenticationError() async {
        MockURLProtocol.reset()
        MockURLProtocol.addHandler(
            forPathContaining: "/api/v1/version",
            statusCode: 401,
            responseData: Data("denied".utf8)
        )

        await #expect(throws: GiteaAPIError.self) {
            let _: Version = try await makeClient().request(
                method: "GET",
                path: "/version",
                body: nil,
                token: "bad",
                timeoutInterval: 5
            )
        }
    }

    @Test("Malformed responses produce a decoding error")
    func malformedResponse() async {
        MockURLProtocol.reset()
        MockURLProtocol.addHandler(forPathContaining: "/api/v1/version", responseData: Data("{}".utf8))

        await #expect(throws: GiteaAPIError.self) {
            let _: Version = try await makeClient().request(
                method: "GET",
                path: "/version",
                body: nil,
                token: "token",
                timeoutInterval: 5
            )
        }
    }

    private func makeClient() -> GiteaClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return GiteaClient(
            instanceURL: URL(string: "https://git.example.test")!,
            session: URLSession(configuration: configuration)
        )
    }
}
