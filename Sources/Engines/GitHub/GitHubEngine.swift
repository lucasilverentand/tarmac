import Foundation

actor GitHubEngine {
    let tokenManager: TokenManager
    let runnerProvider: RunnerProvider
    let client: any GitHubClientProtocol
    let keychainService: any KeychainServiceProtocol

    init(
        client: any GitHubClientProtocol = GitHubClient(),
        keychainService: any KeychainServiceProtocol = KeychainService(),
        cacheDirectory: URL
    ) {
        self.init(
            client: client,
            keychainService: keychainService,
            storage: StorageManager(rootDirectory: cacheDirectory)
        )
    }

    init(
        client: any GitHubClientProtocol = GitHubClient(),
        keychainService: any KeychainServiceProtocol = KeychainService(),
        storage: StorageManager
    ) {
        self.client = client
        self.keychainService = keychainService
        self.tokenManager = TokenManager(client: client)
        self.runnerProvider = RunnerProvider(client: client, storage: storage)
    }

    func installationToken(for org: Organization) async throws -> String {
        guard let keyData = keychainService.load(key: org.privateKeyKeychainKey) else {
            throw TokenError.noPrivateKey
        }
        return try await tokenManager.installationToken(for: org, privateKeyData: keyData)
    }

    func ensureRunner(for org: Organization) async throws -> URL {
        let token = try await installationToken(for: org)
        return try await runnerProvider.ensureRunner(token: token, accountPath: org.accountPath)
    }

    func organizationInstallationId(
        organizationName: String,
        appId: String,
        privateKeyData: Data
    ) async throws -> Int {
        struct InstallationResponse: Decodable, Sendable {
            let id: Int
        }

        let org = organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !org.isEmpty else {
            throw GitHubInstallationDiscoveryError.missingOrganizationName
        }

        let jwt = try await tokenManager.appJWT(appId: appId, privateKeyData: privateKeyData)
        let response: InstallationResponse = try await client.request(
            method: "GET",
            path: "/orgs/\(org)/installation",
            body: nil,
            headers: ["Authorization": "Bearer \(jwt)"],
            timeoutInterval: 30
        )
        return response.id
    }

    func generateJITConfig(for org: Organization, runnerName: String) async throws -> String {
        let token = try await installationToken(for: org)
        return try await runnerProvider.generateJITConfig(
            token: token,
            accountPath: org.accountPath,
            name: runnerName,
            labels: org.runnerLabels
        )
    }

    func listOrganizationRunners(for org: Organization) async throws -> [GitHubRunner] {
        let token = try await installationToken(for: org)
        var runners: [GitHubRunner] = []
        var page = 1

        while true {
            let response: GitHubRunnerListResponse = try await client.request(
                method: "GET",
                path: "\(org.accountPath)/actions/runners?per_page=100&page=\(page)",
                body: nil,
                headers: ["Authorization": "Bearer \(token)"],
                timeoutInterval: 30
            )
            runners.append(contentsOf: response.runners)

            if response.runners.count < 100 {
                break
            }
            page += 1
        }

        return runners
    }

    func deleteOrganizationRunner(id runnerId: Int64, for org: Organization) async throws {
        let token = try await installationToken(for: org)
        let (data, response) = try await client.requestRaw(
            method: "DELETE",
            path: "\(org.accountPath)/actions/runners/\(runnerId)",
            body: nil,
            headers: ["Authorization": "Bearer \(token)"],
            timeoutInterval: 30
        )

        guard (200..<300).contains(response.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            Log.github.error("GitHub runner delete error \(response.statusCode): \(message)")
            throw GitHubAPIError.httpError(statusCode: response.statusCode, message: message)
        }
    }

    func reconcileStaleRunners(for org: Organization, leases: [RunnerLease]) async -> RunnerReconciliationReport {
        let githubLeases = leases.filter {
            $0.request.organizationName == org.name && $0.runner.provider == .github
        }
        guard !githubLeases.isEmpty else {
            return .empty
        }

        do {
            let runners = try await listOrganizationRunners(for: org)
            let leaseByName = Dictionary(uniqueKeysWithValues: githubLeases.map { ($0.runnerName, $0) })
            let leaseById = Dictionary(
                uniqueKeysWithValues: githubLeases.compactMap { lease in
                    lease.runner.runnerId.map { ($0, lease) }
                }
            )
            var report = RunnerReconciliationReport(scannedRunnerCount: runners.count)

            for runner in runners {
                guard let lease = leaseById[runner.id] ?? leaseByName[runner.name] else {
                    report.skippedRunnerCount += 1
                    continue
                }

                report.matchedLeaseCount += 1
                guard isSafeStaleRunner(runner, for: lease) else {
                    report.skippedRunnerCount += 1
                    continue
                }

                do {
                    try await deleteOrganizationRunner(id: runner.id, for: org)
                    report.removedRunners.append(
                        RunnerReconciliationRemoval(
                            organizationName: org.name,
                            jobId: lease.jobId,
                            runnerId: runner.id,
                            runnerName: runner.name
                        )
                    )
                } catch {
                    report.failures.append(
                        RunnerReconciliationFailure(
                            organizationName: org.name,
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
                    RunnerReconciliationFailure(
                        organizationName: org.name,
                        message: error.localizedDescription
                    )
                ]
            )
        }
    }

    private func isSafeStaleRunner(_ runner: GitHubRunner, for lease: RunnerLease) -> Bool {
        guard runner.name == lease.runnerName else { return false }
        guard runner.isOffline && !runner.busy else { return false }

        let leaseLabels = Set(lease.runner.labels)
        return leaseLabels.isSubset(of: runner.labelNames)
    }
}

enum GitHubInstallationDiscoveryError: Error, LocalizedError, Sendable {
    case missingOrganizationName

    var errorDescription: String? {
        switch self {
        case .missingOrganizationName: "Enter the organization name before finding the installation."
        }
    }
}
