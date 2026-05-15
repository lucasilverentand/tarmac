import Foundation

@Observable
@MainActor
final class VMStatusViewModel {
    var activeVM: VMInstance?
    var baseImageExists: Bool = false
    var baseImageVerified: Bool = false
    var storageHealth: StorageHealth?
    var installProgress: Double = 0
    var isInstalling: Bool = false

    var readyForJobs: Bool {
        baseImageExists && baseImageVerified && (storageHealth?.isReadyForJobs ?? false)
    }
}
