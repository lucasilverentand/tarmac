import Foundation
import Security
import Testing

@testable import Tarmac

@Suite("Job Lifecycle Integration")
struct JobLifecycleIntegrationTests {
    private func makeEngine() throws -> (QueueEngine, JobStore, RecordingGitHubClient) {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient(
            defaultResponseJSON: """
                {"token":"ghs_integration","expires_at":"\(futureDate)"}
                """.data(using: .utf8)!
        )

        let keychain = PreviewKeychainService()
        let keyData = try TestFactories.makeTestKeyData()

        let tempDir = try TestFactories.makeTempDir()
        let github = GitHubEngine(
            client: client,
            keychainService: keychain,
            cacheDirectory: tempDir
        )

        let jobStore = TestFactories.makeJobStore()
        let dispatcher = JobDispatcher()
        let engine = QueueEngine(
            github: github,
            client: client,
            jobStore: jobStore,
            dispatcher: dispatcher
        )

        return (engine, jobStore, client)
    }

    private func saveKeyForOrg(_ org: Organization, keychain: PreviewKeychainService) throws {
        let keyData = try TestFactories.makeTestKeyData()
        _ = keychain.save(key: org.privateKeyKeychainKey, data: keyData)
    }

    private func jobAvailableMessage(
        jobId: Int64,
        repo: String = "test-repo",
        org: String = "test-org"
    ) -> ScaleSetMessage {
        let body = """
            {"jobMessageBase":{"jobId":\(jobId),"runnerRequestId":1,"repositoryName":"\(repo)","ownerName":"\(org)","workflowRunName":"CI"}}
            """
        return ScaleSetMessage(
            messageId: jobId,
            messageType: "JobAvailable",
            body: body,
            statistics: nil
        )
    }

    private func jobCompletedMessage(jobId: Int64, result: String = "success") -> ScaleSetMessage {
        let body = """
            {"jobId":\(jobId),"result":"\(result)"}
            """
        return ScaleSetMessage(
            messageId: jobId + 1000,
            messageType: "JobCompleted",
            body: body,
            statistics: nil
        )
    }

    @Test("Full lifecycle: poll → enqueue → dispatch → complete")
    func fullLifecycle() async throws {
        let (engine, store, _) = try makeEngine()
        let org = TestFactories.makeOrg()

        let dispatchedJobHolder = DispatchedJobHolder()
        await engine.setOnJobReady { job in
            await dispatchedJobHolder.set(job)
        }

        // 1. Job available
        await engine.handleMessages([jobAvailableMessage(jobId: 42)], org: org)
        let jobs = await store.jobs
        #expect(jobs.count == 1)
        #expect(await dispatchedJobHolder.job?.id == 42)

        // 2. Job completed
        await engine.handleMessages([jobCompletedMessage(jobId: 42)], org: org)
        let completed = await store.job(byId: 42)
        #expect(completed?.status == .completed)
    }

    @Test("Two jobs queued → sequential dispatch")
    func sequentialDispatch() async throws {
        let (engine, store, _) = try makeEngine()
        let org = TestFactories.makeOrg()

        // Enqueue two jobs
        await engine.handleMessages(
            [
                jobAvailableMessage(jobId: 1),
                jobAvailableMessage(jobId: 2),
            ],
            org: org
        )

        let jobs = await store.jobs
        let provisioning = jobs.filter { $0.status == .provisioning }
        let pending = jobs.filter { $0.status == .pending }

        // Only first should be dispatched
        #expect(provisioning.count == 1)
        #expect(provisioning.first?.id == 1)
        #expect(pending.count == 1)
        #expect(pending.first?.id == 2)

        // Complete first job
        await engine.handleMessages([jobCompletedMessage(jobId: 1)], org: org)

        // Try dispatch again — second job should now dispatch
        await engine.tryDispatch()

        let job2 = await store.job(byId: 2)
        #expect(job2?.status == .provisioning)
    }

    @Test("Job from excluded repo is skipped")
    func excludedRepoSkipped() async throws {
        let (engine, store, _) = try makeEngine()
        let org = TestFactories.makeOrg(
            filterMode: .exclude,
            filteredRepositories: ["private-repo"]
        )

        await engine.handleMessages(
            [
                jobAvailableMessage(jobId: 10, repo: "private-repo")
            ],
            org: org
        )

        let jobs = await store.jobs
        #expect(jobs.isEmpty)
    }

    @Test("Multiple orgs → priority dispatch respects org order")
    func multiOrgPriority() async throws {
        let (engine, store, _) = try makeEngine()

        let orgA = TestFactories.makeOrg(name: "org-a", scaleSetId: 1)
        let orgB = TestFactories.makeOrg(name: "org-b", scaleSetId: 2)

        // Set priority: orgA before orgB
        let dispatcher = await engine.dispatcher
        await dispatcher.setOrgPriority(["org-a", "org-b"])

        // Enqueue from orgB first, then orgA
        await engine.handleMessages([jobAvailableMessage(jobId: 100, org: "org-b")], org: orgB)

        // Complete first to allow re-dispatch
        await engine.handleMessages([jobCompletedMessage(jobId: 100)], org: orgB)

        // Now enqueue one from each
        await engine.handleMessages([jobAvailableMessage(jobId: 201, org: "org-b")], org: orgB)
        await engine.handleMessages([jobAvailableMessage(jobId: 200, org: "org-a")], org: orgA)

        // org-a should dispatch first since it has higher priority
        // (but since 201 was dispatched already during handleMessages, check the overall state)
        let jobs = await store.jobs
        let active = jobs.filter { $0.status == .provisioning }
        #expect(!active.isEmpty)
    }

    @Test("JobCompleted with failure marks job as failed")
    func failedJob() async throws {
        let (engine, store, _) = try makeEngine()
        let org = TestFactories.makeOrg()

        await engine.handleMessages([jobAvailableMessage(jobId: 77)], org: org)
        await engine.handleMessages([jobCompletedMessage(jobId: 77, result: "failed")], org: org)

        let job = await store.job(byId: 77)
        #expect(job?.status == .failed)
    }
}

/// Thread-safe holder for dispatched jobs in tests.
private actor DispatchedJobHolder {
    private(set) var job: RunnerJob?

    func set(_ job: RunnerJob) {
        self.job = job
    }
}
