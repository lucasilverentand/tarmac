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
                    rubyVersion: "3.3",
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
        #expect(profile.readinessIssues.contains { $0.message.contains("xcodebuild -showsdks") })
        #expect(profile.readinessIssues.contains { $0.message.contains("iOS simulator runtime") })
        #expect(profile.readinessIssues.contains { $0.message.contains("xcrun simctl list runtimes") })
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

    @Test("React Native iOS readiness requires Ruby and CocoaPods")
    func reactNativeReadinessRequiresRubyAndCocoaPods() {
        let profile = RunnerImageProfile(
            name: "React Native image",
            baseMacOSVersion: "26.0",
            xcodeVersion: "17.0",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            commandLineToolsInstalled: true,
            sdks: [ApplePlatformSDK(platform: .iOS, version: "19.0")],
            simulatorRuntimes: [AppleSimulatorRuntime(platform: .iOS, version: "19.0")],
            capabilities: [.reactNativeIOS],
            preparation: BaseImagePreparation(
                inventory: ToolchainInventory(
                    xcodeLicenseAccepted: true,
                    nodeVersion: "24.0",
                    packageManagers: [PackageManagerInventory(manager: .yarn, version: "1.22")]
                )
            )
        )

        #expect(!profile.isReady)
        #expect(profile.advertisedLabels.isEmpty)
        #expect(profile.readinessIssues.contains { $0.message.contains("Ruby") })
        #expect(profile.readinessIssues.contains { $0.message.contains("CocoaPods") })
    }

    @Test("toolchain inventory decodes older records without Ruby")
    func toolchainInventoryDecodesOlderRecordsWithoutRuby() throws {
        let data = Data(
            """
            {
              "xcodeLicenseAccepted": true,
              "nodeVersion": "24.0",
              "packageManagers": [{ "manager": "npm", "version": "10.8" }],
              "cocoaPodsVersion": "1.16"
            }
            """.utf8
        )

        let inventory = try JSONDecoder().decode(ToolchainInventory.self, from: data)

        #expect(inventory.xcodeLicenseAccepted)
        #expect(inventory.nodeVersion == "24.0")
        #expect(inventory.packageManagers == [PackageManagerInventory(manager: .npm, version: "10.8")])
        #expect(inventory.rubyVersion == "")
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
                    rubyVersion: "3.3",
                    cocoaPodsVersion: "1.16",
                    expoCLIVersion: "0.24",
                    easCLIVersion: "16.0"
                )
            )
        )

        #expect(profile.isReady)
        #expect(profile.advertisedLabels == ["expo-ios"])
    }

    @Test("complete Flutter iOS toolchain advertises Flutter label")
    func completeFlutterToolchainAdvertisesLabel() {
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
                inventory: ToolchainInventory(
                    xcodeLicenseAccepted: true,
                    flutterVersion: "3.32",
                    dartVersion: "3.8",
                    cocoaPodsVersion: "1.16"
                )
            )
        )

        #expect(profile.isReady)
        #expect(profile.advertisedLabels == ["flutter-ios"])
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

    @Test("Apple platform capabilities expose unsigned validation workflows")
    func applePlatformCapabilitiesExposeUnsignedValidationWorkflows() {
        #expect(
            AppleBuildCapability.iOS.unsignedValidationWorkflow
                == AppleBuildValidationWorkflow(
                    runnerLabel: "ios",
                    sdk: "iphonesimulator",
                    destination: "generic/platform=iOS Simulator",
                    command: "xcodebuild build",
                    buildSettings: ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"],
                    requiresSigningCredentials: false
                )
        )
        #expect(AppleBuildCapability.watchOS.unsignedValidationWorkflow?.sdk == "watchsimulator")
        #expect(AppleBuildCapability.tvOS.unsignedValidationWorkflow?.sdk == "appletvsimulator")
        #expect(AppleBuildCapability.visionOS.unsignedValidationWorkflow?.sdk == "xrsimulator")
        #expect(AppleBuildCapability.spm.unsignedValidationWorkflow?.command == "swift test")
        #expect(
            AppleBuildCapability.flutterIOS.unsignedValidationWorkflow
                == AppleBuildValidationWorkflow(
                    runnerLabel: "flutter-ios",
                    sdk: nil,
                    destination: nil,
                    command: "flutter build ios --simulator --debug --no-codesign",
                    buildSettings: [],
                    requiresSigningCredentials: false
                )
        )
        #expect(
            AppleBuildCapability.reactNativeIOS.unsignedValidationWorkflow
                == AppleBuildValidationWorkflow(
                    runnerLabel: "react-native-ios",
                    sdk: "iphonesimulator",
                    destination: "generic/platform=iOS Simulator",
                    command: "bundle exec pod install && xcodebuild build",
                    buildSettings: ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"],
                    requiresSigningCredentials: false
                )
        )
    }

    @Test("unavailable simulator runtimes do not satisfy readiness")
    func unavailableSimulatorRuntimesDoNotSatisfyReadiness() {
        let profile = RunnerImageProfile(
            name: "iOS image",
            baseMacOSVersion: "26.0",
            xcodeVersion: "17.0",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            commandLineToolsInstalled: true,
            sdks: [ApplePlatformSDK(platform: .iOS, version: "19.0")],
            simulatorRuntimes: [AppleSimulatorRuntime(platform: .iOS, version: "19.0", isAvailable: false)],
            capabilities: [.iOS],
            preparation: BaseImagePreparation(
                inventory: ToolchainInventory(xcodeLicenseAccepted: true)
            )
        )

        #expect(!profile.isReady)
        #expect(profile.readinessIssues.contains { $0.message.contains("iOS simulator runtime") })
    }
}
