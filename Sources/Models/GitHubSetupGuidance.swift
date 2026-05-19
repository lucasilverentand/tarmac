import Foundation

struct GitHubSetupGuidance: Identifiable, Equatable, Sendable {
    enum Scope: String, Sendable {
        case organization
        case repository
        case enterprise
        case permissions
    }

    let scope: Scope
    let title: String
    let detail: String

    var id: Scope { scope }
}

extension GitHubSetupGuidance {
    static let organization = GitHubSetupGuidance(
        scope: .organization,
        title: "Use an organization runner scale set",
        detail:
            "Tarmac currently connects to GitHub Actions at organization scope. Install the GitHub App on the organization, enter the organization name, App ID, installation ID, and the Actions Runner Scale Set ID from that organization."
    )

    static let repository = GitHubSetupGuidance(
        scope: .repository,
        title: "Repository filters do not replace GitHub visibility",
        detail:
            "The repository filter only decides which queued jobs Tarmac accepts after GitHub sends them. Configure runner group repository access in GitHub so workflows can only target the repositories you intend."
    )

    static let enterprise = GitHubSetupGuidance(
        scope: .enterprise,
        title: "Enterprise runner scale sets are not supported yet",
        detail:
            "For GitHub Enterprise Cloud, install Tarmac per organization. Enterprise-level runner groups and runner scale sets are not supported yet because they use different endpoints and are outside the current setup flow."
    )

    static let permissions = GitHubSetupGuidance(
        scope: .permissions,
        title: "Grant self-hosted runner access",
        detail:
            "The GitHub App needs organization self-hosted runner permission to read runner groups, inspect runner downloads, and verify the configured runner scale set."
    )

    static let setupOverview: [GitHubSetupGuidance] = [
        organization,
        repository,
        enterprise,
        permissions,
    ]
}
