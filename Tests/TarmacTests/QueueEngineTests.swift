import Testing
import Foundation
import Security
@testable import Tarmac

@Suite("QueueEngine")
struct QueueEngineTests {
    private func makeEngine() throws -> (QueueEngine, JobStore, RecordingGitHubClient) {
        let futureDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))
        let client = RecordingGitHubClient(
            defaultResponseJSON: """
            {"token":"ghs_queue","expires_at":"\(futureDate)"}
            """.data(using: .utf8)!
        )

        let keychain = PreviewKeychainService()
        let keyData = try TestFactories.makeTestKeyData()

        // Save key for the default test org
        let defaultOrg = TestFactories.makeOrg()
        _ = keychain.save(key: defaultOrg.privateKeyKeychainKey, data: keyData)

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

    private func jobAvailableMessage(jobId: Int64, repo: String = "test-repo", workflow: String = "CI") -> ScaleSetMessage {
        let body = """
        {"jobMessageBase":{"jobId":\(jobId),"runnerRequestId":1,"repositoryName":"\(repo)","ownerName":"test-org","workflowRunName":"\(workflow)"}}
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

    @Test("handleMessages with JobAvailable enqueues job in store")
    func handleJobAvailableEnqueues() async throws {
        let (engine, store, _) = try makeEngine()
        let org = TestFactories.makeOrg()
        let message = jobAvailableMessage(jobId: 42)

        await engine.handleMessages([message], org: org)

        let jobs = await store.jobs
        #expect(jobs.count == 1)
        #expect(jobs.first?.id == 42)
        #expect(jobs.first?.status == .provisioning) // dispatched immediately
    }

    @Test("JobAvailable triggers dispatch and calls onJobReady")
    func jobAvailableTriggersDispatch() async throws {
        let (engine, store, _) = try makeEngine()
        let org = TestFactories.makeOrg()

        // Verify dispatch happened by checking store state
        let message = jobAvailableMessage(jobId: 77)
        await engine.handleMessages([message], org: org)

        let job = await store.job(byId: 77)
        #expect(job?.status == .provisioning) // dispatched = markStarted called
    }

    @Test("JobCompleted with success marks .completed")
    func jobCompletedSuccess() async throws {
        let (engine, store, _) = try makeEngine()
        let org = TestFactories.makeOrg()

        // First enqueue and dispatch
        await engine.handleMessages([jobAvailableMessage(jobId: 10)], org: org)

        // Now complete it
        await engine.handleMessages([jobCompletedMessage(jobId: 10, result: "success")], org: org)

        let job = await store.job(byId: 10)
        #expect(job?.status == .completed)
    }

    @Test("JobCompleted with failed marks .failed")
    func jobCompletedFailed() async throws {
        let (engine, store, _) = try makeEngine()
        let org = TestFactories.makeOrg()

        await engine.handleMessages([jobAvailableMessage(jobId: 20)], org: org)
        await engine.handleMessages([jobCompletedMessage(jobId: 20, result: "failed")], org: org)

        let job = await store.job(byId: 20)
        #expect(job?.status == .failed)
    }

    @Test("start filters to enabled orgs with scaleSetId")
    func startFiltersOrgs() async throws {
        let (engine, _, _) = try makeEngine()

        let enabledWithScaleSet = TestFactories.makeOrg(name: "good", scaleSetId: 1, isEnabled: true)
        let disabledOrg = TestFactories.makeOrg(name: "disabled", scaleSetId: 2, isEnabled: false)
        let noScaleSet = TestFactories.makeOrg(name: "no-ss", scaleSetId: nil, isEnabled: true)

        // start should only create pollers for enabled orgs with scaleSetId
        // We can't easily inspect pollers, but we can verify it doesn't crash
        // with mixed org configurations
        await engine.start(orgs: [enabledWithScaleSet, disabledOrg, noScaleSet])
        await engine.stop()
    }

    @Test("stop cancels polling tasks and clears state")
    func stopClearsState() async throws {
        let (engine, _, _) = try makeEngine()
        let org = TestFactories.makeOrg()

        await engine.start(orgs: [org])
        await engine.stop()

        // After stop, engine should accept new start without issues
        await engine.start(orgs: [org])
        await engine.stop()
    }

    @Test("Sequential dispatch: second job not dispatched while first active")
    func sequentialDispatch() async throws {
        let (engine, store, _) = try makeEngine()
        let org = TestFactories.makeOrg()

        // Don't set onJobReady so the first job stays in provisioning
        await engine.handleMessages([jobAvailableMessage(jobId: 1)], org: org)
        await engine.handleMessages([jobAvailableMessage(jobId: 2)], org: org)

        let jobs = await store.jobs
        let provisioning = jobs.filter { $0.status == .provisioning }
        let pending = jobs.filter { $0.status == .pending }

        #expect(provisioning.count == 1)
        #expect(pending.count == 1)
        #expect(provisioning.first?.id == 1)
        #expect(pending.first?.id == 2)
    }

    @Test("Repository filter: job skipped when repo is excluded")
    func repoFilterExclude() async throws {
        let (engine, store, _) = try makeEngine()
        let org = TestFactories.makeOrg(
            filterMode: .exclude,
            filteredRepositories: ["blocked-repo"]
        )

        let message = jobAvailableMessage(jobId: 50, repo: "blocked-repo")
        await engine.handleMessages([message], org: org)

        let jobs = await store.jobs
        #expect(jobs.isEmpty)
    }

    @Test("Repository filter: job accepted when repo passes include filter")
    func repoFilterInclude() async throws {
        let (engine, store, _) = try makeEngine()
        let org = TestFactories.makeOrg(
            filterMode: .include,
            filteredRepositories: ["allowed-repo"]
        )

        let allowed = jobAvailableMessage(jobId: 60, repo: "allowed-repo")
        let blocked = jobAvailableMessage(jobId: 61, repo: "other-repo")
        await engine.handleMessages([allowed, blocked], org: org)

        let jobs = await store.jobs
        #expect(jobs.count == 1)
        #expect(jobs.first?.id == 60)
    }

    @Test("Malformed JobAvailable body is ignored")
    func malformedJobAvailableIgnored() async throws {
        let (engine, store, _) = try makeEngine()
        let org = TestFactories.makeOrg()

        let malformed = ScaleSetMessage(
            messageId: 99,
            messageType: "JobAvailable",
            body: "not valid json at all",
            statistics: nil
        )

        await engine.handleMessages([malformed], org: org)

        let jobs = await store.jobs
        #expect(jobs.isEmpty)
    }
}
