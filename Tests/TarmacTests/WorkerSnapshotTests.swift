import Foundation
import Testing

@testable import Tarmac

@Suite("Worker snapshots")
struct WorkerSnapshotTests {
    @Test("resource usage normalizes percentages and fractions")
    func normalizesResourceUsage() {
        let usage = WorkerResourceUsage(
            sampledAt: Date(),
            cpuPercent: 125,
            memoryUsedBytes: 6_000,
            memoryTotalBytes: 8_000,
            diskUsedBytes: 20_000,
            diskTotalBytes: 80_000
        )

        #expect(usage.normalizedCPUPercent == 100)
        #expect(usage.memoryFraction == 0.75)
        #expect(usage.diskFraction == 0.25)
    }

    @Test("resource samples report staleness against an explicit clock")
    func reportsStaleSamples() {
        let usage = WorkerResourceUsage(
            sampledAt: Date(timeIntervalSince1970: 100),
            cpuPercent: 10,
            memoryUsedBytes: 1,
            memoryTotalBytes: 2,
            diskUsedBytes: 1,
            diskTotalBytes: 2
        )

        #expect(!usage.isStale(at: Date(timeIntervalSince1970: 110), after: 15))
        #expect(usage.isStale(at: Date(timeIntervalSince1970: 116), after: 15))
    }

    @Test("task summaries preserve worker-facing job context")
    func preservesTaskContext() {
        var job = TestFactories.makeJob(id: 42, org: "SevenTwo")
        job.workflowName = "Build & Test"
        job.repositoryName = "tarmac"
        job.runnerName = "ephemeral-42"
        job.status = .running

        let summary = WorkerTaskSummary(job: job)

        #expect(summary.id == 42)
        #expect(summary.organizationName == "SevenTwo")
        #expect(summary.workflowName == "Build & Test")
        #expect(summary.repositoryName == "tarmac")
        #expect(summary.runnerName == "ephemeral-42")
        #expect(summary.status == .running)
    }
}
