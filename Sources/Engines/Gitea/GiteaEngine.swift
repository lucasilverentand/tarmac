import Foundation

private struct GiteaVersionResponse: Decodable, Sendable {
    let version: String
}

private struct GiteaRegistrationTokenResponse: Decodable, Sendable {
    let token: String
}

private struct GiteaRepository: Decodable, Sendable {
    let name: String
    let fullName: String

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
    }
}

private struct GiteaWorkflowJobsResponse: Decodable, Sendable {
    let jobs: [GiteaWorkflowJob]
    let totalCount: Int?

    enum CodingKeys: String, CodingKey {
        case jobs
        case totalCount = "total_count"
    }
}

private struct GiteaWorkflowJob: Decodable, Sendable {
    let id: Int64
    let runID: Int64?
    let name: String?
    let status: String
    let conclusion: String?
    let labels: [String]
    let runnerID: Int64?
    let runnerName: String?
    let createdAt: Date?
    let startedAt: Date?
    let completedAt: Date?
    let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion, labels
        case runID = "run_id"
        case runnerID = "runner_id"
        case runnerName = "runner_name"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case htmlURL = "html_url"
    }
}

private struct GiteaRunnerListResponse: Decodable, Sendable {
    let runners: [GiteaRunner]
}

private struct GiteaRunner: Decodable, Sendable {
    struct Label: Decodable, Sendable {
        let name: String
    }

    let id: Int64
    let name: String
    let status: String
    let busy: Bool
    let labels: [Label]
}

actor GiteaEngine: ActionsProvider {
    nonisolated let kind: ProviderKind = .gitea

    private let client: any GiteaClientProtocol
    private let keychainService: any KeychainServiceProtocol
    private let runnerProvider: GiteaRunnerProvider

    init(
        client: any GiteaClientProtocol,
        keychainService: any KeychainServiceProtocol,
        runnerProvider: GiteaRunnerProvider
    ) {
        self.client = client
        self.keychainService = keychainService
        self.runnerProvider = runnerProvider
    }

    init(account: RunnerAccount, keychainService: any KeychainServiceProtocol, storage: StorageManager) throws {
        guard let instanceURL = account.normalizedServerURL else { throw GiteaAPIError.invalidURL }
        self.client = GiteaClient(instanceURL: instanceURL)
        self.keychainService = keychainService
        self.runnerProvider = GiteaRunnerProvider(storage: storage)
    }

    func validate(account: RunnerAccount) async -> ProviderSetupResult {
        var issues: [ProviderSetupIssue] = []
        var serverVersion: String?
        do {
            let token = try apiToken(for: account)
            let version: GiteaVersionResponse = try await client.request(
                method: "GET",
                path: "/version",
                body: nil,
                token: token,
                timeoutInterval: 15
            )
            serverVersion = version.version
            if SemanticVersion(version.version).map({ $0 < SemanticVersion(major: 1, minor: 25, patch: 0) }) != false {
                issues.append(.unsupportedVersion(required: "1.25", actual: version.version))
            }
            _ = try await registrationToken(for: account)
            _ = try await runnerProvider.ensureRunner()
            _ = try await queuedJobs(for: account)
        } catch let error as GiteaAPIError {
            switch error {
            case .httpError(let status, let message) where status == 401:
                issues.append(.authentication("Gitea rejected the API token: \(message)"))
            case .httpError(let status, let message) where status == 403:
                issues.append(.permissions("The API token lacks permission for this scope: \(message)"))
            case .httpError(let status, _) where status == 404:
                issues.append(.actionsUnavailable)
            case .noCompatibleRunner, .missingChecksum, .checksumMismatch, .extractionFailed:
                issues.append(.runnerUnavailable(error.localizedDescription))
            default:
                issues.append(.invalidConfiguration(error.localizedDescription))
            }
        } catch {
            issues.append(.invalidConfiguration(error.localizedDescription))
        }
        return ProviderSetupResult(
            provider: .gitea,
            accountID: account.id,
            serverVersion: serverVersion,
            issues: issues
        )
    }

    func queuedJobs(for account: RunnerAccount) async throws -> [ProviderQueuedJob] {
        let token = try apiToken(for: account)
        let repositories = try await repositories(for: account, token: token)
        var discovered: [ProviderQueuedJob] = []

        if account.scope == .instance {
            for status in ["pending", "queued"] {
                let jobs = try await pagedJobs(path: "/admin/actions/jobs", status: status, token: token)
                discovered.append(contentsOf: jobs.compactMap { providerJob($0, account: account, repository: nil) })
            }
        } else {
            for repository in repositories where account.acceptsRepository(repository.name) {
                for status in ["pending", "queued"] {
                    let path = "/repos/\(repository.fullName)/actions/jobs"
                    let jobs = try await pagedJobs(path: path, status: status, token: token)
                    discovered.append(
                        contentsOf: jobs.compactMap {
                            providerJob($0, account: account, repository: repository.fullName)
                        }
                    )
                }
            }
        }

        return Dictionary(grouping: discovered, by: \ProviderQueuedJob.key)
            .compactMap { $0.value.first }
            .sorted { lhs, rhs in
                lhs.queuedAt == rhs.queuedAt ? lhs.key.remoteJobID < rhs.key.remoteJobID : lhs.queuedAt < rhs.queuedAt
            }
    }

    func prepareRunner(for account: RunnerAccount, runnerName: String) async throws -> PreparedRunner {
        let token = try await registrationToken(for: account)
        let runnerPath = try await runnerProvider.ensureRunner()
        guard let instanceURL = account.normalizedServerURL else { throw GiteaAPIError.invalidURL }
        return PreparedRunner(
            runnerPath: runnerPath,
            guestConfig: .giteaEphemeral(
                instanceURL: instanceURL.absoluteString,
                registrationToken: token,
                runnerName: runnerName,
                labels: account.giteaRunnerLabels
            )
        )
    }

    func claimedJob(for account: RunnerAccount, runnerName: String) async throws -> ProviderQueuedJob? {
        let token = try apiToken(for: account)
        let repositories = try await repositories(for: account, token: token)
        var matches: [ProviderQueuedJob] = []
        if account.scope == .instance {
            let jobs = try await pagedJobs(path: "/admin/actions/jobs", status: "in_progress", token: token)
            matches = jobs.filter { $0.runnerName == runnerName }.compactMap {
                providerJob($0, account: account, repository: nil, requireQueued: false)
            }
        } else {
            for repository in repositories where account.acceptsRepository(repository.name) {
                let jobs = try await pagedJobs(
                    path: "/repos/\(repository.fullName)/actions/jobs",
                    status: "in_progress",
                    token: token
                )
                matches.append(
                    contentsOf: jobs.filter { $0.runnerName == runnerName }.compactMap {
                        providerJob($0, account: account, repository: repository.fullName, requireQueued: false)
                    }
                )
            }
        }
        guard matches.count <= 1 else { throw GiteaAPIError.ambiguousClaim(runnerName) }
        return matches.first
    }

    func terminalResult(
        for account: RunnerAccount,
        remoteJobID: String,
        repositoryName: String?
    ) async throws -> JobResult? {
        guard let id = Int64(remoteJobID), let repositoryName else { return nil }
        let token = try apiToken(for: account)
        let job: GiteaWorkflowJob = try await client.request(
            method: "GET",
            path: "/repos/\(repositoryName)/actions/jobs/\(id)",
            body: nil,
            token: token,
            timeoutInterval: 30
        )
        let status = job.status.lowercased()
        let conclusion = job.conclusion?.lowercased()
        guard
            ["completed", "success", "failure", "cancelled", "canceled", "skipped"].contains(status)
                || conclusion != nil
        else { return nil }
        switch conclusion ?? status {
        case "success": return .success
        case "failure", "failed": return .failure("Gitea job failed")
        case "cancelled", "canceled": return .failure("Gitea job was cancelled")
        case "skipped": return .failure("Gitea job was skipped")
        default: return .failure("Gitea job completed with \(job.conclusion ?? job.status)")
        }
    }

    func reconcileStaleRunners(
        for account: RunnerAccount,
        leases: [RunnerLease]
    ) async -> RunnerReconciliationReport {
        let accountLeases = leases.filter {
            $0.runner.provider == .gitea
                && ($0.request.accountID == account.id || $0.request.organizationName == account.name)
        }
        do {
            let token = try apiToken(for: account)
            let response: GiteaRunnerListResponse = try await client.request(
                method: "GET",
                path: runnerCollectionPath(for: account),
                body: nil,
                token: token,
                timeoutInterval: 30
            )
            var report = RunnerReconciliationReport(scannedRunnerCount: response.runners.count)
            let leasesByName = Dictionary(uniqueKeysWithValues: accountLeases.map { ($0.runnerName, $0) })
            for runner in response.runners {
                guard runner.name.hasPrefix("tarmac-gitea-") else {
                    report.skippedRunnerCount += 1
                    continue
                }
                guard runner.status.lowercased() == "offline", !runner.busy else {
                    report.skippedRunnerCount += 1
                    continue
                }
                let lease = leasesByName[runner.name]
                if lease != nil { report.matchedLeaseCount += 1 }
                do {
                    try await deleteRunner(id: runner.id, account: account, token: token)
                    report.removedRunners.append(
                        RunnerReconciliationRemoval(
                            organizationName: account.name,
                            jobId: lease?.jobId ?? 0,
                            runnerId: runner.id,
                            runnerName: runner.name
                        )
                    )
                } catch {
                    report.failures.append(
                        RunnerReconciliationFailure(
                            organizationName: account.name,
                            runnerName: runner.name,
                            message: error.localizedDescription
                        )
                    )
                }
            }
            return report
        } catch {
            return RunnerReconciliationReport(
                failures: [
                    RunnerReconciliationFailure(organizationName: account.name, message: error.localizedDescription)
                ]
            )
        }
    }

    private func apiToken(for account: RunnerAccount) throws -> String {
        guard let data = keychainService.load(key: account.accessTokenKeychainKey),
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            throw GiteaAPIError.missingToken
        }
        return token
    }

    private func registrationToken(for account: RunnerAccount) async throws -> String {
        let token = try apiToken(for: account)
        let response: GiteaRegistrationTokenResponse = try await client.request(
            method: "POST",
            path: "\(runnerCollectionPath(for: account))/registration-token",
            body: nil,
            token: token,
            timeoutInterval: 30
        )
        return response.token
    }

    private func runnerCollectionPath(for account: RunnerAccount) -> String {
        switch account.scope {
        case .repository: "/repos/\(account.name)/\(account.repositoryName ?? "")/actions/runners"
        case .organization: "/orgs/\(account.name)/actions/runners"
        case .instance: "/admin/actions/runners"
        }
    }

    private func repositories(for account: RunnerAccount, token: String) async throws -> [GiteaRepository] {
        switch account.scope {
        case .repository:
            let fullName = "\(account.name)/\(account.repositoryName ?? "")"
            return [GiteaRepository(name: account.repositoryName ?? "", fullName: fullName)]
        case .organization:
            return try await pagedRepositories(path: "/orgs/\(account.name)/repos", token: token)
        case .instance:
            return []
        }
    }

    private func pagedRepositories(path: String, token: String) async throws -> [GiteaRepository] {
        var repositories: [GiteaRepository] = []
        var page = 1
        while true {
            let batch: [GiteaRepository] = try await client.request(
                method: "GET",
                path: "\(path)?limit=50&page=\(page)",
                body: nil,
                token: token,
                timeoutInterval: 30
            )
            repositories.append(contentsOf: batch)
            guard batch.count == 50 else { return repositories }
            page += 1
        }
    }

    private func pagedJobs(path: String, status: String, token: String) async throws -> [GiteaWorkflowJob] {
        var jobs: [GiteaWorkflowJob] = []
        var page = 1
        while true {
            let response: GiteaWorkflowJobsResponse = try await client.request(
                method: "GET",
                path: "\(path)?status=\(status)&limit=50&page=\(page)",
                body: nil,
                token: token,
                timeoutInterval: 30
            )
            jobs.append(contentsOf: response.jobs)
            guard response.jobs.count == 50,
                response.totalCount.map({ jobs.count < $0 }) ?? true
            else { return jobs }
            page += 1
        }
    }

    private func providerJob(
        _ job: GiteaWorkflowJob,
        account: RunnerAccount,
        repository: String?,
        requireQueued: Bool = true
    ) -> ProviderQueuedJob? {
        if requireQueued, !["pending", "queued"].contains(job.status.lowercased()) { return nil }
        let offeredLabels = Set(
            account.giteaRunnerLabels.map { $0.split(separator: ":", maxSplits: 1).first.map(String.init) ?? $0 }.map {
                $0.lowercased()
            }
        )
        guard job.labels.allSatisfy({ offeredLabels.contains($0.lowercased()) }) else { return nil }
        let repositoryName =
            repository ?? repositoryFrom(htmlURL: job.htmlURL, instanceURL: account.normalizedServerURL)
        guard account.acceptsRepository(repositoryName?.split(separator: "/").last.map(String.init)) else { return nil }
        let key = ProviderJobKey(accountID: account.id, remoteJobID: String(job.id))
        return ProviderQueuedJob(
            key: key,
            localID: key.localID,
            runID: job.runID,
            name: job.name,
            repositoryName: repositoryName,
            labels: job.labels,
            queuedAt: job.createdAt ?? job.startedAt ?? Date(),
            htmlURL: job.htmlURL.flatMap(URL.init(string:))
        )
    }

    private func repositoryFrom(htmlURL: String?, instanceURL: URL?) -> String? {
        guard let htmlURL, let url = URL(string: htmlURL), url.host == instanceURL?.host else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }
        return "\(components[0])/\(components[1])"
    }

    private func deleteRunner(id: Int64, account: RunnerAccount, token: String) async throws {
        let (data, response) = try await client.requestRaw(
            method: "DELETE",
            path: "\(runnerCollectionPath(for: account))/\(id)",
            body: nil,
            token: token,
            timeoutInterval: 30
        )
        guard (200..<300).contains(response.statusCode) else {
            throw GiteaAPIError.httpError(
                statusCode: response.statusCode,
                message: String(data: data, encoding: .utf8) ?? "Unknown error"
            )
        }
    }
}
