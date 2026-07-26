import Foundation

enum GitHubAccountType: String, Codable, Sendable, CaseIterable, Identifiable {
    case repository
    case organization
    case enterprise

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .repository: "Repository"
        case .organization: "Organization"
        case .enterprise: "Enterprise"
        }
    }

    static let runnerAccountTypes: [GitHubAccountType] = [.repository, .organization, .enterprise]

    var apiPathPrefix: String {
        switch self {
        case .repository: "repos"
        case .organization: "orgs"
        case .enterprise: "enterprises"
        }
    }
}

enum GitHubCredentialMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case githubApp
    case accessToken

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .githubApp: "GitHub App"
        case .accessToken: "Access Token"
        }
    }
}

struct RunnerAccount: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var provider: ProviderKind = .github
    var serverURL: String = "https://github.com"
    var scope: RunnerAccountScope = .organization
    var name: String
    var accountType: GitHubAccountType = .organization
    var repositoryName: String?
    var credentialMode: GitHubCredentialMode = .githubApp
    var appId: String
    var installationId: Int
    var scaleSetId: Int?
    var scaleSetName: String?
    var labels: [String] = ["self-hosted", "macOS", "ARM64"]
    var imageProfile: RunnerImageProfile?
    var runnerPools: [RunnerPoolConfiguration] = []
    var isEnabled: Bool = true
    var filterMode: RepositoryFilterMode = .all
    var filteredRepositories: [String] = []

    /// Keychain key for this org's private key
    var privateKeyKeychainKey: String {
        "github-app-private-key-\(id.uuidString)"
    }

    /// Keychain key for a runner access token.
    var accessTokenKeychainKey: String {
        switch provider {
        case .github: "github-enterprise-access-token-\(id.uuidString)"
        case .gitea: "gitea-api-token-\(id.uuidString)"
        }
    }

    var requiresGitHubAppCredentials: Bool {
        provider == .github && accountType != .enterprise && credentialMode == .githubApp
    }

    var requiresAccessToken: Bool {
        provider == .gitea || accountType == .enterprise || credentialMode == .accessToken
    }

    var requiresEnterpriseAccessToken: Bool {
        requiresAccessToken
    }

    /// Base path for GitHub API calls scoped to this account.
    var accountPath: String {
        switch accountType {
        case .repository:
            "/repos/\(name)/\(repositoryName ?? "")"
        case .organization:
            "/orgs/\(name)"
        case .enterprise:
            "/enterprises/\(name)"
        }
    }

    enum CodingKeys: String, CodingKey {
        case provider, serverURL, scope
        case id, name, accountType, repositoryName, credentialMode, appId, installationId, scaleSetId, scaleSetName
        case labels
        case imageProfile, runnerPools, isEnabled, filterMode, filteredRepositories
    }

    init(
        id: UUID = UUID(),
        provider: ProviderKind = .github,
        serverURL: String = "https://github.com",
        scope: RunnerAccountScope? = nil,
        name: String,
        accountType: GitHubAccountType = .organization,
        repositoryName: String? = nil,
        credentialMode: GitHubCredentialMode? = nil,
        appId: String,
        installationId: Int,
        scaleSetId: Int? = nil,
        scaleSetName: String? = nil,
        labels: [String] = ["self-hosted", "macOS", "ARM64"],
        imageProfile: RunnerImageProfile? = nil,
        runnerPools: [RunnerPoolConfiguration] = [],
        isEnabled: Bool = true,
        filterMode: RepositoryFilterMode = .all,
        filteredRepositories: [String] = []
    ) {
        self.id = id
        self.provider = provider
        self.serverURL = serverURL
        self.scope = scope ?? Self.scope(for: accountType)
        self.name = name
        self.accountType = accountType
        self.repositoryName = repositoryName
        self.credentialMode = credentialMode ?? (accountType == .enterprise ? .accessToken : .githubApp)
        self.appId = appId
        self.installationId = installationId
        self.scaleSetId = scaleSetId
        self.scaleSetName = scaleSetName
        self.labels = labels
        self.imageProfile = imageProfile
        self.runnerPools = runnerPools
        self.isEnabled = isEnabled
        self.filterMode = filterMode
        self.filteredRepositories = filteredRepositories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.provider = try container.decodeIfPresent(ProviderKind.self, forKey: .provider) ?? .github
        self.serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL) ?? "https://github.com"
        self.name = try container.decode(String.self, forKey: .name)
        self.accountType = try container.decodeIfPresent(GitHubAccountType.self, forKey: .accountType) ?? .organization
        self.scope =
            try container.decodeIfPresent(RunnerAccountScope.self, forKey: .scope)
            ?? Self.scope(for: accountType)
        self.repositoryName = try container.decodeIfPresent(String.self, forKey: .repositoryName)
        self.credentialMode =
            try container.decodeIfPresent(GitHubCredentialMode.self, forKey: .credentialMode)
            ?? (accountType == .enterprise ? .accessToken : .githubApp)
        self.appId = try container.decode(String.self, forKey: .appId)
        self.installationId = try container.decode(Int.self, forKey: .installationId)
        self.scaleSetId = try container.decodeIfPresent(Int.self, forKey: .scaleSetId)
        self.scaleSetName = try container.decodeIfPresent(String.self, forKey: .scaleSetName)
        self.labels =
            try container.decodeIfPresent([String].self, forKey: .labels)
            ?? ["self-hosted", "macOS", "ARM64"]
        self.imageProfile = try container.decodeIfPresent(RunnerImageProfile.self, forKey: .imageProfile)
        self.runnerPools = try container.decodeIfPresent([RunnerPoolConfiguration].self, forKey: .runnerPools) ?? []
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.filterMode = try container.decodeIfPresent(RepositoryFilterMode.self, forKey: .filterMode) ?? .all
        self.filteredRepositories = try container.decodeIfPresent([String].self, forKey: .filteredRepositories) ?? []
    }

    private static func scope(for accountType: GitHubAccountType) -> RunnerAccountScope {
        switch accountType {
        case .repository: .repository
        case .organization: .organization
        case .enterprise: .instance
        }
    }
}

/// Compatibility name retained while GitHub-specific call sites are migrated.
typealias Organization = RunnerAccount

enum RepositoryFilterMode: String, Codable, Sendable, CaseIterable {
    case all
    case include
    case exclude

    var label: String {
        switch self {
        case .all: "All repositories"
        case .include: "Only these repositories"
        case .exclude: "All except these repositories"
        }
    }
}

extension RunnerAccount {
    var runnerLabels: [String] {
        Self.normalizedLabels(labels + (imageProfile?.advertisedLabels ?? []))
    }

    var effectiveRunnerPools: [RunnerPoolConfiguration] {
        if !runnerPools.isEmpty { return runnerPools }
        return [
            RunnerPoolConfiguration(
                id: id,
                name: imageProfile?.name ?? "Default",
                scaleSetId: scaleSetId,
                scaleSetName: scaleSetName,
                imageProfile: imageProfile ?? RunnerImageProfile()
            )
        ]
    }

    func runnerPool(id poolID: UUID?) -> RunnerPoolConfiguration? {
        guard let poolID else { return effectiveRunnerPools.first(where: \.isEnabled) }
        return effectiveRunnerPools.first { $0.id == poolID }
    }

    func runnerPool(matching requestedLabels: [String]) -> RunnerPoolConfiguration? {
        let enabledPools = effectiveRunnerPools.filter(\.isEnabled)
        return enabledPools.first { $0.matches(requestedLabels: requestedLabels) }
            ?? (enabledPools.count == 1 ? enabledPools[0] : nil)
    }

    func runtimeAccount(for pool: RunnerPoolConfiguration) -> RunnerAccount {
        var account = self
        account.scaleSetId = pool.scaleSetId
        account.scaleSetName = pool.scaleSetName
        account.labels = Self.normalizedLabels(labels + pool.routingLabels)
        account.imageProfile = pool.imageProfile
        account.runnerPools = []
        return account
    }

    var usesRepositoryWorkflowPolling: Bool {
        provider == .github
            && accountType == .organization
            && scaleSetId == nil
            && filterMode == .include
            && !filteredRepositories.isEmpty
    }

    var imageProfileReadinessIssues: [RunnerImageProfileReadinessIssue] {
        imageProfile?.readinessIssues ?? []
    }

    func runnerBaseImagePath(defaultPath: String) -> String {
        imageProfile?.resolvedBaseImagePath(defaultPath: defaultPath) ?? defaultPath
    }

    func runnerVMConfiguration(defaultConfiguration: VMConfiguration) -> VMConfiguration {
        imageProfile?.resolvedVMConfiguration(defaultConfiguration: defaultConfiguration) ?? defaultConfiguration
    }

    func acceptsRepository(_ repoName: String?) -> Bool {
        if scope == .repository {
            guard let repoName else { return true }
            return repositoryName?.localizedCaseInsensitiveCompare(repoName) == .orderedSame
        }

        guard let repoName else { return true }
        switch filterMode {
        case .all:
            return true
        case .include:
            return filteredRepositories.contains(where: { repoName.localizedCaseInsensitiveCompare($0) == .orderedSame }
            )
        case .exclude:
            return !filteredRepositories.contains(where: {
                repoName.localizedCaseInsensitiveCompare($0) == .orderedSame
            })
        }
    }

    var normalizedServerURL: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            components.host != nil
        else {
            return nil
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.url
    }

    var giteaAPIPath: String {
        switch scope {
        case .repository: "/repos/\(name)/\(repositoryName ?? "")"
        case .organization: "/orgs/\(name)"
        case .instance: "/admin"
        }
    }

    var giteaRunnerLabels: [String] {
        Self.normalizedLabels(
            runnerLabels.map { label in
                label.contains(":") ? label : "\(label):host"
            }
        )
    }

    private static func normalizedLabels(_ labels: [String]) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []
        for label in labels {
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            normalized.append(trimmed)
        }
        return normalized
    }
}
