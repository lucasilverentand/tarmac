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

    @Test("Expo iOS readiness requires React Native tools and Expo CLIs")
    func expoReadinessRequiresReactNativeToolsAndExpoCLIs() {
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
                    rubyVersion: "3.3",
                    cocoaPodsVersion: "1.16",
                    expoCLIVersion: "0.24"
                )
            )
        )

        #expect(!profile.isReady)
        #expect(profile.advertisedLabels.isEmpty)
        #expect(profile.readinessIssues.contains { $0.message.contains("JavaScript package manager") })
        #expect(profile.readinessIssues.contains { $0.message.contains("EAS CLI") })
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
        #expect(inventory.expoCLIVersion == "")
        #expect(inventory.easCLIVersion == "")
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
            baseImagePath: "/Images/Xcode17.img",
            vmConfiguration: VMConfiguration(cpuCount: 8, memorySizeGB: 16, diskSizeGB: 120),
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
        #expect(org.runnerBaseImagePath(defaultPath: "/Images/Default.img") == "/Images/Xcode17.img")
        #expect(org.runnerVMConfiguration(defaultConfiguration: VMConfiguration()).cpuCount == 8)
    }

    @Test("inventory report parser creates automatic advertised profile")
    func inventoryReportCreatesAutomaticProfile() {
        let report = RunnerImageInventoryReport.parse(
            """
            captured_at\t2026-05-19T10:15:30Z
            macos_version\t26.0
            developer_directory\t/Applications/Xcode.app/Contents/Developer
            xcode_version\t17.0
            xcode_license_accepted\ttrue
            command_line_tools_installed\ttrue
            command_line_tools_version\t17.0.0.0.1
            sdk\tmacos\t26.0
            sdk\tios\t19.0
            runtime\tios\t19.0\ttrue
            tool\tnode\tv24.0.0
            tool\truby\truby 3.3.0
            tool\tcocoapods\t1.16.0
            package_manager\tnpm\t10.8.0
            """
        )

        let profile = RunnerImageProfile.automatic(
            from: report,
            baseImagePath: "/Images/Xcode17.img",
            vmConfiguration: VMConfiguration(cpuCount: 6, memorySizeGB: 12, diskSizeGB: 100),
            name: "Scanned"
        )

        #expect(report.capturedAt != nil)
        #expect(profile.name == "Scanned")
        #expect(profile.baseImagePath == "/Images/Xcode17.img")
        #expect(profile.vmConfiguration?.cpuCount == 6)
        #expect(profile.preparation?.baseImageIdentifier == "Xcode17.img")
        #expect(profile.capabilities == [.xcode, .iOS, .spm, .reactNativeIOS])
        #expect(profile.advertisedLabels == ["xcode", "ios", "spm", "react-native-ios"])
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
        #expect(
            AppleBuildCapability.expoIOS.unsignedValidationWorkflow
                == AppleBuildValidationWorkflow(
                    runnerLabel: "expo-ios",
                    sdk: nil,
                    destination: nil,
                    command: "eas build --platform ios --local --profile simulator --non-interactive",
                    buildSettings: ["EXPO_NO_TELEMETRY=1"],
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

    @Test("approved Apple release matrix preserves the existing macOS 27 image")
    func approvedAppleReleaseMatrixPreservesBetaImage() {
        let account = Organization(
            name: "example",
            appId: "1",
            installationId: 1,
            scaleSetId: 42,
            scaleSetName: "existing"
        )

        let pools = RunnerPoolConfiguration.approvedAppleReleaseMatrix(
            account: account,
            storageRootPath: "/Tarmac",
            defaultBaseImagePath: "/Tarmac/BaseImage.img",
            defaultVMConfiguration: VMConfiguration()
        )

        let stable = pools.first { $0.releaseChannel == .appStore }
        let beta = pools.first { $0.releaseChannel == .beta }
        #expect(stable?.isEnabled == false)
        #expect(stable?.imageProfile.xcodeVersion == "26.6")
        #expect(stable?.routingLabels.contains("tarmac-app-store") == true)
        #expect(beta?.isEnabled == true)
        #expect(beta?.scaleSetId == 42)
        #expect(beta?.resolvedBaseImagePath(defaultPath: "") == "/Tarmac/BaseImage.img")
        #expect(beta?.matches(requestedLabels: ["self-hosted", "tarmac-beta"]) == true)
        #expect(beta?.matches(requestedLabels: ["self-hosted", "macOS"]) == false)
    }
}
