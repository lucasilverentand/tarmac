import Foundation

enum RunnerReleaseChannel: String, Codable, CaseIterable, Hashable, Sendable {
    case appStore
    case beta
    case custom

    var displayName: String {
        switch self {
        case .appStore: "App Store"
        case .beta: "Beta / TestFlight"
        case .custom: "Custom"
        }
    }
}

/// A routable runner pool backed by one macOS image and one independent warm VM.
struct RunnerPoolConfiguration: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var releaseChannel: RunnerReleaseChannel
    var isEnabled: Bool
    var keepsWarmRunner: Bool
    var scaleSetId: Int?
    var scaleSetName: String?
    var routingLabels: [String]
    var platformDirectoryPath: String
    var imageProfile: RunnerImageProfile

    init(
        id: UUID = UUID(),
        name: String,
        releaseChannel: RunnerReleaseChannel = .custom,
        isEnabled: Bool = true,
        keepsWarmRunner: Bool = true,
        scaleSetId: Int? = nil,
        scaleSetName: String? = nil,
        routingLabels: [String] = [],
        platformDirectoryPath: String = "",
        imageProfile: RunnerImageProfile
    ) {
        self.id = id
        self.name = name
        self.releaseChannel = releaseChannel
        self.isEnabled = isEnabled
        self.keepsWarmRunner = keepsWarmRunner
        self.scaleSetId = scaleSetId
        self.scaleSetName = scaleSetName
        self.routingLabels = Self.normalizedLabels(routingLabels)
        self.platformDirectoryPath = platformDirectoryPath
        self.imageProfile = imageProfile
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? releaseChannel.displayName : trimmed
    }

    var advertisedLabels: [String] {
        Self.normalizedLabels(routingLabels + imageProfile.advertisedLabels)
    }

    func resolvedBaseImagePath(defaultPath: String) -> String {
        imageProfile.resolvedBaseImagePath(defaultPath: defaultPath)
    }

    func resolvedPlatformDirectoryPath(storageRootPath: String) -> String {
        let trimmed = platformDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }

        let basePath = resolvedBaseImagePath(
            defaultPath: URL(fileURLWithPath: storageRootPath)
                .appendingPathComponent("BaseImage.img")
                .path
        )
        return URL(fileURLWithPath: basePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Platform", isDirectory: true)
            .path
    }

    func runtimeStorageRootPath(storageRootPath: String) -> String {
        URL(fileURLWithPath: storageRootPath)
            .appendingPathComponent("Pools", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            .path
    }

    func matches(requestedLabels: [String]) -> Bool {
        let requested = Set(requestedLabels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let routes = routingLabels.map { $0.lowercased() }
        return routes.contains(where: requested.contains)
    }

    private static func normalizedLabels(_ labels: [String]) -> [String] {
        var seen: Set<String> = []
        return labels.compactMap { label in
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }
}

extension RunnerPoolConfiguration {
    static func approvedAppleReleaseMatrix(
        account: RunnerAccount,
        storageRootPath: String,
        defaultBaseImagePath: String,
        defaultVMConfiguration: VMConfiguration
    ) -> [RunnerPoolConfiguration] {
        let root = URL(fileURLWithPath: storageRootPath)
        let stableRoot =
            root
            .appendingPathComponent("Images", isDirectory: true)
            .appendingPathComponent("app-store-macos-26", isDirectory: true)
        let betaRoot = URL(fileURLWithPath: defaultBaseImagePath).deletingLastPathComponent()
        let legacyProfile = account.imageProfile
        let legacyLooksStable =
            legacyProfile.map {
                $0.baseMacOSVersion.hasPrefix("26") || $0.xcodeVersion.hasPrefix("26")
            } ?? false

        let stableProfile =
            legacyLooksStable
            ? legacyProfile!
            : RunnerImageProfile(
                name: "macOS 26 + Xcode 26.6",
                baseImagePath: stableRoot.appendingPathComponent("BaseImage.img").path,
                vmConfiguration: defaultVMConfiguration,
                baseMacOSVersion: "26",
                xcodeVersion: "26.6",
                developerDirectory: "/Applications/Xcode.app/Contents/Developer",
                commandLineToolsInstalled: true,
                capabilities: [.xcode]
            )
        let betaProfile =
            legacyLooksStable
            ? RunnerImageProfile(
                name: "macOS 27 + Xcode 27 beta 3",
                baseImagePath:
                    root
                    .appendingPathComponent("Images", isDirectory: true)
                    .appendingPathComponent("beta-macos-27", isDirectory: true)
                    .appendingPathComponent("BaseImage.img")
                    .path,
                vmConfiguration: defaultVMConfiguration,
                baseMacOSVersion: "27",
                xcodeVersion: "27 beta 3",
                developerDirectory: "/Applications/Xcode-beta.app/Contents/Developer",
                commandLineToolsInstalled: true,
                capabilities: [.xcode]
            )
            : legacyProfile
                ?? RunnerImageProfile(
                    name: "macOS 27 + Xcode 27 beta 3",
                    baseImagePath: defaultBaseImagePath,
                    vmConfiguration: defaultVMConfiguration,
                    baseMacOSVersion: "27",
                    xcodeVersion: "27 beta 3",
                    developerDirectory: "/Applications/Xcode-beta.app/Contents/Developer",
                    commandLineToolsInstalled: true,
                    capabilities: [.xcode]
                )

        return [
            RunnerPoolConfiguration(
                name: "Stable production",
                releaseChannel: .appStore,
                isEnabled: legacyLooksStable,
                scaleSetId: legacyLooksStable ? account.scaleSetId : nil,
                scaleSetName: legacyLooksStable ? account.scaleSetName : "tarmac-app-store",
                routingLabels: ["tarmac-app-store", "macos-26", "xcode-26"],
                platformDirectoryPath: legacyLooksStable
                    ? betaRoot.appendingPathComponent("Platform", isDirectory: true).path
                    : stableRoot.appendingPathComponent("Platform", isDirectory: true).path,
                imageProfile: stableProfile
            ),
            RunnerPoolConfiguration(
                name: "Beta / TestFlight",
                releaseChannel: .beta,
                isEnabled: !legacyLooksStable,
                scaleSetId: legacyLooksStable ? nil : account.scaleSetId,
                scaleSetName: legacyLooksStable ? "tarmac-beta" : account.scaleSetName,
                routingLabels: ["tarmac-beta", "macos-27", "xcode-27-beta"],
                platformDirectoryPath: betaRoot.appendingPathComponent("Platform", isDirectory: true).path,
                imageProfile: betaProfile
            ),
        ]
    }
}
