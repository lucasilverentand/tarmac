import Foundation

@MainActor
protocol VMControlHandling: AnyObject {
    func health() -> VMControlHealthResponse
    func vmState() -> VMControlVMResponse
    func boot() async throws -> VMControlVMResponse
    func stop() async throws -> VMControlVMResponse
    func teardown() async throws -> VMControlVMResponse
}
