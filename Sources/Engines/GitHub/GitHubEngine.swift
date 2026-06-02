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

    func authorizationToken(for org: Organization) async throws -> String {
        switch org.accountType {
        case .organization:
            return try await installationToken(for: org)
        case .enterprise:
            guard let token = enterpriseAccessToken(for: org) else {
                throw GitHubEnterpriseTokenError.noAccessToken
            }
            return token
        }
    }

    private func enterpriseAccessToken(for org: Organization) -> String? {
        guard let data = keychainService.load(key: org.accessTokenKeychainKey),
            let token = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func ensureRunner(for org: Organization) async throws -> URL {
        let token = try await authorizationToken(for: org)
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

    func enterpriseInstallationId(
        enterpriseSlug: String,
        appId: String,
        privateKeyData: Data
    ) async throws -> Int {
        struct InstallationResponse: Decodable, Sendable {
            let id: Int
        }

        let enterprise = enterpriseSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !enterprise.isEmpty else {
            throw GitHubInstallationDiscoveryError.missingEnterpriseSlug
        }

        let jwt = try await tokenManager.appJWT(appId: appId, privateKeyData: privateKeyData)
        let response: InstallationResponse = try await client.request(
            method: "GET",
            path: "/enterprises/\(enterprise)/installation",
            body: nil,
            headers: enterpriseControlPlaneHeaders(token: jwt),
            timeoutInterval: 30
        )
        return response.id
    }

    func listEnterpriseInstallableOrganizations(
        enterpriseSlug: String,
        enterpriseInstallationId: Int,
        appId: String,
        privateKeyData: Data
    ) async throws -> [EnterpriseInstallableOrganization] {
        let enterprise = try normalizedEnterpriseSlug(enterpriseSlug)
        let token = try await enterpriseInstallationToken(
            enterpriseSlug: enterprise,
            enterpriseInstallationId: enterpriseInstallationId,
            appId: appId,
            privateKeyData: privateKeyData
        )
        var organizations: [EnterpriseInstallableOrganization] = []
        var page = 1

        while true {
            let pageOrganizations: [EnterpriseInstallableOrganization] = try await client.request(
                method: "GET",
                path: "/enterprises/\(enterprise)/apps/installable_organizations?per_page=100&page=\(page)",
                body: nil,
                headers: enterpriseControlPlaneHeaders(token: token),
                timeoutInterval: 30
            )
            organizations.append(contentsOf: pageOrganizations)

            if pageOrganizations.count < 100 {
                break
            }
            page += 1
        }

        return organizations
    }

    func installEnterpriseGitHubApp(
        enterpriseSlug: String,
        organizationName: String,
        enterpriseInstallationId: Int,
        appId: String,
        clientId: String,
        privateKeyData: Data,
        repositorySelection: EnterpriseGitHubAppInstallRepositorySelection,
        repositories: [String]
    ) async throws -> EnterpriseOrganizationInstallation {
        let enterprise = try normalizedEnterpriseSlug(enterpriseSlug)
        let org = organizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !org.isEmpty else {
            throw GitHubInstallationDiscoveryError.missingOrganizationName
        }
        let trimmedClientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientId.isEmpty else {
            throw GitHubEnterpriseControlPlaneError.missingClientId
        }
        if repositorySelection == .selected && repositories.isEmpty {
            throw GitHubEnterpriseControlPlaneError.missingRepositories
        }

        struct InstallRequest: Encodable, Sendable {
            let clientId: String
            let repositorySelection: String
            let repositories: [String]?

            enum CodingKeys: String, CodingKey {
                case clientId = "client_id"
                case repositorySelection = "repository_selection"
                case repositories
            }
        }

        let token = try await enterpriseInstallationToken(
            enterpriseSlug: enterprise,
            enterpriseInstallationId: enterpriseInstallationId,
            appId: appId,
            privateKeyData: privateKeyData
        )
        return try await client.request(
            method: "POST",
            path: "/enterprises/\(enterprise)/apps/organizations/\(org)/installations",
            body: InstallRequest(
                clientId: trimmedClientId,
                repositorySelection: repositorySelection.rawValue,
                repositories: repositorySelection == .selected ? repositories : nil
            ),
            headers: enterpriseControlPlaneHeaders(token: token),
            timeoutInterval: 30
        )
    }

    private func enterpriseInstallationToken(
        enterpriseSlug: String,
        enterpriseInstallationId: Int,
        appId: String,
        privateKeyData: Data
    ) async throws -> String {
        try await tokenManager.installationToken(
            installationId: enterpriseInstallationId,
            appId: appId,
            privateKeyData: privateKeyData,
            logSubject: enterpriseSlug
        )
    }

    private func normalizedEnterpriseSlug(_ enterpriseSlug: String) throws -> String {
        let enterprise = enterpriseSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !enterprise.isEmpty else {
            throw GitHubInstallationDiscoveryError.missingEnterpriseSlug
        }
        return enterprise
    }

    private func enterpriseControlPlaneHeaders(token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "X-GitHub-Api-Version": "2026-03-10",
        ]
    }

    func generateJITConfig(for org: Organization, runnerName: String, runnerGroupId: Int? = nil) async throws -> String
    {
        let token = try await authorizationToken(for: org)
        return try await runnerProvider.generateJITConfig(
            token: token,
            accountPath: org.accountPath,
            name: runnerName,
            labels: org.runnerLabels,
            runnerGroupId: runnerGroupId
        )
    }

    func generateRegistrationToken(for org: Organization) async throws -> String {
        let token = try await authorizationToken(for: org)
        return try await runnerProvider.generateRegistrationToken(
            token: token,
            accountPath: org.accountPath
        )
    }

    func generateRunnerGuestConfig(
        for org: Organization,
        runnerName: String,
        runnerGroupId: Int? = nil
    ) async throws -> RunnerGuestConfig {
        do {
            let jitConfig = try await generateJITConfig(
                for: org,
                runnerName: runnerName,
                runnerGroupId: runnerGroupId
            )
            return .jit(config: jitConfig)
        } catch {
            guard error.isRunnerRegistrationFallbackEligible else {
                throw error
            }
            Log.github.warning(
                "JIT runner config unavailable; falling back to registration token: \(error.localizedDescription)"
            )
            let registrationToken = try await generateRegistrationToken(for: org)
            return .registrationToken(
                url: org.runnerRegistrationURL,
                token: registrationToken,
                runnerName: runnerName,
                labels: org.runnerLabels
            )
        }
    }

    func listOrganizationRunners(for org: Organization) async throws -> [GitHubRunner] {
        let token = try await authorizationToken(for: org)
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
        let token = try await authorizationToken(for: org)
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

enum GitHubEnterpriseTokenError: Error, LocalizedError, Sendable {
    case noAccessToken

    var errorDescription: String? {
        switch self {
        case .noAccessToken: "No enterprise access token found in Keychain"
        }
    }
}

enum GitHubInstallationDiscoveryError: Error, LocalizedError, Sendable {
    case missingOrganizationName
    case missingEnterpriseSlug

    var errorDescription: String? {
        switch self {
        case .missingOrganizationName: "Enter the organization name before finding the installation."
        case .missingEnterpriseSlug: "Enter the enterprise slug before using the enterprise setup path."
        }
    }
}

enum GitHubEnterpriseControlPlaneError: Error, LocalizedError, Sendable {
    case missingClientId
    case missingRepositories

    var errorDescription: String? {
        switch self {
        case .missingClientId: "Enter the GitHub App Client ID before installing it into organizations."
        case .missingRepositories: "Enter at least one repository when repository access is set to selected."
        }
    }
}
