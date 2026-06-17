import Foundation

enum ActiveVMRole: Equatable, Sendable {
    case jobRunner
    case warmRunnerActive
    case warmRunnerIdle

    var displayTitle: String {
        switch self {
        case .jobRunner:
            "Running"
        case .warmRunnerActive:
            "Warm runner active"
        case .warmRunnerIdle:
            "Warm runner idle"
        }
    }

    var statusText: String {
        switch self {
        case .jobRunner:
            "Job VM running"
        case .warmRunnerActive:
            "Warm runner handling job"
        case .warmRunnerIdle:
            "Warm runner waiting for reuse"
        }
    }

    var isWarmRunner: Bool {
        switch self {
        case .jobRunner:
            false
        case .warmRunnerActive, .warmRunnerIdle:
            true
        }
    }
}

@Observable
@MainActor
final class VMStatusViewModel {
    var activeVM: VMInstance?
    var activeVMRole: ActiveVMRole?
    var warmRunnerJobsServed: Int?
    var warmRunnerLastActivityAt: Date?
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

    var hasDisplayableVM: Bool {
        activeVM != nil
    }

    var readinessStatusText: String {
        readiness.statusText
    }
}
