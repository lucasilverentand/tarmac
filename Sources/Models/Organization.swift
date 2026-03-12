import Foundation

struct Organization: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var appId: String
    var installationId: Int
    var scaleSetId: Int?
    var labels: [String] = ["self-hosted", "macOS", "ARM64"]
    var isEnabled: Bool = true
    var filterMode: RepositoryFilterMode = .all
    var filteredRepositories: [String] = []

    /// Keychain key for this org's private key
    var privateKeyKeychainKey: String {
        "github-app-private-key-\(id.uuidString)"
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
    func acceptsRepository(_ repoName: String?) -> Bool {
        guard let repoName else { return true }
        switch filterMode {
        case .all:
            return true
        case .include:
            return filteredRepositories.contains(where: { repoName.localizedCaseInsensitiveCompare($0) == .orderedSame })
        case .exclude:
            return !filteredRepositories.contains(where: { repoName.localizedCaseInsensitiveCompare($0) == .orderedSame })
        }
    }
}
