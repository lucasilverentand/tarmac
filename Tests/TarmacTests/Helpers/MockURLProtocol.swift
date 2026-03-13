import Foundation

@testable import Tarmac

/// A URLProtocol subclass that intercepts all requests and returns canned responses.
/// Register handlers before making requests to configure responses for specific URL patterns.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handlers: [(URLRequest) -> (Data, HTTPURLResponse)?] = []

    static func reset() {
        handlers = []
    }

    static func addHandler(
        forPathContaining fragment: String,
        statusCode: Int = 200,
        responseData: Data = Data()
    ) {
        handlers.append { request in
            guard let url = request.url, url.path.contains(fragment) else { return nil }
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (responseData, response)
        }
    }

    static func addHandler(
        matching predicate: @escaping (URLRequest) -> Bool,
        statusCode: Int = 200,
        responseData: Data = Data()
    ) {
        handlers.append { request in
            guard predicate(request) else { return nil }
            let url = request.url ?? URL(string: "https://api.github.com")!
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (responseData, response)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        for handler in Self.handlers {
            if let (data, response) = handler(request) {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
                return
            }
        }

        // No handler matched — return 500
        let url = request.url ?? URL(string: "https://api.github.com")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil
        )!
        let errorData = "MockURLProtocol: no handler matched \(request.url?.absoluteString ?? "nil")".data(
            using: .utf8
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: errorData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
