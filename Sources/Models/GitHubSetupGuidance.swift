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
            "Install the GitHub App on the organization, enter the organization name and App ID, import the private key, then let Tarmac find the organization installation ID."
    )

    static let repository = GitHubSetupGuidance(
        scope: .repository,
        title: "Repository filters do not replace GitHub visibility",
        detail:
            "The repository filter only decides which queued jobs Tarmac accepts after GitHub sends them. Configure runner group repository access in GitHub so workflows can only target the repositories you intend."
    )

    static let enterprise = GitHubSetupGuidance(
        scope: .enterprise,
        title: "Enterprise runner accounts use access tokens",
        detail:
            "Enterprise-level runner APIs are scoped to the enterprise account. Add the enterprise slug and save an access token with enterprise runner management permission."
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
            "Use this when Tarmac should receive jobs from one GitHub organization. Register the app under that organization, install it on the same organization, then import the private key so Tarmac can find the installation ID.",
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
                    "Click Find Installation after the app is installed on the organization. Tarmac reads /orgs/<org>/installation with the app private key."
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
        title: "Create an enterprise-owned app for organization installs",
        summary:
            "Use this for organization runner accounts when one enterprise-owned app should be installed into several runner organizations. Enterprise-level runner accounts use an enterprise access token instead.",
        registrationOwnerPath: "enterprises",
        documentationURL:
            "https://docs.github.com/en/enterprise-cloud@latest/admin/managing-github-apps-for-your-enterprise/creating-github-apps-for-your-enterprise",
        appFields: standardAppFields + [
            GitHubAppFormFieldGuide(
                kind: .visibility,
                field: "Enterprise installation",
                value: "Optional; not the runner installation ID",
                detail:
                    "Use organization installs for organization runner accounts. Enterprise runner accounts do not use GitHub App installation tokens."
            )
        ],
        tarmacFields: [
            TarmacAccountFieldGuide(
                kind: .type,
                field: "Type",
                detail:
                    "Choose Organization when using this GitHub App flow. Choose Enterprise only when configuring enterprise-level runners with an access token."
            ),
            TarmacAccountFieldGuide(
                kind: .accountName,
                field: "Organization name",
                detail:
                    "Enter the organization login that owns the runner scale set, even when the app itself is owned by the enterprise."
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
                    "Install the app on the organization, then click Find Installation in Tarmac. Do not paste the enterprise installation ID; it cannot create organization runner tokens."
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
                    "Enter the numeric organization runner scale set ID that Tarmac should poll for queued jobs."
            ),
            TarmacAccountFieldGuide(
                kind: .labels,
                field: "Runner labels",
                detail:
                    "Keep self-hosted and add the labels workflows use in runs-on, such as macOS and ARM64."
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
                "Tarmac uses the App ID and private key to find the org installation, then creates installation access tokens."
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
                "Install it on the organization that owns the runner scale set. If the app is enterprise-owned, install it into each runner organization."
        ),
        GitHubAppSetupStep(
            number: 4,
            title: "Finish in Tarmac",
            detail:
                "Enter the organization name, App ID, scale set ID, and labels. Import the .pem file, click Find Installation, then run Check Setup."
        ),
    ]
}
