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
    var preparation: BaseImagePreparation?

    init(
        name: String = "Apple Platform",
        baseMacOSVersion: String = "",
        xcodeVersion: String = "",
        developerDirectory: String = "",
        commandLineToolsInstalled: Bool = false,
        sdks: [ApplePlatformSDK] = [],
        simulatorRuntimes: [AppleSimulatorRuntime] = [],
        capabilities: [AppleBuildCapability] = [],
        distribution: AppleDistributionToolchain = AppleDistributionToolchain(),
        preparation: BaseImagePreparation? = nil
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
        self.preparation = preparation
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
        case preparation
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
        preparation = try container.decodeIfPresent(BaseImagePreparation.self, forKey: .preparation)
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
        let inventory = preparation?.inventory ?? ToolchainInventory()

        if capability.requiresCommandLineTools && !commandLineToolsInstalled {
            issues.append(
                .init(
                    capability: capability,
                    message: "\(displayName): Command-line tools are missing for \(capability.displayName)."
                )
            )
        }

        if capability.requiresXcode && !inventory.xcodeLicenseAccepted {
            issues.append(
                .init(
                    capability: capability,
                    message: "\(displayName): Xcode license has not been accepted for \(capability.displayName)."
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
                    message:
                        "\(displayName): \(platform.displayName) SDK is missing for \(capability.displayName). "
                        + "Run `xcodebuild -showsdks` in the guest and record the matching simulator SDK before advertising `\(capability.label)`."
                )
            )
        }

        for platform in capability.requiredSimulatorRuntimes where !hasSimulatorRuntime(for: platform) {
            issues.append(
                .init(
                    capability: capability,
                    message:
                        "\(displayName): \(platform.displayName) simulator runtime is missing for \(capability.displayName). "
                        + "Run `xcrun simctl list runtimes` in the guest and install an available runtime before advertising `\(capability.label)`."
                )
            )
        }

        for tool in capability.requiredTools where !inventory.hasTool(tool) {
            issues.append(
                .init(
                    capability: capability,
                    message: "\(displayName): \(tool.displayName) is missing for \(capability.displayName)."
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

struct AppleBuildValidationWorkflow: Equatable, Hashable, Sendable {
    var runnerLabel: String
    var sdk: String?
    var destination: String?
    var command: String
    var buildSettings: [String]
    var requiresSigningCredentials: Bool
}

struct BaseImagePreparation: Codable, Hashable, Sendable {
    var baseImageIdentifier: String = ""
    var steps: [BaseImagePreparationStep] = BaseImagePreparationStep.defaultSteps
    var inventory: ToolchainInventory = ToolchainInventory()
    var updatedAt: Date?

    var completedStepCount: Int {
        steps.filter { $0.status == .completed }.count
    }
}

struct BaseImagePreparationStep: Codable, Hashable, Identifiable, Sendable {
    var id: BaseImagePreparationStepID
    var status: PreparationStepStatus = .notStarted
    var notes: String = ""
    var updatedAt: Date?

    static let defaultSteps: [BaseImagePreparationStep] = BaseImagePreparationStepID.allCases.map {
        BaseImagePreparationStep(id: $0)
    }
}

enum BaseImagePreparationStepID: String, Codable, CaseIterable, Identifiable, Sendable {
    case installXcode
    case acceptXcodeLicense
    case selectDeveloperDirectory
    case installCommandLineTools
    case installSimulatorRuntimes
    case installOptionalToolchains

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .installXcode: "Install Xcode"
        case .acceptXcodeLicense: "Accept Xcode license"
        case .selectDeveloperDirectory: "Select developer directory"
        case .installCommandLineTools: "Install command-line tools"
        case .installSimulatorRuntimes: "Install simulator runtimes"
        case .installOptionalToolchains: "Install optional toolchains"
        }
    }
}

enum PreparationStepStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case notStarted
    case inProgress
    case completed
    case blocked

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notStarted: "Not started"
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .blocked: "Blocked"
        }
    }
}

struct ToolchainInventory: Codable, Hashable, Sendable {
    var capturedAt: Date?
    var commandLineToolsVersion: String = ""
    var xcodeLicenseAccepted: Bool = false
    var flutterVersion: String = ""
    var dartVersion: String = ""
    var nodeVersion: String = ""
    var packageManagers: [PackageManagerInventory] = []
    var rubyVersion: String = ""
    var cocoaPodsVersion: String = ""
    var expoCLIVersion: String = ""
    var easCLIVersion: String = ""

    init(
        capturedAt: Date? = nil,
        commandLineToolsVersion: String = "",
        xcodeLicenseAccepted: Bool = false,
        flutterVersion: String = "",
        dartVersion: String = "",
        nodeVersion: String = "",
        packageManagers: [PackageManagerInventory] = [],
        rubyVersion: String = "",
        cocoaPodsVersion: String = "",
        expoCLIVersion: String = "",
        easCLIVersion: String = ""
    ) {
        self.capturedAt = capturedAt
        self.commandLineToolsVersion = commandLineToolsVersion
        self.xcodeLicenseAccepted = xcodeLicenseAccepted
        self.flutterVersion = flutterVersion
        self.dartVersion = dartVersion
        self.nodeVersion = nodeVersion
        self.packageManagers = packageManagers
        self.rubyVersion = rubyVersion
        self.cocoaPodsVersion = cocoaPodsVersion
        self.expoCLIVersion = expoCLIVersion
        self.easCLIVersion = easCLIVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt)
        commandLineToolsVersion = try container.decodeIfPresent(String.self, forKey: .commandLineToolsVersion) ?? ""
        xcodeLicenseAccepted = try container.decodeIfPresent(Bool.self, forKey: .xcodeLicenseAccepted) ?? false
        flutterVersion = try container.decodeIfPresent(String.self, forKey: .flutterVersion) ?? ""
        dartVersion = try container.decodeIfPresent(String.self, forKey: .dartVersion) ?? ""
        nodeVersion = try container.decodeIfPresent(String.self, forKey: .nodeVersion) ?? ""
        packageManagers =
            try container.decodeIfPresent([PackageManagerInventory].self, forKey: .packageManagers) ?? []
        rubyVersion = try container.decodeIfPresent(String.self, forKey: .rubyVersion) ?? ""
        cocoaPodsVersion = try container.decodeIfPresent(String.self, forKey: .cocoaPodsVersion) ?? ""
        expoCLIVersion = try container.decodeIfPresent(String.self, forKey: .expoCLIVersion) ?? ""
        easCLIVersion = try container.decodeIfPresent(String.self, forKey: .easCLIVersion) ?? ""
    }

    func hasTool(_ tool: AppleToolchainRequirement) -> Bool {
        switch tool {
        case .flutter:
            !flutterVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .dart:
            !dartVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .node:
            !nodeVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .packageManager:
            packageManagers.contains { !$0.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .ruby:
            !rubyVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .cocoaPods:
            !cocoaPodsVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .expoCLI:
            !expoCLIVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .easCLI:
            !easCLIVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct PackageManagerInventory: Codable, Hashable, Sendable {
    var manager: JavaScriptPackageManager
    var version: String
}

enum JavaScriptPackageManager: String, Codable, CaseIterable, Identifiable, Sendable {
    case npm
    case yarn
    case pnpm
    case bun

    var id: String { rawValue }
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

    var requiredTools: [AppleToolchainRequirement] {
        switch self {
        case .flutterIOS:
            [.flutter, .dart, .cocoaPods]
        case .reactNativeIOS:
            [.node, .packageManager, .ruby, .cocoaPods]
        case .expoIOS:
            [.node, .packageManager, .ruby, .cocoaPods, .expoCLI, .easCLI]
        case .xcode, .iOS, .watchOS, .tvOS, .visionOS, .spm, .macOSDistribution:
            []
        }
    }

    var unsignedValidationWorkflow: AppleBuildValidationWorkflow? {
        let unsignedSimulatorSettings = ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"]

        switch self {
        case .iOS:
            return AppleBuildValidationWorkflow(
                runnerLabel: label,
                sdk: "iphonesimulator",
                destination: "generic/platform=iOS Simulator",
                command: "xcodebuild build",
                buildSettings: unsignedSimulatorSettings,
                requiresSigningCredentials: false
            )
        case .watchOS:
            return AppleBuildValidationWorkflow(
                runnerLabel: label,
                sdk: "watchsimulator",
                destination: "generic/platform=watchOS Simulator",
                command: "xcodebuild build",
                buildSettings: unsignedSimulatorSettings,
                requiresSigningCredentials: false
            )
        case .tvOS:
            return AppleBuildValidationWorkflow(
                runnerLabel: label,
                sdk: "appletvsimulator",
                destination: "generic/platform=tvOS Simulator",
                command: "xcodebuild build",
                buildSettings: unsignedSimulatorSettings,
                requiresSigningCredentials: false
            )
        case .visionOS:
            return AppleBuildValidationWorkflow(
                runnerLabel: label,
                sdk: "xrsimulator",
                destination: "generic/platform=visionOS Simulator",
                command: "xcodebuild build",
                buildSettings: unsignedSimulatorSettings,
                requiresSigningCredentials: false
            )
        case .spm:
            return AppleBuildValidationWorkflow(
                runnerLabel: label,
                sdk: nil,
                destination: nil,
                command: "swift test",
                buildSettings: [],
                requiresSigningCredentials: false
            )
        case .reactNativeIOS:
            return AppleBuildValidationWorkflow(
                runnerLabel: label,
                sdk: "iphonesimulator",
                destination: "generic/platform=iOS Simulator",
                command: "bundle exec pod install && xcodebuild build",
                buildSettings: unsignedSimulatorSettings,
                requiresSigningCredentials: false
            )
        case .xcode, .macOSDistribution, .flutterIOS, .expoIOS:
            return nil
        }
    }
}

enum AppleToolchainRequirement: String, Codable, CaseIterable, Identifiable, Sendable {
    case flutter
    case dart
    case node
    case packageManager
    case ruby
    case cocoaPods
    case expoCLI
    case easCLI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flutter: "Flutter SDK"
        case .dart: "Dart SDK"
        case .node: "Node.js"
        case .packageManager: "JavaScript package manager"
        case .ruby: "Ruby"
        case .cocoaPods: "CocoaPods"
        case .expoCLI: "Expo CLI"
        case .easCLI: "EAS CLI"
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
