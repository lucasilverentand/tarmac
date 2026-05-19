import Foundation
import Testing

@testable import Tarmac

@Suite("Model Codable")
struct ModelCodableTests {
    // MARK: - RunnerJob

    @Test("RunnerJob round-trip with all fields")
    func runnerJobFullRoundTrip() throws {
        let queuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var lease = RunnerLease(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            job: RunnerJob(
                id: 42,
                organizationName: "my-org",
                runnerRequestId: 1001,
                status: .running,
                workflowName: "CI Pipeline",
                repositoryName: "my-repo",
                queuedAt: queuedAt
            ),
            runnerName: "ephemeral-42",
            labels: ["self-hosted", "macOS"],
            createdAt: queuedAt
        )
        lease.recordVMStarted(
            vmInstanceId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            diskImagePath: "/tmp/tarmac/disks/job-42.img",
            sharedDirectoryPath: "/tmp/tarmac/jobs/42",
            now: Date(timeIntervalSince1970: 1_700_000_030)
        )

        let job = RunnerJob(
            id: 42,
            organizationName: "my-org",
            runnerRequestId: 1001,
            status: .running,
            workflowName: "CI Pipeline",
            repositoryName: "my-repo",
            jitConfig: "encoded-config-data",
            runnerName: "ephemeral-42",
            runnerLease: lease,
            vmInstanceId: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            diagnosticsBundlePath: "/tmp/diagnostics/job-42",
            queuedAt: queuedAt,
            startedAt: Date(timeIntervalSince1970: 1_700_000_060),
            completedAt: nil,
            failureReason: nil
        )

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(RunnerJob.self, from: data)

        #expect(decoded.id == 42)
        #expect(decoded.organizationName == "my-org")
        #expect(decoded.status == .running)
        #expect(decoded.runnerRequestId == 1001)
        #expect(decoded.workflowName == "CI Pipeline")
        #expect(decoded.repositoryName == "my-repo")
        #expect(decoded.jitConfig == "encoded-config-data")
        #expect(decoded.runnerName == "ephemeral-42")
        #expect(decoded.runnerLease?.runnerName == "ephemeral-42")
        #expect(decoded.runnerLease?.runner.labels == ["self-hosted", "macOS"])
        #expect(decoded.runnerLease?.executionAttempt?.sharedDirectoryPath == "/tmp/tarmac/jobs/42")
        #expect(decoded.vmInstanceId?.uuidString == "11111111-1111-1111-1111-111111111111")
        #expect(decoded.diagnosticsBundlePath == "/tmp/diagnostics/job-42")
        #expect(decoded.startedAt != nil)
        #expect(decoded.completedAt == nil)
        #expect(decoded.failureReason == nil)
    }

    @Test("RunnerJob round-trip with nil optionals")
    func runnerJobNilOptionals() throws {
        let job = RunnerJob(
            id: 1,
            organizationName: "org",
            status: .pending,
            queuedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(RunnerJob.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.workflowName == nil)
        #expect(decoded.repositoryName == nil)
        #expect(decoded.jitConfig == nil)
        #expect(decoded.runnerRequestId == nil)
        #expect(decoded.runnerName == nil)
        #expect(decoded.runnerLease == nil)
        #expect(decoded.vmInstanceId == nil)
        #expect(decoded.diagnosticsBundlePath == nil)
        #expect(decoded.startedAt == nil)
        #expect(decoded.completedAt == nil)
    }

    @Test("RunnerLease round-trip preserves cleanup context")
    func runnerLeaseRoundTrip() throws {
        var job = RunnerJob(
            id: 88,
            organizationName: "org",
            runnerRequestId: 44,
            status: .running,
            workflowName: "Release",
            repositoryName: "repo",
            queuedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        job.runnerName = "ephemeral-88"
        var lease = RunnerLease(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            job: job,
            runnerName: "ephemeral-88",
            labels: ["self-hosted", "macOS"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_010)
        )
        lease.recordVMStarted(
            vmInstanceId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            diskImagePath: "/tmp/disks/88.img",
            sharedDirectoryPath: "/tmp/jobs/88",
            now: Date(timeIntervalSince1970: 1_700_000_020)
        )
        lease.recordDiagnosticsBundle(path: "/tmp/diagnostics/88", now: Date(timeIntervalSince1970: 1_700_000_030))
        lease.recordCleanupState(.completed, now: Date(timeIntervalSince1970: 1_700_000_040))

        let data = try JSONEncoder().encode(lease)
        let decoded = try JSONDecoder().decode(RunnerLease.self, from: data)

        #expect(decoded.id == lease.id)
        #expect(decoded.request.jobId == 88)
        #expect(decoded.runner.provider == .github)
        #expect(decoded.runner.runnerName == "ephemeral-88")
        #expect(decoded.executionAttempt?.vmInstanceId.uuidString == "44444444-4444-4444-4444-444444444444")
        #expect(decoded.executionAttempt?.completedAt != nil)
        #expect(decoded.logBundle?.path == "/tmp/diagnostics/88")
        #expect(decoded.cleanupState == .completed)
    }

    // MARK: - Organization

    @Test("Organization round-trip preserves all fields")
    func organizationRoundTrip() throws {
        let org = Organization(
            name: "test-org",
            appId: "APP42",
            installationId: 99,
            scaleSetId: 7,
            labels: ["self-hosted", "macOS"],
            imageProfile: RunnerImageProfile(
                name: "Xcode 17",
                baseMacOSVersion: "26.0",
                xcodeVersion: "17.0",
                developerDirectory: "/Applications/Xcode.app/Contents/Developer",
                commandLineToolsInstalled: true,
                sdks: [ApplePlatformSDK(platform: .iOS, version: "19.0")],
                simulatorRuntimes: [AppleSimulatorRuntime(platform: .iOS, version: "19.0")],
                capabilities: [.xcode, .iOS],
                preparation: BaseImagePreparation(
                    baseImageIdentifier: "base-image-2026-05-16",
                    steps: [
                        BaseImagePreparationStep(id: .installXcode, status: .completed),
                        BaseImagePreparationStep(id: .acceptXcodeLicense, status: .completed),
                    ],
                    inventory: ToolchainInventory(
                        commandLineToolsVersion: "17.0",
                        xcodeLicenseAccepted: true,
                        nodeVersion: "24.0",
                        packageManagers: [PackageManagerInventory(manager: .npm, version: "10.8")],
                        rubyVersion: "3.3",
                        cocoaPodsVersion: "1.16"
                    )
                )
            ),
            isEnabled: false,
            filterMode: .include,
            filteredRepositories: ["my-repo", "other-repo"]
        )

        let data = try JSONEncoder().encode(org)
        let decoded = try JSONDecoder().decode(Organization.self, from: data)

        #expect(decoded.name == "test-org")
        #expect(decoded.appId == "APP42")
        #expect(decoded.installationId == 99)
        #expect(decoded.scaleSetId == 7)
        #expect(decoded.labels == ["self-hosted", "macOS"])
        #expect(decoded.imageProfile?.name == "Xcode 17")
        #expect(decoded.imageProfile?.sdks == [ApplePlatformSDK(platform: .iOS, version: "19.0")])
        #expect(decoded.imageProfile?.capabilities == [.xcode, .iOS])
        #expect(decoded.imageProfile?.preparation?.baseImageIdentifier == "base-image-2026-05-16")
        #expect(decoded.imageProfile?.preparation?.completedStepCount == 2)
        #expect(decoded.imageProfile?.preparation?.inventory.xcodeLicenseAccepted == true)
        #expect(decoded.imageProfile?.preparation?.inventory.packageManagers.first?.manager == .npm)
        #expect(decoded.imageProfile?.preparation?.inventory.rubyVersion == "3.3")
        #expect(decoded.isEnabled == false)
        #expect(decoded.filterMode == .include)
        #expect(decoded.filteredRepositories == ["my-repo", "other-repo"])
    }

    @Test("Organization Hashable consistency")
    func organizationHashable() {
        let org = Organization(name: "a", appId: "1", installationId: 1)
        var set = Set<Organization>()
        set.insert(org)
        set.insert(org)  // same instance
        #expect(set.count == 1)
    }

    @Test("Organization acceptsRepository with all mode")
    func orgFilterAll() {
        let org = Organization(name: "a", appId: "1", installationId: 1, filterMode: .all)
        #expect(org.acceptsRepository("any-repo"))
        #expect(org.acceptsRepository(nil))
    }

    @Test("Organization acceptsRepository with include mode")
    func orgFilterInclude() {
        let org = Organization(
            name: "a",
            appId: "1",
            installationId: 1,
            filterMode: .include,
            filteredRepositories: ["allowed-repo"]
        )
        #expect(org.acceptsRepository("allowed-repo"))
        #expect(org.acceptsRepository("Allowed-Repo"))  // case-insensitive
        #expect(!org.acceptsRepository("other-repo"))
        #expect(org.acceptsRepository(nil))  // nil repo always accepted
    }

    @Test("Organization acceptsRepository with exclude mode")
    func orgFilterExclude() {
        let org = Organization(
            name: "a",
            appId: "1",
            installationId: 1,
            filterMode: .exclude,
            filteredRepositories: ["blocked-repo"]
        )
        #expect(!org.acceptsRepository("blocked-repo"))
        #expect(!org.acceptsRepository("Blocked-Repo"))  // case-insensitive
        #expect(org.acceptsRepository("other-repo"))
        #expect(org.acceptsRepository(nil))
    }

    @Test("GitHub setup guidance distinguishes supported setup scopes")
    func githubSetupGuidanceScopes() {
        let guidance = GitHubSetupGuidance.setupOverview

        #expect(guidance.map(\.scope) == [.organization, .repository, .enterprise, .permissions])
        #expect(GitHubSetupGuidance.organization.detail.contains("organization scope"))
        #expect(GitHubSetupGuidance.repository.detail.contains("only decides which queued jobs Tarmac accepts"))
        #expect(GitHubSetupGuidance.enterprise.detail.contains("not supported yet"))
        #expect(GitHubSetupGuidance.permissions.detail.contains("organization self-hosted runner permission"))
    }

    // MARK: - AppleSigningAsset

    @Test("AppleSigningAsset round-trip preserves metadata")
    func appleSigningAssetRoundTrip() throws {
        let asset = AppleSigningAsset(
            id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            displayName: "iOS Distribution",
            teamId: "TEAM12345",
            bundleIdentifierPattern: "com.example.*",
            certificateCommonName: "Apple Distribution",
            provisioningProfileUUID: "profile-uuid",
            certificateExpiresAt: Date(timeIntervalSince1970: 4_102_444_800),
            provisioningProfileExpiresAt: Date(timeIntervalSince1970: 4_102_444_800),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let data = try JSONEncoder().encode(asset)
        let decoded = try JSONDecoder().decode(AppleSigningAsset.self, from: data)

        #expect(decoded == asset)
        #expect(decoded.certificateKeychainKey == "apple-signing-certificate-p12-\(asset.id.uuidString)")
        #expect(decoded.passphraseKeychainKey == "apple-signing-certificate-passphrase-\(asset.id.uuidString)")
        #expect(decoded.provisioningProfileKeychainKey == "apple-signing-provisioning-profile-\(asset.id.uuidString)")
    }

    @Test("AppleSigningAsset bundle matching supports exact, wildcard, and prefix patterns")
    func appleSigningAssetBundleMatching() {
        let exact = AppleSigningAsset(displayName: "Exact", teamId: "TEAM", bundleIdentifierPattern: "com.example.app")
        let wildcard = AppleSigningAsset(displayName: "Wildcard", teamId: "TEAM", bundleIdentifierPattern: "*")
        let prefix = AppleSigningAsset(displayName: "Prefix", teamId: "TEAM", bundleIdentifierPattern: "com.example.*")

        #expect(exact.matches(bundleIdentifier: "com.example.app"))
        #expect(!exact.matches(bundleIdentifier: "com.example.other"))
        #expect(wildcard.matches(bundleIdentifier: "anything"))
        #expect(prefix.matches(bundleIdentifier: "com.example"))
        #expect(prefix.matches(bundleIdentifier: "com.example.watchkitapp"))
        #expect(!prefix.matches(bundleIdentifier: "com.examples.watchkitapp"))
    }

    // MARK: - VMConfiguration

    @Test("VMConfiguration round-trip")
    func vmConfigRoundTrip() throws {
        let config = VMConfiguration(
            cpuCount: 8,
            memorySizeGB: 16,
            diskSizeGB: 120,
            runnerCompletionTimeoutSeconds: 7_200
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(VMConfiguration.self, from: data)

        #expect(decoded.cpuCount == 8)
        #expect(decoded.memorySizeGB == 16)
        #expect(decoded.diskSizeGB == 120)
        #expect(decoded.runnerCompletionTimeoutSeconds == 7_200)
    }

    @Test("VMConfiguration decodes legacy payloads")
    func vmConfigLegacyDecode() throws {
        let data = #"{"cpuCount":8,"memorySizeGB":16,"diskSizeGB":120}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(VMConfiguration.self, from: data)

        #expect(decoded.cpuCount == 8)
        #expect(decoded.memorySizeGB == 16)
        #expect(decoded.diskSizeGB == 120)
        #expect(decoded.runnerCompletionTimeoutSeconds == 3_600)
    }

    @Test("VMConfiguration memorySize computed property")
    func vmConfigMemorySize() {
        let config = VMConfiguration(cpuCount: 4, memorySizeGB: 8, diskSizeGB: 80)
        #expect(config.memorySize == 8 * 1024 * 1024 * 1024)
    }

    // MARK: - CacheConfiguration

    @Test("CacheConfiguration round-trip")
    func cacheConfigRoundTrip() throws {
        let config = CacheConfiguration(isEnabled: false, maxSizeGB: 50, retentionDays: 7)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CacheConfiguration.self, from: data)

        #expect(decoded.isEnabled == false)
        #expect(decoded.maxSizeGB == 50)
        #expect(decoded.retentionDays == 7)
    }

    @Test("CacheConfiguration static properties")
    func cacheConfigStaticProperties() {
        #expect(CacheConfiguration.guestMountTag == "actions-cache")
        #expect(CacheConfiguration.guestMountPoint == "/Volumes/actions-cache")
        #expect(
            CacheConfiguration.guestCacheTargets.map(\.directoryName) == [
                "swiftpm",
                "xcode-derived-data",
                "cocoapods",
                "pub-cache",
                "npm",
                "yarn",
                "pnpm-store",
                "bun-install-cache",
            ]
        )
        #expect(CacheConfiguration.guestCacheTargets.map(\.environmentVariable).contains("PUB_CACHE"))
        #expect(CacheConfiguration.guestCacheTargets.map(\.environmentVariable).contains("NPM_CONFIG_CACHE"))
        #expect(CacheConfiguration.guestCacheTargets.map(\.environmentVariable).contains("YARN_CACHE_FOLDER"))
        #expect(CacheConfiguration.guestCacheTargets.map(\.environmentVariable).contains("PNPM_STORE_PATH"))
        #expect(CacheConfiguration.guestCacheTargets.map(\.environmentVariable).contains("BUN_INSTALL_CACHE_DIR"))
    }

    @Test("DiagnosticsRetentionConfiguration round-trip")
    func diagnosticsRetentionConfigRoundTrip() throws {
        let config = DiagnosticsRetentionConfiguration(
            maxBundleCount: 25,
            maxAgeDays: 5,
            maxSizeMB: 256,
            keepSuccessfulJobLogs: true
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(DiagnosticsRetentionConfiguration.self, from: data)

        #expect(decoded.maxBundleCount == 25)
        #expect(decoded.maxAgeDays == 5)
        #expect(decoded.maxSizeMB == 256)
        #expect(decoded.maxSizeBytes == 256 * 1024 * 1024)
        #expect(decoded.keepSuccessfulJobLogs)
    }

    // MARK: - TokenInfo

    @Test("TokenInfo isExpired and isExpiringSoon edge cases")
    func tokenInfoExpiration() {
        let expired = TokenInfo(token: "t", expiresAt: Date().addingTimeInterval(-1))
        #expect(expired.isExpired)
        #expect(expired.isExpiringSoon)

        let expiringSoon = TokenInfo(token: "t", expiresAt: Date().addingTimeInterval(30))
        #expect(!expiringSoon.isExpired)
        #expect(expiringSoon.isExpiringSoon)  // within 60s

        let fresh = TokenInfo(token: "t", expiresAt: Date().addingTimeInterval(300))
        #expect(!fresh.isExpired)
        #expect(!fresh.isExpiringSoon)
    }

    // MARK: - RunnerDownloadInfo

    @Test("RunnerDownloadInfo snake_case CodingKeys")
    func runnerDownloadInfoCodingKeys() throws {
        let json = """
            {
                "os": "osx",
                "architecture": "arm64",
                "download_url": "https://example.com/runner.tar.gz",
                "filename": "actions-runner-osx-arm64-2.300.0.tar.gz",
                "sha256_checksum": "abc123"
            }
            """.data(using: .utf8)!

        let info = try JSONDecoder().decode(RunnerDownloadInfo.self, from: json)
        #expect(info.os == "osx")
        #expect(info.architecture == "arm64")
        #expect(info.downloadUrl == "https://example.com/runner.tar.gz")
        #expect(info.filename == "actions-runner-osx-arm64-2.300.0.tar.gz")
        #expect(info.sha256Checksum == "abc123")

        // Re-encode and verify round-trip
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(RunnerDownloadInfo.self, from: data)
        #expect(decoded.downloadUrl == info.downloadUrl)
    }

    // MARK: - ScaleSetMessage

    @Test("ScaleSetMessage with nested statistics round-trip")
    func scaleSetMessageRoundTrip() throws {
        let message = ScaleSetMessage(
            messageId: 99,
            messageType: "JobAvailable",
            body: "{\"test\":true}",
            statistics: ScaleSetStatistics(
                totalAvailableJobs: 3,
                totalAssignedJobs: 1,
                totalRunningJobs: 2,
                totalRegisteredRunners: 5
            )
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ScaleSetMessage.self, from: data)

        #expect(decoded.messageId == 99)
        #expect(decoded.messageType == "JobAvailable")
        #expect(decoded.body == "{\"test\":true}")
        #expect(decoded.statistics?.totalAvailableJobs == 3)
        #expect(decoded.statistics?.totalAssignedJobs == 1)
        #expect(decoded.statistics?.totalRunningJobs == 2)
        #expect(decoded.statistics?.totalRegisteredRunners == 5)
    }
}
