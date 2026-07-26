import Foundation

enum WorkerKind: Equatable, Sendable {
    case githubRunner
    case manualControl
}

enum WorkerLifecycleState: Equatable, Sendable {
    case starting
    case working
    case warmIdle
    case running
    case stopping
    case stopped
    case failed

    var isActive: Bool {
        switch self {
        case .starting, .working, .warmIdle, .running, .stopping:
            true
        case .stopped, .failed:
            false
        }
    }
}

struct WorkerTaskSummary: Equatable, Sendable {
    let id: Int64
    let organizationName: String
    let workflowName: String?
    let repositoryName: String?
    let runnerName: String?
    let status: JobStatus
    let startedAt: Date?

    init(job: RunnerJob) {
        id = job.id
        organizationName = job.organizationName
        workflowName = job.workflowName
        repositoryName = job.repositoryName
        runnerName = job.runnerName ?? job.runnerLease?.runnerName
        status = job.status
        startedAt = job.startedAt
    }
}

struct WorkerResourceUsage: Codable, Equatable, Sendable {
    let sampledAt: Date
    let cpuPercent: Double
    let memoryUsedBytes: Int64
    let memoryTotalBytes: Int64
    let diskUsedBytes: Int64
    let diskTotalBytes: Int64

    var normalizedCPUPercent: Double {
        min(max(cpuPercent, 0), 100)
    }

    var memoryFraction: Double {
        fraction(used: memoryUsedBytes, total: memoryTotalBytes)
    }

    var diskFraction: Double {
        fraction(used: diskUsedBytes, total: diskTotalBytes)
    }

    func isStale(at date: Date = Date(), after interval: TimeInterval = 15) -> Bool {
        date.timeIntervalSince(sampledAt) > interval
    }

    private func fraction(used: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(used) / Double(total), 0), 1)
    }
}

struct WorkerSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let runnerPoolID: UUID?
    let runnerPoolName: String?
    let releaseChannel: RunnerReleaseChannel?
    let routingLabels: [String]
    let kind: WorkerKind
    let lifecycleState: WorkerLifecycleState
    let vmState: VMInstance.VMState
    let jobId: Int64?
    let diskImagePath: URL
    let startedAt: Date
    let configuration: VMConfiguration
    let task: WorkerTaskSummary?
    let resourceUsage: WorkerResourceUsage?
    let diskImageAllocatedBytes: Int64?
    let warmRunnerJobsServed: Int?
    let warmRunnerLastActivityAt: Date?
    let automaticShutdownAt: Date?
    let isPinned: Bool

    init(
        id: UUID,
        runnerPoolID: UUID? = nil,
        runnerPoolName: String? = nil,
        releaseChannel: RunnerReleaseChannel? = nil,
        routingLabels: [String] = [],
        kind: WorkerKind,
        lifecycleState: WorkerLifecycleState,
        vmState: VMInstance.VMState,
        jobId: Int64?,
        diskImagePath: URL,
        startedAt: Date,
        configuration: VMConfiguration,
        task: WorkerTaskSummary?,
        resourceUsage: WorkerResourceUsage?,
        diskImageAllocatedBytes: Int64?,
        warmRunnerJobsServed: Int?,
        warmRunnerLastActivityAt: Date?,
        automaticShutdownAt: Date?,
        isPinned: Bool
    ) {
        self.id = id
        self.runnerPoolID = runnerPoolID
        self.runnerPoolName = runnerPoolName
        self.releaseChannel = releaseChannel
        self.routingLabels = routingLabels
        self.kind = kind
        self.lifecycleState = lifecycleState
        self.vmState = vmState
        self.jobId = jobId
        self.diskImagePath = diskImagePath
        self.startedAt = startedAt
        self.configuration = configuration
        self.task = task
        self.resourceUsage = resourceUsage
        self.diskImageAllocatedBytes = diskImageAllocatedBytes
        self.warmRunnerJobsServed = warmRunnerJobsServed
        self.warmRunnerLastActivityAt = warmRunnerLastActivityAt
        self.automaticShutdownAt = automaticShutdownAt
        self.isPinned = isPinned
    }

    var displayName: String {
        if let runnerName = task?.runnerName, !runnerName.isEmpty {
            return runnerName
        }
        if let runnerPoolName, !runnerPoolName.isEmpty {
            return runnerPoolName
        }
        switch kind {
        case .githubRunner:
            return "Runner \(id.uuidString.prefix(8))"
        case .manualControl:
            return "Manual VM \(id.uuidString.prefix(8))"
        }
    }
}
