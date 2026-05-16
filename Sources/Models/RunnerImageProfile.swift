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
