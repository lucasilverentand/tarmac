import Foundation
import Testing

@testable import Tarmac

@Suite("RunnerImageProfile")
struct RunnerImageProfileTests {
    @Test("ready profile derives Apple capability labels")
    func derivesReadyLabels() {
        let profile = RunnerImageProfile(
            name: "Xcode 17",
            baseMacOSVersion: "26.0",
            xcodeVersion: "17.0",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            commandLineToolsInstalled: true,
            sdks: [
                ApplePlatformSDK(platform: .macOS, version: "26.0"),
                ApplePlatformSDK(platform: .iOS, version: "19.0"),
            ],
            simulatorRuntimes: [
                AppleSimulatorRuntime(platform: .iOS, version: "19.0")
            ],
            capabilities: [.xcode, .spm, .iOS, .reactNativeIOS],
            preparation: BaseImagePreparation(
                inventory: ToolchainInventory(
                    xcodeLicenseAccepted: true,
                    nodeVersion: "24.0",
                    packageManagers: [PackageManagerInventory(manager: .npm, version: "10.8")],
                    cocoaPodsVersion: "1.16"
                )
            )
        )

        #expect(profile.isReady)
        #expect(profile.advertisedLabels == ["xcode", "ios", "spm", "react-native-ios"])
    }

    @Test("missing Xcode, SDK, and simulator runtime block capability labels")
    func missingToolsBlockCapabilityLabels() {
        let profile = RunnerImageProfile(
            name: "Incomplete image",
            baseMacOSVersion: "26.0",
            xcodeVersion: "",
            developerDirectory: "",
            commandLineToolsInstalled: true,
            sdks: [],
            simulatorRuntimes: [],
            capabilities: [.iOS]
        )

        #expect(!profile.isReady)
        #expect(profile.advertisedLabels.isEmpty)
        #expect(profile.readinessIssues.contains { $0.message.contains("Xcode version") })
        #expect(profile.readinessIssues.contains { $0.message.contains("Xcode license") })
        #expect(profile.readinessIssues.contains { $0.message.contains("iOS SDK") })
        #expect(profile.readinessIssues.contains { $0.message.contains("iOS simulator runtime") })
    }

    @Test("optional Apple toolchains block specialized profile labels")
    func optionalToolsBlockSpecializedLabels() {
        let profile = RunnerImageProfile(
            name: "Flutter image",
            baseMacOSVersion: "26.0",
            xcodeVersion: "17.0",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            commandLineToolsInstalled: true,
            sdks: [ApplePlatformSDK(platform: .iOS, version: "19.0")],
            simulatorRuntimes: [AppleSimulatorRuntime(platform: .iOS, version: "19.0")],
            capabilities: [.flutterIOS],
            preparation: BaseImagePreparation(
                inventory: ToolchainInventory(xcodeLicenseAccepted: true, flutterVersion: "3.32")
            )
        )

        #expect(!profile.isReady)
        #expect(profile.advertisedLabels.isEmpty)
        #expect(profile.readinessIssues.contains { $0.message.contains("Dart SDK") })
        #expect(profile.readinessIssues.contains { $0.message.contains("CocoaPods") })
    }

    @Test("complete optional Apple toolchain advertises specialized profile label")
    func completeOptionalToolchainAdvertisesLabel() {
        let profile = RunnerImageProfile(
            name: "Expo image",
            baseMacOSVersion: "26.0",
            xcodeVersion: "17.0",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            commandLineToolsInstalled: true,
            sdks: [ApplePlatformSDK(platform: .iOS, version: "19.0")],
            simulatorRuntimes: [AppleSimulatorRuntime(platform: .iOS, version: "19.0")],
            capabilities: [.expoIOS],
            preparation: BaseImagePreparation(
                inventory: ToolchainInventory(
                    xcodeLicenseAccepted: true,
                    nodeVersion: "24.0",
                    packageManagers: [PackageManagerInventory(manager: .pnpm, version: "10.0")],
                    cocoaPodsVersion: "1.16",
                    expoCLIVersion: "0.24",
                    easCLIVersion: "16.0"
                )
            )
        )

        #expect(profile.isReady)
        #expect(profile.advertisedLabels == ["expo-ios"])
    }

    @Test("organization runner labels merge static and profile labels")
    func organizationRunnerLabelsMergeProfileLabels() {
        let profile = RunnerImageProfile(
            name: "Xcode 17",
            baseMacOSVersion: "26.0",
            xcodeVersion: "17.0",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            commandLineToolsInstalled: true,
            sdks: [ApplePlatformSDK(platform: .macOS, version: "26.0")],
            simulatorRuntimes: [],
            capabilities: [.xcode, .spm],
            preparation: BaseImagePreparation(
                inventory: ToolchainInventory(xcodeLicenseAccepted: true)
            )
        )
        let org = Organization(
            name: "org",
            appId: "1",
            installationId: 1,
            labels: ["self-hosted", "macOS", "xcode"],
            imageProfile: profile
        )

        #expect(org.runnerLabels == ["self-hosted", "macOS", "xcode", "spm"])
    }
}
