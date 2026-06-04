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

struct Organization: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
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
    var isEnabled: Bool = true
    var filterMode: RepositoryFilterMode = .all
    var filteredRepositories: [String] = []

    /// Keychain key for this org's private key
    var privateKeyKeychainKey: String {
        "github-app-private-key-\(id.uuidString)"
    }

    /// Keychain key for a runner access token.
    var accessTokenKeychainKey: String {
        "github-enterprise-access-token-\(id.uuidString)"
    }

    var requiresGitHubAppCredentials: Bool {
        accountType != .enterprise && credentialMode == .githubApp
    }

    var requiresAccessToken: Bool {
        accountType == .enterprise || credentialMode == .accessToken
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
        case id, name, accountType, repositoryName, credentialMode, appId, installationId, scaleSetId, scaleSetName
        case labels
        case imageProfile, isEnabled, filterMode, filteredRepositories
    }

    init(
        id: UUID = UUID(),
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
        isEnabled: Bool = true,
        filterMode: RepositoryFilterMode = .all,
        filteredRepositories: [String] = []
    ) {
        self.id = id
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
        self.isEnabled = isEnabled
        self.filterMode = filterMode
        self.filteredRepositories = filteredRepositories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.accountType = try container.decodeIfPresent(GitHubAccountType.self, forKey: .accountType) ?? .organization
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
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.filterMode = try container.decodeIfPresent(RepositoryFilterMode.self, forKey: .filterMode) ?? .all
        self.filteredRepositories = try container.decodeIfPresent([String].self, forKey: .filteredRepositories) ?? []
    }
}

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

extension Organization {
    var runnerLabels: [String] {
        Self.normalizedLabels(labels + (imageProfile?.advertisedLabels ?? []))
    }

    var usesRepositoryWorkflowPolling: Bool {
        accountType == .organization
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
        if accountType == .repository {
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
