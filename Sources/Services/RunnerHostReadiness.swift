import Foundation

enum RunnerHostReadinessCategory: String, Sendable {
    case host
    case storage
    case vm
    case github

    var displayName: String {
        switch self {
        case .host: "Host"
        case .storage: "Storage"
        case .vm: "Virtual Machine"
        case .github: "GitHub"
        }
    }
}

struct RunnerHostReadinessIssue: Equatable, Identifiable, Sendable {
    let category: RunnerHostReadinessCategory
    let message: String

    var id: String { "\(category.rawValue):\(message)" }
}

struct RunnerHostReadiness: Equatable, Sendable {
    var issues: [RunnerHostReadinessIssue]

    static let unchecked = RunnerHostReadiness(
        issues: [
            RunnerHostReadinessIssue(
                category: .host,
                message: "Setup checks have not run yet."
            )
        ]
    )

    var isReady: Bool {
        issues.isEmpty
    }

    var nextIssue: RunnerHostReadinessIssue? {
        issues.first
    }

    var statusText: String {
        nextIssue?.message ?? "Ready to accept jobs"
    }

    @MainActor
    static func evaluate(
        configStore: ConfigStore,
        storageHealth providedStorageHealth: StorageHealth? = nil,
        hostCapability: HostCapability = .current()
    ) -> RunnerHostReadiness {
        let storage = StorageManager(rootPath: configStore.storageRootPath)
        let storageHealth = providedStorageHealth ?? storage.evaluateHealth()
        var issues: [RunnerHostReadinessIssue] = []

        issues.append(
            contentsOf: hostCapability.issues.map {
                RunnerHostReadinessIssue(category: .host, message: $0)
            }
        )

        appendStorageIssues(
            to: &issues,
            configStore: configStore,
            storageHealth: storageHealth
        )
        appendVMIssues(
            to: &issues,
            configStore: configStore,
            storage: storage
        )
        appendGitHubIssues(
            to: &issues,
            configStore: configStore
        )

        return RunnerHostReadiness(issues: issues)
    }

    @MainActor
    private static func appendStorageIssues(
        to issues: inout [RunnerHostReadinessIssue],
        configStore: ConfigStore,
        storageHealth: StorageHealth
    ) {
        guard configStore.hasCompletedStorageSetup else {
            issues.append(
                RunnerHostReadinessIssue(
                    category: .storage,
                    message: "Choose a storage location before starting."
                )
            )
            return
        }

        for issue in storageHealth.blockingIssues {
            issues.append(.init(category: .storage, message: issue.message))
        }

        let requiredFreeBytes = requiredFreeBytes(
            for: largestRunnerConfiguration(configStore: configStore),
            cloneBehavior: storageHealth.cloneBehavior
        )
        if let available = storageHealth.volume?.availableCapacityBytes,
            available < requiredFreeBytes
        {
            issues.append(
                .init(
                    category: .storage,
                    message:
                        "Storage volume has \(formatBytes(available)) available; \(formatBytes(requiredFreeBytes)) required to start jobs."
                )
            )
        }
    }

    @MainActor
    private static func appendVMIssues(
        to issues: inout [RunnerHostReadinessIssue],
        configStore: ConfigStore,
        storage: StorageManager
    ) {
        let fm = FileManager.default
        let defaultBaseImagePath = configStore.resolvedBaseImagePath
        let enabledOrganizations = configStore.organizations.filter(\.isEnabled)
        let defaultImageRequired =
            enabledOrganizations.isEmpty
            || enabledOrganizations.contains {
                pathsMatch($0.runnerBaseImagePath(defaultPath: defaultBaseImagePath), defaultBaseImagePath)
            }

        if defaultImageRequired {
            guard fm.fileExists(atPath: defaultBaseImagePath) else {
                issues.append(
                    .init(
                        category: .vm,
                        message: "Create and verify a base image before starting."
                    )
                )
                return
            }

            if !storage.isBaseImageVerified() {
                issues.append(
                    .init(
                        category: .vm,
                        message: "Verify the base image before starting."
                    )
                )
            }
        }

        for org in enabledOrganizations {
            let imagePath = org.runnerBaseImagePath(defaultPath: defaultBaseImagePath)
            guard !pathsMatch(imagePath, defaultBaseImagePath), !fm.fileExists(atPath: imagePath) else {
                continue
            }
            issues.append(
                .init(
                    category: .vm,
                    message: "\(org.name): Runner image does not exist at \(imagePath)."
                )
            )
        }

        let platformStore = PlatformDataStore(storage: storage)
        if !platformStore.hasExistingPlatform {
            issues.append(
                .init(
                    category: .vm,
                    message: "Create VM platform data by setting up the base image."
                )
            )
        }
    }

    private static func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path
            == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    @MainActor
    private static func appendGitHubIssues(
        to issues: inout [RunnerHostReadinessIssue],
        configStore: ConfigStore
    ) {
        if configStore.organizations.isEmpty {
            issues.append(.init(category: .github, message: "Add a GitHub organization."))
            return
        }

        let enabled = configStore.organizations.filter(\.isEnabled)
        if enabled.isEmpty {
            issues.append(.init(category: .github, message: "Enable at least one GitHub organization."))
            return
        }

        for org in enabled {
            if org.requiresGitHubAppCredentials && org.appId.isEmpty {
                issues.append(.init(category: .github, message: "\(org.name): GitHub App ID is not configured."))
            }
            if org.scaleSetId == nil {
                issues.append(.init(category: .github, message: "\(org.name): Scale set ID is not configured."))
            }
            for profileIssue in org.imageProfileReadinessIssues {
                issues.append(.init(category: .github, message: "\(org.name): \(profileIssue.message)"))
            }
            if org.requiresGitHubAppCredentials && !configStore.hasPrivateKey(for: org) {
                issues.append(.init(category: .github, message: "\(org.name): Private key is not imported."))
            }
            if org.requiresEnterpriseAccessToken && !configStore.hasAccessToken(for: org) {
                issues.append(
                    .init(
                        category: .github,
                        message: "\(org.name): Enterprise access token is not configured."
                    )
                )
            }
        }
    }

    private static func requiredFreeBytes(
        for config: VMConfiguration,
        cloneBehavior: StorageCloneBehavior
    ) -> Int64 {
        let gib: Int64 = 1024 * 1024 * 1024
        if cloneBehavior.isFastPath {
            return max(10 * gib, Int64(config.diskSizeGB) * gib / 10)
        }
        return Int64(config.diskSizeGB) * gib
    }

    @MainActor
    private static func largestRunnerConfiguration(configStore: ConfigStore) -> VMConfiguration {
        configStore.organizations
            .filter(\.isEnabled)
            .map { $0.runnerVMConfiguration(defaultConfiguration: configStore.vmConfiguration) }
            .max { lhs, rhs in lhs.diskSizeGB < rhs.diskSizeGB }
            ?? configStore.vmConfiguration
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }
}
