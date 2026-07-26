import Foundation

enum ActiveVMRole: Equatable, Sendable {
    case jobRunner
    case warmRunnerActive
    case warmRunnerIdle
    case manualControl

    var displayTitle: String {
        switch self {
        case .jobRunner:
            "Running"
        case .warmRunnerActive:
            "Warm runner active"
        case .warmRunnerIdle:
            "Warm runner idle"
        case .manualControl:
            "Manual control"
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
        case .manualControl:
            "VM running under local control"
        }
    }

    var isWarmRunner: Bool {
        switch self {
        case .jobRunner, .manualControl:
            false
        case .warmRunnerActive, .warmRunnerIdle:
            true
        }
    }
}

enum IdleVMControlOperation: Equatable, Sendable {
    case starting
    case restarting
    case shuttingDown

    var statusText: LocalizedStringResource {
        switch self {
        case .starting:
            "Prewarming idle machine…"
        case .restarting:
            "Restarting idle machine…"
        case .shuttingDown:
            "Shutting down idle machine…"
        }
    }
}

@Observable
@MainActor
final class VMStatusViewModel {
    var workers: [WorkerSnapshot] = []
    var activeVM: VMInstance?
    var activeVMRole: ActiveVMRole?
    var warmRunnerJobsServed: Int?
    var warmRunnerLastActivityAt: Date?
    var warmRunnerIdleShutdownAt: Date?
    var isWarmRunnerPinned = false
    var idleVMControlOperation: IdleVMControlOperation?
    var idleVMControlErrorMessage: String?
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

    var activeWorkerCount: Int {
        workers.count { $0.lifecycleState.isActive }
    }

    var workingWorkerCount: Int {
        workers.count { $0.lifecycleState == .working }
    }

    var warmIdleWorkerCount: Int {
        workers.count { $0.lifecycleState == .warmIdle }
    }

    var canControlIdleVM: Bool {
        activeVM != nil && activeVMRole == .warmRunnerIdle && idleVMControlOperation == nil
    }

    var readinessStatusText: String {
        readiness.statusText
    }
}
