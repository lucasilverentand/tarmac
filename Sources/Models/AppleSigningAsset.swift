import Foundation

struct AppleSigningAsset: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var displayName: String
    var teamId: String
    var bundleIdentifierPattern: String
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
        self.certificateCommonName = certificateCommonName
        self.provisioningProfileUUID = provisioningProfileUUID
        self.certificateExpiresAt = certificateExpiresAt
        self.provisioningProfileExpiresAt = provisioningProfileExpiresAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
