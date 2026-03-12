import Testing
import Foundation
@testable import Tarmac

@Suite("Model Codable")
struct ModelCodableTests {
    // MARK: - RunnerJob

    @Test("RunnerJob round-trip with all fields")
    func runnerJobFullRoundTrip() throws {
        let job = RunnerJob(
            id: 42,
            organizationName: "my-org",
            status: .running,
            workflowName: "CI Pipeline",
            repositoryName: "my-repo",
            jitConfig: "encoded-config-data",
            queuedAt: Date(timeIntervalSince1970: 1700000000),
            startedAt: Date(timeIntervalSince1970: 1700000060),
            completedAt: nil,
            failureReason: nil
        )

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(RunnerJob.self, from: data)

        #expect(decoded.id == 42)
        #expect(decoded.organizationName == "my-org")
        #expect(decoded.status == .running)
        #expect(decoded.workflowName == "CI Pipeline")
        #expect(decoded.repositoryName == "my-repo")
        #expect(decoded.jitConfig == "encoded-config-data")
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
            queuedAt: Date(timeIntervalSince1970: 1700000000)
        )

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(RunnerJob.self, from: data)

        #expect(decoded.id == 1)
        #expect(decoded.workflowName == nil)
        #expect(decoded.repositoryName == nil)
        #expect(decoded.jitConfig == nil)
        #expect(decoded.startedAt == nil)
        #expect(decoded.completedAt == nil)
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
        #expect(decoded.isEnabled == false)
        #expect(decoded.filterMode == .include)
        #expect(decoded.filteredRepositories == ["my-repo", "other-repo"])
    }

    @Test("Organization Hashable consistency")
    func organizationHashable() {
        let org = Organization(name: "a", appId: "1", installationId: 1)
        var set = Set<Organization>()
        set.insert(org)
        set.insert(org) // same instance
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
            name: "a", appId: "1", installationId: 1,
            filterMode: .include,
            filteredRepositories: ["allowed-repo"]
        )
        #expect(org.acceptsRepository("allowed-repo"))
        #expect(org.acceptsRepository("Allowed-Repo")) // case-insensitive
        #expect(!org.acceptsRepository("other-repo"))
        #expect(org.acceptsRepository(nil)) // nil repo always accepted
    }

    @Test("Organization acceptsRepository with exclude mode")
    func orgFilterExclude() {
        let org = Organization(
            name: "a", appId: "1", installationId: 1,
            filterMode: .exclude,
            filteredRepositories: ["blocked-repo"]
        )
        #expect(!org.acceptsRepository("blocked-repo"))
        #expect(!org.acceptsRepository("Blocked-Repo")) // case-insensitive
        #expect(org.acceptsRepository("other-repo"))
        #expect(org.acceptsRepository(nil))
    }

    // MARK: - VMConfiguration

    @Test("VMConfiguration round-trip")
    func vmConfigRoundTrip() throws {
        let config = VMConfiguration(cpuCount: 8, memorySizeGB: 16, diskSizeGB: 120)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(VMConfiguration.self, from: data)

        #expect(decoded.cpuCount == 8)
        #expect(decoded.memorySizeGB == 16)
        #expect(decoded.diskSizeGB == 120)
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
    }

    // MARK: - TokenInfo

    @Test("TokenInfo isExpired and isExpiringSoon edge cases")
    func tokenInfoExpiration() {
        let expired = TokenInfo(token: "t", expiresAt: Date().addingTimeInterval(-1))
        #expect(expired.isExpired)
        #expect(expired.isExpiringSoon)

        let expiringSoon = TokenInfo(token: "t", expiresAt: Date().addingTimeInterval(30))
        #expect(!expiringSoon.isExpired)
        #expect(expiringSoon.isExpiringSoon) // within 60s

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
