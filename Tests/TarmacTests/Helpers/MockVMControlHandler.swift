import Foundation

@testable import Tarmac

@MainActor
final class MockVMControlHandler: VMControlHandling {
    private(set) var bootCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var teardownCallCount = 0

    var healthResponse = VMControlHealthResponse(status: "ok", service: "tarmac-vm-control")
    var vmStateResponse = VMControlVMResponse(
        instance: nil,
        isRunning: false,
        baseImageExists: true,
        baseImageVerified: true
    )
    var bootResponse: VMControlVMResponse?
    var stopResponse: VMControlVMResponse?
    var teardownResponse: VMControlVMResponse?
    var error: Error?

    func health() -> VMControlHealthResponse {
        healthResponse
    }

    func vmState() -> VMControlVMResponse {
        vmStateResponse
    }

    func boot() async throws -> VMControlVMResponse {
        bootCallCount += 1
        if let error { throw error }
        return bootResponse ?? vmStateResponse
    }

    func stop() async throws -> VMControlVMResponse {
        stopCallCount += 1
        if let error { throw error }
        return stopResponse ?? vmStateResponse
    }

    func teardown() async throws -> VMControlVMResponse {
        teardownCallCount += 1
        if let error { throw error }
        return teardownResponse ?? vmStateResponse
    }
}
