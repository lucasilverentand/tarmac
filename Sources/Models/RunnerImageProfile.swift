import Foundation

struct RunnerImageProfile: Codable, Hashable, Sendable {
    var name: String = "Apple Platform"
    var baseMacOSVersion: String = ""
    var xcodeVersion: String = ""
    var developerDirectory: String = ""
    var commandLineToolsInstalled: Bool = false
    var sdks: [ApplePlatformSDK] = []
    var simulatorRuntimes: [AppleSimulatorRuntime] = []
    var capabilities: [AppleBuildCapability] = []
    var distribution: AppleDistributionToolchain = AppleDistributionToolchain()

    init(
        name: String = "Apple Platform",
        baseMacOSVersion: String = "",
        xcodeVersion: String = "",
        developerDirectory: String = "",
        commandLineToolsInstalled: Bool = false,
        sdks: [ApplePlatformSDK] = [],
        simulatorRuntimes: [AppleSimulatorRuntime] = [],
        capabilities: [AppleBuildCapability] = [],
        distribution: AppleDistributionToolchain = AppleDistributionToolchain()
    ) {
        self.name = name
        self.baseMacOSVersion = baseMacOSVersion
        self.xcodeVersion = xcodeVersion
        self.developerDirectory = developerDirectory
        self.commandLineToolsInstalled = commandLineToolsInstalled
        self.sdks = sdks
        self.simulatorRuntimes = simulatorRuntimes
        self.capabilities = capabilities
        self.distribution = distribution
    }

    enum CodingKeys: String, CodingKey {
        case name
        case baseMacOSVersion
        case xcodeVersion
        case developerDirectory
        case commandLineToolsInstalled
        case sdks
        case simulatorRuntimes
        case capabilities
        case distribution
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Apple Platform"
        baseMacOSVersion = try container.decodeIfPresent(String.self, forKey: .baseMacOSVersion) ?? ""
        xcodeVersion = try container.decodeIfPresent(String.self, forKey: .xcodeVersion) ?? ""
        developerDirectory = try container.decodeIfPresent(String.self, forKey: .developerDirectory) ?? ""
        commandLineToolsInstalled =
            try container.decodeIfPresent(Bool.self, forKey: .commandLineToolsInstalled) ?? false
        sdks = try container.decodeIfPresent([ApplePlatformSDK].self, forKey: .sdks) ?? []
        simulatorRuntimes =
            try container.decodeIfPresent([AppleSimulatorRuntime].self, forKey: .simulatorRuntimes) ?? []
        capabilities = try container.decodeIfPresent([AppleBuildCapability].self, forKey: .capabilities) ?? []
        distribution = try container.decodeIfPresent(AppleDistributionToolchain.self, forKey: .distribution) ?? .init()
    }

    var advertisedLabels: [String] {
        AppleBuildCapability.allCases
            .filter { capabilities.contains($0) && readinessIssues(for: $0).isEmpty }
            .map(\.label)
    }

    var readinessIssues: [RunnerImageProfileReadinessIssue] {
        var issues: [RunnerImageProfileReadinessIssue] = []

        let selectedCapabilities = AppleBuildCapability.allCases.filter { capabilities.contains($0) }
        if selectedCapabilities.isEmpty {
            issues.append(
                .init(
                    capability: nil,
                    message: "\(displayName): Select at least one build capability to advertise."
                )
            )
            return issues
        }

        for capability in selectedCapabilities {
            issues.append(contentsOf: readinessIssues(for: capability))
        }

        return Array(OrderedSet(issues))
    }

    var isReady: Bool {
        readinessIssues.isEmpty
    }

    private var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Runner image profile" : name
    }

    private func readinessIssues(for capability: AppleBuildCapability) -> [RunnerImageProfileReadinessIssue] {
        var issues: [RunnerImageProfileReadinessIssue] = []

        if capability.requiresCommandLineTools && !commandLineToolsInstalled {
            issues.append(
                .init(
                    capability: capability,
                    message: "\(displayName): Command-line tools are missing for \(capability.displayName)."
                )
            )
        }

        if capability.requiresXcode {
            if xcodeVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(
                    .init(
                        capability: capability,
                        message: "\(displayName): Xcode version is missing for \(capability.displayName)."
                    )
                )
            }
            if developerDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(
                    .init(
                        capability: capability,
                        message:
                            "\(displayName): Selected developer directory is missing for \(capability.displayName)."
                    )
                )
            }
        }

        for platform in capability.requiredSDKs where !hasSDK(for: platform) {
            issues.append(
                .init(
                    capability: capability,
                    message: "\(displayName): \(platform.displayName) SDK is missing for \(capability.displayName)."
                )
            )
        }

        for platform in capability.requiredSimulatorRuntimes where !hasSimulatorRuntime(for: platform) {
            issues.append(
                .init(
                    capability: capability,
                    message:
                        "\(displayName): \(platform.displayName) simulator runtime is missing for \(capability.displayName)."
                )
            )
        }

        if capability == .macOSDistribution {
            issues.append(contentsOf: distribution.readinessIssues(profileName: displayName, capability: capability))
        }

        return issues
    }

    private func hasSDK(for platform: ApplePlatform) -> Bool {
        sdks.contains { $0.platform == platform && !$0.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func hasSimulatorRuntime(for platform: ApplePlatform) -> Bool {
        simulatorRuntimes.contains {
            $0.platform == platform
                && $0.isAvailable
                && !$0.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct RunnerImageProfileReadinessIssue: Equatable, Hashable, Sendable {
    let capability: AppleBuildCapability?
    let message: String
}

struct ApplePlatformSDK: Codable, Hashable, Sendable {
    var platform: ApplePlatform
    var version: String
}

struct AppleSimulatorRuntime: Codable, Hashable, Sendable {
    var platform: ApplePlatform
    var version: String
    var isAvailable: Bool = true
}

struct AppleDistributionToolchain: Codable, Hashable, Sendable {
    var notarytoolInstalled: Bool = false
    var productbuildInstalled: Bool = false
    var pkgbuildInstalled: Bool = false
    var hdiutilInstalled: Bool = false
    var staplerInstalled: Bool = false
    var developerIDApplicationIdentity: String = ""
    var developerIDInstallerIdentity: String = ""
    var notarizationCredentialSource: AppleNotarizationCredentialSource = .jobEnvironment
    var notarizationCredentialsConfigured: Bool = false

    var installedToolNames: [String] {
        [
            (notarytoolInstalled, "notarytool"),
            (productbuildInstalled, "productbuild"),
            (pkgbuildInstalled, "pkgbuild"),
            (hdiutilInstalled, "hdiutil"),
            (staplerInstalled, "stapler"),
        ].compactMap { installed, name in installed ? name : nil }
    }

    fileprivate func readinessIssues(
        profileName: String,
        capability: AppleBuildCapability
    ) -> [RunnerImageProfileReadinessIssue] {
        var issues: [RunnerImageProfileReadinessIssue] = []

        for missingTool in missingToolNames {
            issues.append(
                .init(
                    capability: capability,
                    message: "\(profileName): \(missingTool) is missing for \(capability.displayName)."
                )
            )
        }

        if developerIDApplicationIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(
                .init(
                    capability: capability,
                    message: "\(profileName): Developer ID Application signing identity is missing."
                )
            )
        }

        if developerIDInstallerIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(
                .init(
                    capability: capability,
                    message: "\(profileName): Developer ID Installer signing identity is missing."
                )
            )
        }

        if !notarizationCredentialsConfigured {
            issues.append(
                .init(
                    capability: capability,
                    message:
                        "\(profileName): Notarization credentials are not configured through \(notarizationCredentialSource.displayName)."
                )
            )
        }

        return issues
    }

    private var missingToolNames: [String] {
        [
            (notarytoolInstalled, "notarytool"),
            (productbuildInstalled, "productbuild"),
            (pkgbuildInstalled, "pkgbuild"),
            (hdiutilInstalled, "hdiutil"),
            (staplerInstalled, "stapler"),
        ].compactMap { installed, name in installed ? nil : name }
    }
}

enum AppleNotarizationCredentialSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case jobEnvironment = "job-environment"
    case appStoreConnectAPIKey = "app-store-connect-api-key"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jobEnvironment: "per-job environment secrets"
        case .appStoreConnectAPIKey: "App Store Connect API key secrets"
        }
    }
}

enum ApplePlatform: String, Codable, CaseIterable, Identifiable, Sendable {
    case macOS = "macos"
    case iOS = "ios"
    case watchOS = "watchos"
    case tvOS = "tvos"
    case visionOS = "visionos"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .iOS: "iOS"
        case .watchOS: "watchOS"
        case .tvOS: "tvOS"
        case .visionOS: "visionOS"
        }
    }
}

enum AppleBuildCapability: String, Codable, CaseIterable, Identifiable, Sendable {
    case xcode
    case iOS = "ios"
    case watchOS = "watchos"
    case tvOS = "tvos"
    case visionOS = "visionos"
    case spm
    case macOSDistribution = "macos-distribution"
    case flutterIOS = "flutter-ios"
    case reactNativeIOS = "react-native-ios"
    case expoIOS = "expo-ios"

    var id: String { rawValue }
    var label: String { rawValue }

    var displayName: String {
        switch self {
        case .xcode: "Xcode"
        case .iOS: "iOS"
        case .watchOS: "watchOS"
        case .tvOS: "tvOS"
        case .visionOS: "visionOS"
        case .spm: "Swift Package Manager"
        case .macOSDistribution: "macOS Distribution"
        case .flutterIOS: "Flutter iOS"
        case .reactNativeIOS: "React Native iOS"
        case .expoIOS: "Expo iOS"
        }
    }

    var requiresCommandLineTools: Bool {
        true
    }

    var requiresXcode: Bool {
        true
    }

    var requiredSDKs: [ApplePlatform] {
        switch self {
        case .xcode:
            []
        case .iOS, .flutterIOS, .reactNativeIOS, .expoIOS:
            [.iOS]
        case .watchOS:
            [.watchOS]
        case .tvOS:
            [.tvOS]
        case .visionOS:
            [.visionOS]
        case .spm, .macOSDistribution:
            [.macOS]
        }
    }

    var requiredSimulatorRuntimes: [ApplePlatform] {
        switch self {
        case .iOS, .flutterIOS, .reactNativeIOS, .expoIOS:
            [.iOS]
        case .watchOS:
            [.watchOS]
        case .tvOS:
            [.tvOS]
        case .visionOS:
            [.visionOS]
        case .xcode, .spm, .macOSDistribution:
            []
        }
    }
}

private struct OrderedSet<Element: Hashable>: Sequence {
    private var elements: [Element] = []

    init(_ values: [Element]) {
        var seen: Set<Element> = []
        for value in values where seen.insert(value).inserted {
            elements.append(value)
        }
    }

    func makeIterator() -> IndexingIterator<[Element]> {
        elements.makeIterator()
    }
}
