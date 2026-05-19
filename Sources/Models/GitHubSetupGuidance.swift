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
            "Install the GitHub App on the organization, enter the organization name, App ID, installation ID, and the Actions Runner Scale Set ID from that organization."
    )

    static let repository = GitHubSetupGuidance(
        scope: .repository,
        title: "Repository filters do not replace GitHub visibility",
        detail:
            "The repository filter only decides which queued jobs Tarmac accepts after GitHub sends them. Configure runner group repository access in GitHub so workflows can only target the repositories you intend."
    )

    static let enterprise = GitHubSetupGuidance(
        scope: .enterprise,
        title: "Enterprise accounts use enterprise slugs",
        detail:
            "For GitHub Enterprise Cloud, choose Enterprise and enter the slug from github.com/enterprises/<slug>. Tarmac will use the enterprise runner endpoints for JIT configuration."
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

struct GitHubAppSetupGuide: Equatable, Sendable {
    let accountType: GitHubAccountType
    let title: String
    let summary: String
    let registrationOwnerPath: String
    let documentationURL: String
    let appFields: [GitHubAppFormFieldGuide]
    let tarmacFields: [TarmacAccountFieldGuide]
    let afterCreationSteps: [GitHubAppSetupStep]

    static func guide(for accountType: GitHubAccountType) -> GitHubAppSetupGuide {
        switch accountType {
        case .organization:
            organization
        case .enterprise:
            enterprise
        }
    }

    func registrationPath(accountName: String) -> String {
        guard let owner = sanitizedAccountName(accountName) else {
            return "https://github.com/\(registrationOwnerPath)/<account>/settings/apps/new"
        }
        return "https://github.com/\(registrationOwnerPath)/\(owner)/settings/apps/new"
    }

    func registrationURL(accountName: String) -> URL? {
        guard let owner = sanitizedAccountName(accountName),
            var components = URLComponents(string: registrationPath(accountName: owner))
        else {
            return nil
        }

        var queryItems = [
            URLQueryItem(name: "name", value: suggestedAppName(accountName: owner)),
            URLQueryItem(name: "description", value: Self.defaultDescription),
            URLQueryItem(name: "url", value: homepageURL(accountName: owner)),
            URLQueryItem(name: "webhook_active", value: "false"),
            URLQueryItem(name: "organization_self_hosted_runners", value: "write"),
        ]

        if accountType == .organization {
            queryItems.append(URLQueryItem(name: "public", value: "false"))
        }

        components.queryItems = queryItems
        return components.url
    }

    func resolvedAppFields(accountName: String) -> [GitHubAppFormFieldGuide] {
        appFields.map { field in
            field.resolved(
                appName: suggestedAppName(accountName: accountName),
                homepageURL: homepageURL(accountName: accountName)
            )
        }
    }

    func suggestedAppName(accountName: String) -> String {
        let owner = sanitizedAccountName(accountName) ?? "<account>"
        let prefix = "Tarmac "
        let maxOwnerLength = max(1, 34 - prefix.count)
        return prefix + String(owner.prefix(maxOwnerLength))
    }

    func homepageURL(accountName: String) -> String {
        guard let owner = sanitizedAccountName(accountName) else {
            return accountType == .enterprise
                ? "https://github.com/enterprises/<enterprise>"
                : "https://github.com/<organization>"
        }

        switch accountType {
        case .organization:
            return "https://github.com/\(owner)"
        case .enterprise:
            return "https://github.com/enterprises/\(owner)"
        }
    }

    private func sanitizedAccountName(_ accountName: String) -> String? {
        let trimmed = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let defaultDescription = "Ephemeral macOS GitHub Actions runners managed by Tarmac."
}

struct GitHubAppFormFieldGuide: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case name
        case description
        case homepageURL
        case callbackURL
        case oauth
        case setupURL
        case webhooks
        case permissions
        case events
        case visibility
    }

    let kind: Kind
    let field: String
    let value: String
    let detail: String

    var id: Kind { kind }

    fileprivate func resolved(appName: String, homepageURL: String) -> GitHubAppFormFieldGuide {
        GitHubAppFormFieldGuide(
            kind: kind,
            field: field,
            value:
                value
                .replacingOccurrences(of: "{appName}", with: appName)
                .replacingOccurrences(of: "{homepageURL}", with: homepageURL),
            detail: detail
        )
    }
}

struct TarmacAccountFieldGuide: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case type
        case accountName
        case appId
        case installationId
        case privateKey
        case scaleSetId
        case labels
    }

    let kind: Kind
    let field: String
    let detail: String

    var id: Kind { kind }
}

struct GitHubAppSetupStep: Identifiable, Equatable, Sendable {
    let number: Int
    let title: String
    let detail: String

    var id: Int { number }
}

extension GitHubAppSetupGuide {
    static let organization = GitHubAppSetupGuide(
        accountType: .organization,
        title: "Create an organization-owned GitHub App",
        summary:
            "Use this when Tarmac should receive jobs from one GitHub organization. Register the app under that organization, install it on the same organization, then copy the generated IDs and private key into Tarmac.",
        registrationOwnerPath: "organizations",
        documentationURL:
            "https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app",
        appFields: standardAppFields + [
            GitHubAppFormFieldGuide(
                kind: .visibility,
                field: "Where can this GitHub App be installed?",
                value: "Only on this account",
                detail:
                    "Keep the app private to the organization unless you intentionally manage several accounts with one public app."
            )
        ],
        tarmacFields: [
            TarmacAccountFieldGuide(
                kind: .type,
                field: "Type",
                detail: "Choose Organization."
            ),
            TarmacAccountFieldGuide(
                kind: .accountName,
                field: "Organization name",
                detail: "Enter the GitHub organization login only, for example octo-org from github.com/octo-org."
            ),
            TarmacAccountFieldGuide(
                kind: .appId,
                field: "App ID",
                detail: "After the app is created, copy App ID from the GitHub App settings page."
            ),
            TarmacAccountFieldGuide(
                kind: .installationId,
                field: "Installation ID",
                detail:
                    "Install the app on the organization, open the installation settings page, and copy the number from /settings/installations/<id>."
            ),
            TarmacAccountFieldGuide(
                kind: .privateKey,
                field: "Private key",
                detail:
                    "In GitHub App settings, generate a private key and import the downloaded .pem file here."
            ),
            TarmacAccountFieldGuide(
                kind: .scaleSetId,
                field: "Scale Set ID",
                detail:
                    "Enter the numeric runner scale set ID for the organization runner scale set that Tarmac should poll."
            ),
            TarmacAccountFieldGuide(
                kind: .labels,
                field: "Runner labels",
                detail:
                    "Keep self-hosted and add the labels your workflows use in runs-on, such as macOS and ARM64."
            ),
        ],
        afterCreationSteps: standardAfterCreationSteps
    )

    static let enterprise = GitHubAppSetupGuide(
        accountType: .enterprise,
        title: "Create an enterprise-owned GitHub App",
        summary:
            "Use this when Tarmac should receive jobs from an enterprise runner scale set. Register the app from Enterprise settings, install it for the enterprise scope, then copy the enterprise slug, generated IDs, and private key into Tarmac.",
        registrationOwnerPath: "enterprises",
        documentationURL:
            "https://docs.github.com/en/enterprise-cloud@latest/admin/managing-github-apps-for-your-enterprise/creating-github-apps-for-your-enterprise",
        appFields: standardAppFields + [
            GitHubAppFormFieldGuide(
                kind: .visibility,
                field: "Installation target",
                value: "Only enterprise organizations",
                detail:
                    "Enterprise-owned apps are internal to the enterprise and can be installed only on that enterprise or organizations within it."
            )
        ],
        tarmacFields: [
            TarmacAccountFieldGuide(
                kind: .type,
                field: "Type",
                detail: "Choose Enterprise."
            ),
            TarmacAccountFieldGuide(
                kind: .accountName,
                field: "Enterprise slug",
                detail:
                    "Enter the slug from github.com/enterprises/<slug>. Do not enter an organization name here."
            ),
            TarmacAccountFieldGuide(
                kind: .appId,
                field: "App ID",
                detail: "After the app is created, copy App ID from the enterprise GitHub App settings page."
            ),
            TarmacAccountFieldGuide(
                kind: .installationId,
                field: "Installation ID",
                detail:
                    "Install the app for the enterprise runner scope, open the installation settings page, and copy the number from /settings/installations/<id>."
            ),
            TarmacAccountFieldGuide(
                kind: .privateKey,
                field: "Private key",
                detail:
                    "In the enterprise GitHub App settings, generate a private key and import the downloaded .pem file here."
            ),
            TarmacAccountFieldGuide(
                kind: .scaleSetId,
                field: "Scale Set ID",
                detail:
                    "Enter the numeric enterprise runner scale set ID that Tarmac should poll for queued jobs."
            ),
            TarmacAccountFieldGuide(
                kind: .labels,
                field: "Runner labels",
                detail:
                    "Keep self-hosted and add the labels enterprise workflows use in runs-on, such as macOS and ARM64."
            ),
        ],
        afterCreationSteps: standardAfterCreationSteps
    )

    private static let standardAppFields: [GitHubAppFormFieldGuide] = [
        GitHubAppFormFieldGuide(
            kind: .name,
            field: "GitHub App name",
            value: "{appName}",
            detail: "Use a short unique name. GitHub shows this name in audit and installation screens."
        ),
        GitHubAppFormFieldGuide(
            kind: .description,
            field: "Description",
            value: defaultDescription,
            detail: "This is shown during installation."
        ),
        GitHubAppFormFieldGuide(
            kind: .homepageURL,
            field: "Homepage URL",
            value: "{homepageURL}",
            detail: "GitHub requires a URL. The owning account URL is enough for a local Tarmac deployment."
        ),
        GitHubAppFormFieldGuide(
            kind: .callbackURL,
            field: "Callback URL",
            value: "Leave blank",
            detail: "Tarmac does not request user OAuth authorization."
        ),
        GitHubAppFormFieldGuide(
            kind: .oauth,
            field: "OAuth and device flow",
            value: "Leave disabled",
            detail:
                "Tarmac uses installation access tokens generated from the App ID, installation ID, and private key."
        ),
        GitHubAppFormFieldGuide(
            kind: .setupURL,
            field: "Setup URL",
            value: "Leave blank",
            detail: "Account setup continues inside Tarmac after the app is installed."
        ),
        GitHubAppFormFieldGuide(
            kind: .webhooks,
            field: "Webhooks",
            value: "Deselect Active",
            detail: "Tarmac polls GitHub runner scale set sessions and does not receive webhook deliveries."
        ),
        GitHubAppFormFieldGuide(
            kind: .permissions,
            field: "Permissions",
            value: "Self-hosted runners: Read & write",
            detail:
                "This permission lets Tarmac read runner downloads and groups, create JIT runner configuration, and clean up Tarmac-owned runners."
        ),
        GitHubAppFormFieldGuide(
            kind: .events,
            field: "Subscribe to events",
            value: "None",
            detail: "No webhook events are needed when webhooks are inactive."
        ),
    ]

    private static let standardAfterCreationSteps: [GitHubAppSetupStep] = [
        GitHubAppSetupStep(
            number: 1,
            title: "Create the GitHub App",
            detail: "Review the prefilled fields, confirm Self-hosted runners is Read & write, then create the app."
        ),
        GitHubAppSetupStep(
            number: 2,
            title: "Generate credentials",
            detail: "Copy the App ID and generate a private key. Keep the downloaded .pem file for import into Tarmac."
        ),
        GitHubAppSetupStep(
            number: 3,
            title: "Install the app",
            detail:
                "Install it on the same organization or enterprise runner scope, then copy the installation ID from the installation settings URL."
        ),
        GitHubAppSetupStep(
            number: 4,
            title: "Finish in Tarmac",
            detail:
                "Enter the account slug, App ID, installation ID, scale set ID, and labels. Import the .pem file before running Check Setup."
        ),
    ]
}
