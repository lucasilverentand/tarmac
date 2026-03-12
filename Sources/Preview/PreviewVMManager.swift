import Foundation

@MainActor
final class PreviewVMManager: VMManagerProtocol {
    var isRunning = false
    var currentInstance: VMInstance?
    var baseImageExists = true
    var installProgress: Double = 0

    func createBaseImage(from ipsw: URL, config: VMConfiguration) async throws {
        installProgress = 1.0
        baseImageExists = true
    }

    func bootVM(for jobId: Int64, config: VMConfiguration, sharedDirectory: URL) async throws -> VMInstance {
        let instance = VMInstance(
            id: UUID(),
            jobId: jobId,
            diskImagePath: URL(filePath: "/tmp/disk.img"),
            startedAt: Date(),
            state: .running
        )
        currentInstance = instance
        isRunning = true
        return instance
    }

    func stopVM() async throws {
        isRunning = false
        currentInstance = nil
    }
}
