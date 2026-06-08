import Foundation

struct HeadlessKeychainService: KeychainServiceProtocol {
    let accessToken: String

    func save(key: String, data: Data) -> Bool {
        false
    }

    func load(key: String) -> Data? {
        guard key.hasPrefix("github-enterprise-access-token-") else {
            return nil
        }
        return Data(accessToken.utf8)
    }

    func delete(key: String) -> Bool {
        false
    }
}

private struct HeadlessWorkflowJobsResponse: Decodable {
    let jobs: [HeadlessWorkflowJob]
}

private struct HeadlessWorkflowJob: Decodable {
    let id: Int64
    let runId: Int64
    let name: String?
    let status: String
    let conclusion: String?
    let labels: [String]
    let startedAt: Date?
    let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case name, status, conclusion, labels
        case startedAt = "started_at"
        case htmlURL = "html_url"
    }
}

@main
struct HeadlessTarmacRunner {
    static func main() async {
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        guard
            let token = ProcessInfo.processInfo.environment["TARMAC_HEADLESS_ACCESS_TOKEN"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            fputs("TARMAC_HEADLESS_ACCESS_TOKEN is required\n", stderr)
            exit(2)
        }

        print("Tarmac headless starting")
        let targetRunId = ProcessInfo.processInfo.environment["TARMAC_HEADLESS_RUN_ID"]
            .flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let targetRunId {
            print("Target GitHub Actions run id: \(targetRunId)")
        }
        let defaults = UserDefaults(suiteName: "studio.seventwo.tarmac") ?? .standard
        if ProcessInfo.processInfo.environment["TARMAC_HEADLESS_RESET_JOB_HISTORY"] == "1" {
            defaults.removeObject(forKey: "completedJobHistory")
            UserDefaults.standard.removeObject(forKey: "completedJobHistory")
            print("Reset completed job history")
        }

        let appState = await MainActor.run {
            AppState(
                configStore: ConfigStore(
                    defaults: defaults,
                    keychainService: HeadlessKeychainService(accessToken: token)
                )
            )
        }
        await MainActor.run {
            print("Initial readiness: \(appState.vmStatusViewModel.readinessStatusText)")
            print(
                "Loaded orgs: \(appState.configStore.organizations.map { "\($0.name):\($0.filterMode.rawValue):\($0.filteredRepositories.joined(separator: ",")):repoPolling=\($0.usesRepositoryWorkflowPolling)" }.joined(separator: " "))"
            )
        }
        var queuedJobs: [GitHubQueuedWorkflowJob] = []
        let queuedOrg = await MainActor.run(body: { appState.configStore.organizations.first })
        if let org = queuedOrg {
            do {
                let github = GitHubEngine(
                    keychainService: HeadlessKeychainService(accessToken: token),
                    storage: StorageManager(rootPath: await MainActor.run { appState.configStore.storageRootPath })
                )
                let allQueuedJobs = try await github.queuedWorkflowJobs(for: org, repositoryName: "tarmac-e2e")
                if let targetRunId {
                    let targetJobs = try await queuedWorkflowJobs(
                        token: token,
                        org: org,
                        repositoryName: "tarmac-e2e",
                        runId: targetRunId
                    )
                    let targetJobIds = Set(targetJobs.map(\.id))
                    print(
                        "Target queuedWorkflowJobs count: \(targetJobs.count) all=\(targetJobs.map { "\($0.runId)/\($0.id)" })"
                    )
                    print(
                        "Target jobs present in FIFO injection: \(targetJobIds.allSatisfy { id in allQueuedJobs.contains { $0.id == id } })"
                    )
                }
                queuedJobs = allQueuedJobs
                print(
                    "Direct queuedWorkflowJobs count: \(allQueuedJobs.count) all=\(allQueuedJobs.map { "\($0.runId)/\($0.id)" }) selected=\(queuedJobs.map { "\($0.runId)/\($0.id)" })"
                )
            } catch {
                print("Direct queuedWorkflowJobs failed: \(error.localizedDescription)")
            }
        }
        await appState.start()

        await MainActor.run {
            print("Post-start readiness: \(appState.vmStatusViewModel.readinessStatusText)")
        }
        if let queuedOrg, !queuedJobs.isEmpty {
            print("Injecting \(queuedJobs.count) queued workflow job(s) into Tarmac queue engine")
            let injected = await appState.testing_handleQueuedWorkflowJobs(queuedJobs, org: queuedOrg)
            print("Queue injection accepted: \(injected)")
        }

        while !Task.isCancelled {
            await MainActor.run {
                let summaries = appState.queueViewModel.allJobs.map {
                    "\($0.id):\($0.status.rawValue):\($0.failureReason ?? "")"
                }
                if summaries.isEmpty {
                    print("Queue state: empty")
                } else {
                    print("Queue state: \(summaries.joined(separator: " "))")
                }
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private static func queuedWorkflowJobs(
        token: String,
        org: Organization,
        repositoryName: String,
        runId: Int64
    ) async throws -> [GitHubQueuedWorkflowJob] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(org.name)/\(repositoryName)/actions/runs/\(runId)/jobs"
        components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        guard let url = components.url else {
            return []
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "HeadlessTarmacRunner",
                code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: "GitHub jobs request failed with HTTP \(http.statusCode): \(body)"
                ]
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let responseBody = try decoder.decode(HeadlessWorkflowJobsResponse.self, from: data)
        let requiredLabels = org.runnerLabels.map { $0.lowercased() }
        return responseBody.jobs.compactMap { job in
            guard job.status == "queued", job.conclusion == nil else {
                return nil
            }
            let labels = Set(job.labels.map { $0.lowercased() })
            guard requiredLabels.allSatisfy(labels.contains) else {
                return nil
            }
            return GitHubQueuedWorkflowJob(
                id: job.id,
                runId: job.runId,
                name: job.name,
                repositoryName: repositoryName,
                labels: job.labels,
                queuedAt: job.startedAt,
                htmlURL: job.htmlURL
            )
        }
    }
}
