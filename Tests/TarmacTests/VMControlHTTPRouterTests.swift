import Foundation
import Testing

@testable import Tarmac

@Suite("VMControlHTTPRouter")
struct VMControlHTTPRouterTests {
    @Test("GET /health returns service status")
    @MainActor
    func healthEndpoint() async {
        let handler = MockVMControlHandler()
        let response = await VMControlHTTPRouter.handle(
            request: VMControlHTTPRequest(method: "GET", path: "/health"),
            configuration: VMControlConfiguration(isEnabled: true, authToken: "secret"),
            handler: handler
        )

        #expect(response.statusCode == 200)
        let payload = try? JSONDecoder().decode(VMControlHealthResponse.self, from: response.body)
        #expect(payload?.status == "ok")
        #expect(payload?.service == "tarmac-vm-control")
    }

    @Test("GET /vm returns current VM state")
    @MainActor
    func vmStateEndpoint() async {
        let handler = MockVMControlHandler()
        handler.vmStateResponse = VMControlVMResponse(
            instance: nil,
            isRunning: true,
            baseImageExists: true,
            baseImageVerified: false
        )

        let response = await VMControlHTTPRouter.handle(
            request: VMControlHTTPRequest(method: "GET", path: "/vm"),
            configuration: VMControlConfiguration(isEnabled: true, authToken: "secret"),
            handler: handler
        )

        #expect(response.statusCode == 200)
        let payload = try? JSONDecoder().decode(VMControlVMResponse.self, from: response.body)
        #expect(payload?.isRunning == true)
        #expect(payload?.baseImageVerified == false)
    }

    @Test("POST /vm/boot requires bearer token")
    @MainActor
    func bootRequiresAuth() async {
        let handler = MockVMControlHandler()
        let configuration = VMControlConfiguration(isEnabled: true, authToken: "secret-token")

        let unauthorized = await VMControlHTTPRouter.handle(
            request: VMControlHTTPRequest(method: "POST", path: "/vm/boot"),
            configuration: configuration,
            handler: handler
        )
        #expect(unauthorized.statusCode == 401)
        #expect(handler.bootCallCount == 0)

        let authorized = await VMControlHTTPRouter.handle(
            request: VMControlHTTPRequest(
                method: "POST",
                path: "/vm/boot",
                headers: ["authorization": "Bearer secret-token"]
            ),
            configuration: configuration,
            handler: handler
        )
        #expect(authorized.statusCode == 200)
        #expect(handler.bootCallCount == 1)
    }

    @Test("POST /vm/stop and teardown forward to handler")
    @MainActor
    func lifecycleEndpoints() async {
        let handler = MockVMControlHandler()
        let configuration = VMControlConfiguration(isEnabled: true, authToken: "token")
        let headers = ["authorization": "Bearer token"]

        _ = await VMControlHTTPRouter.handle(
            request: VMControlHTTPRequest(method: "POST", path: "/vm/stop", headers: headers),
            configuration: configuration,
            handler: handler
        )
        _ = await VMControlHTTPRouter.handle(
            request: VMControlHTTPRequest(method: "POST", path: "/vm/teardown", headers: headers),
            configuration: configuration,
            handler: handler
        )

        #expect(handler.stopCallCount == 1)
        #expect(handler.teardownCallCount == 1)
    }

    @Test("VM control errors map to HTTP status codes")
    @MainActor
    func errorStatusCodes() async {
        let handler = MockVMControlHandler()
        handler.error = VMControlError.vmAlreadyRunning
        let configuration = VMControlConfiguration(isEnabled: true, authToken: "token")

        let response = await VMControlHTTPRouter.handle(
            request: VMControlHTTPRequest(
                method: "POST",
                path: "/vm/boot",
                headers: ["authorization": "Bearer token"]
            ),
            configuration: configuration,
            handler: handler
        )

        #expect(response.statusCode == 409)
        let payload = try? JSONDecoder().decode(VMControlErrorResponse.self, from: response.body)
        #expect(payload?.error == VMControlError.vmAlreadyRunning.localizedDescription)
    }

    @Test("Unknown routes return 404")
    @MainActor
    func notFound() async {
        let handler = MockVMControlHandler()
        let response = await VMControlHTTPRouter.handle(
            request: VMControlHTTPRequest(method: "GET", path: "/missing"),
            configuration: VMControlConfiguration(),
            handler: handler
        )

        #expect(response.statusCode == 404)
    }

    @Test("Authorization helper accepts bearer and raw token")
    func authorizationHelper() {
        let request = VMControlHTTPRequest(
            method: "POST",
            path: "/vm/boot",
            headers: ["authorization": "Bearer abc"]
        )
        #expect(VMControlHTTPRouter.isAuthorized(request: request, token: "abc"))
        #expect(
            VMControlHTTPRouter.isAuthorized(
                request: VMControlHTTPRequest(method: "POST", path: "/vm/boot", headers: ["authorization": "abc"]),
                token: "abc"
            )
        )
        #expect(!VMControlHTTPRouter.isAuthorized(request: request, token: "wrong"))
    }

    @Test("HTTP request parser reads headers and body")
    func requestParser() {
        let raw = """
        POST /vm/boot HTTP/1.1\r
        Host: 127.0.0.1\r
        Authorization: Bearer token\r
        Content-Length: 4\r
        \r
        test
        """.data(using: .utf8)!

        let request = VMControlHTTPRouter.parseRequest(from: raw)
        #expect(request?.method == "POST")
        #expect(request?.path == "/vm/boot")
        #expect(request?.headers["authorization"] == "Bearer token")
        #expect(String(data: request?.body ?? Data(), encoding: .utf8) == "test")
    }
}
