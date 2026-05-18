import Foundation

enum GitHubAccountType: String, Codable, Sendable, CaseIterable, Identifiable {
    case organization
    case enterprise

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .organization: "Organization"
        case .enterprise: "Enterprise"
        }
    }

    var apiPathPrefix: String {
        switch self {
        case .organization: "orgs"
        case .enterprise: "enterprises"
        }
    }
}

struct Organization: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var accountType: GitHubAccountType = .organization
    var appId: String
    var installationId: Int
    var scaleSetId: Int?
    var labels: [String] = ["self-hosted", "macOS", "ARM64"]
    var imageProfile: RunnerImageProfile?
    var isEnabled: Bool = true
    var filterMode: RepositoryFilterMode = .all
    var filteredRepositories: [String] = []

    /// Keychain key for this org's private key
    var privateKeyKeychainKey: String {
        "github-app-private-key-\(id.uuidString)"
    }

    /// Base path for GitHub API calls scoped to this account (`/orgs/<name>` or `/enterprises/<name>`).
    var accountPath: String {
        "/\(accountType.apiPathPrefix)/\(name)"
    }

    enum CodingKeys: String, CodingKey {
        case id, name, accountType, appId, installationId, scaleSetId, labels
        case imageProfile, isEnabled, filterMode, filteredRepositories
    }

    init(
        id: UUID = UUID(),
        name: String,
        accountType: GitHubAccountType = .organization,
        appId: String,
        installationId: Int,
        scaleSetId: Int? = nil,
        labels: [String] = ["self-hosted", "macOS", "ARM64"],
        imageProfile: RunnerImageProfile? = nil,
        isEnabled: Bool = true,
        filterMode: RepositoryFilterMode = .all,
        filteredRepositories: [String] = []
    ) {
        self.id = id
        self.name = name
        self.accountType = accountType
        self.appId = appId
        self.installationId = installationId
        self.scaleSetId = scaleSetId
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
        self.appId = try container.decode(String.self, forKey: .appId)
        self.installationId = try container.decode(Int.self, forKey: .installationId)
        self.scaleSetId = try container.decodeIfPresent(Int.self, forKey: .scaleSetId)
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

    var imageProfileReadinessIssues: [RunnerImageProfileReadinessIssue] {
        imageProfile?.readinessIssues ?? []
    }

    func acceptsRepository(_ repoName: String?) -> Bool {
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
