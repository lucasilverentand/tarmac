import Foundation

@Observable
@MainActor
final class VMStatusViewModel {
    var activeVM: VMInstance?
    var baseImageExists: Bool = false
    var baseImageVerified: Bool = false
    var storageHealth: StorageHealth?
    var readiness: RunnerHostReadiness = .unchecked
    var runnerReconciliation: RunnerReconciliationReport = .empty
    var installProgress: Double = 0
    var isInstalling: Bool = false

    var readyForJobs: Bool {
        readiness.isReady
    }

    var readinessStatusText: String {
        readiness.statusText
    }
}
