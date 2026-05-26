import Foundation

struct EnterpriseInstallableOrganization: Identifiable, Codable, Equatable, Sendable {
    let id: Int64
    let login: String
}

struct EnterpriseOrganizationInstallation: Identifiable, Codable, Equatable, Sendable {
    enum RepositorySelection: String, Codable, Sendable {
        case all
        case selected
        case none
    }

    let id: Int
    let appSlug: String?
    let repositorySelection: RepositorySelection?

    enum CodingKeys: String, CodingKey {
        case id
        case appSlug = "app_slug"
        case repositorySelection = "repository_selection"
    }
}

enum EnterpriseGitHubAppInstallRepositorySelection: String, CaseIterable, Identifiable, Sendable {
    case all
    case selected
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: "All repositories"
        case .selected: "Selected repositories"
        case .none: "No repository access"
        }
    }
}
