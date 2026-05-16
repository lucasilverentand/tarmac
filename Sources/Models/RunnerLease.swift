import Foundation

struct RunnerJobRequest: Codable, Equatable, Sendable {
    let jobId: Int64
    let organizationName: String
    let runnerRequestId: Int64?
    let workflowName: String?
    let repositoryName: String?
    let queuedAt: Date

    init(job: RunnerJob) {
        self.jobId = job.id
        self.organizationName = job.organizationName
        self.runnerRequestId = job.runnerRequestId
        self.workflowName = job.workflowName
        self.repositoryName = job.repositoryName
        self.queuedAt = job.queuedAt
    }
}

enum RunnerLeaseProvider: String, Codable, Sendable {
    case github
}

struct ProviderRunnerReference: Codable, Equatable, Sendable {
    let provider: RunnerLeaseProvider
    var runnerId: Int64?
    var runnerName: String
    var labels: [String]
}

struct RunnerExecutionAttempt: Codable, Equatable, Sendable {
    let vmInstanceId: UUID
    let diskImagePath: String
    let sharedDirectoryPath: String
    let startedAt: Date
    var completedAt: Date?
}

struct LogBundleReference: Codable, Equatable, Sendable {
    let path: String
    let preservedAt: Date
}

enum RunnerLeaseCleanupState: String, Codable, Sendable {
    case pending
    case vmRunning
    case failed
    case completed
}

struct RunnerLease: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let request: RunnerJobRequest
    var runner: ProviderRunnerReference
    let createdAt: Date
    var updatedAt: Date
    var executionAttempt: RunnerExecutionAttempt?
    var logBundle: LogBundleReference?
    var cleanupState: RunnerLeaseCleanupState

    var jobId: Int64 { request.jobId }
    var runnerName: String { runner.runnerName }
    var vmInstanceId: UUID? { executionAttempt?.vmInstanceId }
    var diagnosticsBundlePath: String? { logBundle?.path }

    init(
        id: UUID = UUID(),
        job: RunnerJob,
        runnerName: String,
        labels: [String],
        provider: RunnerLeaseProvider = .github,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.request = RunnerJobRequest(job: job)
        self.runner = ProviderRunnerReference(
            provider: provider,
            runnerId: nil,
            runnerName: runnerName,
            labels: labels
        )
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.cleanupState = .pending
    }

    mutating func recordVMStarted(
        vmInstanceId: UUID,
        diskImagePath: String,
        sharedDirectoryPath: String,
        now: Date = Date()
    ) {
        executionAttempt = RunnerExecutionAttempt(
            vmInstanceId: vmInstanceId,
            diskImagePath: diskImagePath,
            sharedDirectoryPath: sharedDirectoryPath,
            startedAt: now,
            completedAt: nil
        )
        cleanupState = .vmRunning
        updatedAt = now
    }

    mutating func recordDiagnosticsBundle(path: String, now: Date = Date()) {
        logBundle = LogBundleReference(path: path, preservedAt: now)
        updatedAt = now
    }

    mutating func recordCleanupState(_ state: RunnerLeaseCleanupState, now: Date = Date()) {
        if state == .completed, var attempt = executionAttempt, attempt.completedAt == nil {
            attempt.completedAt = now
            executionAttempt = attempt
        }
        cleanupState = state
        updatedAt = now
    }
}
