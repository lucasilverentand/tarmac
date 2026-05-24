import Foundation

struct AppleSigningAsset: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var displayName: String
    var teamId: String
    var bundleIdentifierPattern: String
    var selection: AppleSigningSelection
    var certificateCommonName: String
    var provisioningProfileUUID: String
    var certificateExpiresAt: Date?
    var provisioningProfileExpiresAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        teamId: String,
        bundleIdentifierPattern: String,
        selection: AppleSigningSelection = AppleSigningSelection(),
        certificateCommonName: String = "",
        provisioningProfileUUID: String = "",
        certificateExpiresAt: Date? = nil,
        provisioningProfileExpiresAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.teamId = teamId
        self.bundleIdentifierPattern = bundleIdentifierPattern
        self.selection = selection
        self.certificateCommonName = certificateCommonName
        self.provisioningProfileUUID = provisioningProfileUUID
        self.certificateExpiresAt = certificateExpiresAt
        self.provisioningProfileExpiresAt = provisioningProfileExpiresAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case teamId
        case bundleIdentifierPattern
        case selection
        case certificateCommonName
        case provisioningProfileUUID
        case certificateExpiresAt
        case provisioningProfileExpiresAt
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayName = try container.decode(String.self, forKey: .displayName)
        teamId = try container.decode(String.self, forKey: .teamId)
        bundleIdentifierPattern = try container.decode(String.self, forKey: .bundleIdentifierPattern)
        selection =
            try container.decodeIfPresent(AppleSigningSelection.self, forKey: .selection) ?? AppleSigningSelection()
        certificateCommonName = try container.decodeIfPresent(String.self, forKey: .certificateCommonName) ?? ""
        provisioningProfileUUID = try container.decodeIfPresent(String.self, forKey: .provisioningProfileUUID) ?? ""
        certificateExpiresAt = try container.decodeIfPresent(Date.self, forKey: .certificateExpiresAt)
        provisioningProfileExpiresAt = try container.decodeIfPresent(Date.self, forKey: .provisioningProfileExpiresAt)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    var certificateKeychainKey: String {
        "apple-signing-certificate-p12-\(id.uuidString)"
    }

    var passphraseKeychainKey: String {
        "apple-signing-certificate-passphrase-\(id.uuidString)"
    }

    var provisioningProfileKeychainKey: String {
        "apple-signing-provisioning-profile-\(id.uuidString)"
    }

    func matches(bundleIdentifier: String) -> Bool {
        let pattern = bundleIdentifierPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return false }
        if pattern == "*" {
            return true
        }
        if pattern.hasSuffix(".*") {
            let baseIdentifier = String(pattern.dropLast(2))
            let lowercaseBundle = bundleIdentifier.lowercased()
            let lowercaseBase = baseIdentifier.lowercased()
            return lowercaseBundle == lowercaseBase || lowercaseBundle.hasPrefix("\(lowercaseBase).")
        }
        return bundleIdentifier.localizedCaseInsensitiveCompare(pattern) == .orderedSame
    }
}

enum AppleSigningSelectionMode: String, Codable, CaseIterable, Sendable {
    case disabled
    case allJobs
    case selectedJobs
}

struct AppleSigningSelection: Codable, Hashable, Sendable {
    var mode: AppleSigningSelectionMode = .disabled
    var organizationNames: [String] = []
    var repositoryNames: [String] = []
    var runnerImageProfileNames: [String] = []
    var workflowNames: [String] = []

    init(
        mode: AppleSigningSelectionMode = .disabled,
        organizationNames: [String] = [],
        repositoryNames: [String] = [],
        runnerImageProfileNames: [String] = [],
        workflowNames: [String] = []
    ) {
        self.mode = mode
        self.organizationNames = organizationNames
        self.repositoryNames = repositoryNames
        self.runnerImageProfileNames = runnerImageProfileNames
        self.workflowNames = workflowNames
    }

    func matches(job: RunnerJob, organization: Organization) -> Bool {
        switch mode {
        case .disabled:
            return false
        case .allJobs:
            return true
        case .selectedJobs:
            let hasAnyScope =
                !organizationNames.isEmpty
                || !repositoryNames.isEmpty
                || !runnerImageProfileNames.isEmpty
                || !workflowNames.isEmpty
            guard hasAnyScope else { return false }

            return matches(organization.name, in: organizationNames)
                && matches(job.repositoryName, in: repositoryNames)
                && matches(organization.imageProfile?.name, in: runnerImageProfileNames)
                && matches(job.workflowName, in: workflowNames)
        }
    }

    private func matches(_ value: String?, in candidates: [String]) -> Bool {
        guard !candidates.isEmpty else { return true }
        guard let value else { return false }
        let normalizedValue = normalize(value)
        return candidates.contains { normalize($0) == normalizedValue }
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct AppleSigningInjection: Equatable, Sendable {
    var asset: AppleSigningAsset
    var certificateData: Data
    var certificatePassphrase: String
    var provisioningProfileData: Data
}

enum AppleSigningAssetValidationIssue: String, Codable, Equatable, Sendable {
    case missingDisplayName
    case missingTeamId
    case missingBundleIdentifierPattern
    case missingCertificate
    case missingCertificatePassphrase
    case missingProvisioningProfile
    case expiredCertificate
    case expiredProvisioningProfile
    case bundleIdentifierMismatch
}

struct AppleSigningAssetValidation: Equatable, Sendable {
    var assetId: UUID
    var issues: [AppleSigningAssetValidationIssue]

    var isReady: Bool {
        issues.isEmpty
    }
}

enum AppleSigningDispatchError: Error, LocalizedError, Equatable, Sendable {
    case invalidAsset(assetName: String, issues: [AppleSigningAssetValidationIssue])
    case missingMaterial(assetName: String)

    var errorDescription: String? {
        switch self {
        case .invalidAsset(let assetName, let issues):
            let issueList = issues.map(\.rawValue).joined(separator: ", ")
            return "Apple signing asset \(assetName) is not ready: \(issueList)"
        case .missingMaterial(let assetName):
            return "Apple signing asset \(assetName) could not be loaded from keychain"
        }
    }
}
