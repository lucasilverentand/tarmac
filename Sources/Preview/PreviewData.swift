import Foundation

enum PreviewData {
    static let organizations: [Organization] = [
        Organization(
            name: "acme-corp",
            appId: "111111",
            installationId: 12345,
            labels: ["self-hosted", "macOS", "ARM64"]
        ),
        Organization(
            name: "open-source-org",
            appId: "222222",
            installationId: 67890,
            labels: ["self-hosted", "macOS"]
        ),
    ]

    static let pendingJob = RunnerJob(
        id: 1001,
        organizationName: "acme-corp",
        status: .pending,
        workflowName: "CI",
        repositoryName: "web-app",
        queuedAt: Date().addingTimeInterval(-120)
    )

    static let runningJob = RunnerJob(
        id: 1002,
        organizationName: "open-source-org",
        status: .running,
        workflowName: "Build & Test",
        repositoryName: "ios-sdk",
        queuedAt: Date().addingTimeInterval(-300),
        startedAt: Date().addingTimeInterval(-60)
    )

    static let completedJob = RunnerJob(
        id: 1003,
        organizationName: "acme-corp",
        status: .completed,
        workflowName: "Deploy",
        repositoryName: "backend-api",
        queuedAt: Date().addingTimeInterval(-600),
        startedAt: Date().addingTimeInterval(-540),
        completedAt: Date().addingTimeInterval(-300)
    )

    static let failedJob = RunnerJob(
        id: 1004,
        organizationName: "acme-corp",
        status: .failed,
        workflowName: "Release",
        repositoryName: "infra-tools",
        queuedAt: Date().addingTimeInterval(-900),
        startedAt: Date().addingTimeInterval(-840),
        completedAt: Date().addingTimeInterval(-800),
        failureReason: "VM boot timeout"
    )

    static let vmConfig = VMConfiguration(cpuCount: 4, memorySizeGB: 8, diskSizeGB: 80)
}
