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
    var preparation: BaseImagePreparation?

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

        for tool in capability.requiredTools where !inventory.hasTool(tool) {
            issues.append(
                .init(
                    capability: capability,
                    message: "\(displayName): \(tool.displayName) is missing for \(capability.displayName)."
                )
            )
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
    var cocoaPodsVersion: String = ""
    var expoCLIVersion: String = ""
    var easCLIVersion: String = ""

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
        case .spm:
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
        case .xcode, .spm:
            []
        }
    }

    var requiredTools: [AppleToolchainRequirement] {
        switch self {
        case .flutterIOS:
            [.flutter, .dart, .cocoaPods]
        case .reactNativeIOS:
            [.node, .packageManager, .cocoaPods]
        case .expoIOS:
            [.node, .packageManager, .cocoaPods, .expoCLI, .easCLI]
        case .xcode, .iOS, .watchOS, .tvOS, .visionOS, .spm:
            []
        }
    }
}

enum AppleToolchainRequirement: String, Codable, CaseIterable, Identifiable, Sendable {
    case flutter
    case dart
    case node
    case packageManager
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
