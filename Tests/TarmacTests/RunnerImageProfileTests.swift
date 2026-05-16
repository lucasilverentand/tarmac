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
            capabilities: [.xcode, .spm, .iOS, .reactNativeIOS]
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
        #expect(profile.readinessIssues.contains { $0.message.contains("iOS SDK") })
        #expect(profile.readinessIssues.contains { $0.message.contains("iOS simulator runtime") })
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
            capabilities: [.xcode, .spm]
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

    @Test("macOS distribution requires packaging tools signing identities and notarization credentials")
    func macOSDistributionReadinessRequiresDistributionInputs() {
        let profile = RunnerImageProfile(
            name: "Release image",
            baseMacOSVersion: "26.0",
            xcodeVersion: "17.0",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            commandLineToolsInstalled: true,
            sdks: [ApplePlatformSDK(platform: .macOS, version: "26.0")],
            capabilities: [.macOSDistribution],
            distribution: AppleDistributionToolchain(
                notarytoolInstalled: true,
                productbuildInstalled: true,
                pkgbuildInstalled: false,
                hdiutilInstalled: true,
                staplerInstalled: false,
                developerIDApplicationIdentity: "",
                developerIDInstallerIdentity: "Developer ID Installer: Example",
                notarizationCredentialsConfigured: false
            )
        )

        #expect(!profile.isReady)
        #expect(profile.advertisedLabels.isEmpty)
        #expect(profile.readinessIssues.contains { $0.message.contains("pkgbuild") })
        #expect(profile.readinessIssues.contains { $0.message.contains("stapler") })
        #expect(profile.readinessIssues.contains { $0.message.contains("Developer ID Application") })
        #expect(profile.readinessIssues.contains { $0.message.contains("Notarization credentials") })
    }

    @Test("ready macOS distribution profile advertises distribution label")
    func readyMacOSDistributionAdvertisesLabel() {
        let profile = RunnerImageProfile(
            name: "Release image",
            baseMacOSVersion: "26.0",
            xcodeVersion: "17.0",
            developerDirectory: "/Applications/Xcode.app/Contents/Developer",
            commandLineToolsInstalled: true,
            sdks: [ApplePlatformSDK(platform: .macOS, version: "26.0")],
            capabilities: [.macOSDistribution],
            distribution: AppleDistributionToolchain(
                notarytoolInstalled: true,
                productbuildInstalled: true,
                pkgbuildInstalled: true,
                hdiutilInstalled: true,
                staplerInstalled: true,
                developerIDApplicationIdentity: "Developer ID Application: Example",
                developerIDInstallerIdentity: "Developer ID Installer: Example",
                notarizationCredentialsConfigured: true
            )
        )

        #expect(profile.isReady)
        #expect(profile.advertisedLabels == ["macos-distribution"])
    }
}
