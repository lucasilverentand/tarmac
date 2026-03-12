import Foundation

@MainActor
protocol VMManagerProtocol: AnyObject, Sendable {
    var isRunning: Bool { get }
    var currentInstance: VMInstance? { get }
    func createBaseImage(from ipsw: URL, config: VMConfiguration) async throws
    func bootVM(for jobId: Int64, config: VMConfiguration, sharedDirectory: URL) async throws -> VMInstance
    func stopVM() async throws
    var baseImageExists: Bool { get }
    var installProgress: Double { get }
}
