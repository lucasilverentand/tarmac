import Foundation

struct DiagnosticsBundleStore: Sendable {
    let storage: StorageManager
    var retention: DiagnosticsRetentionConfiguration

    var bundleRoot: URL {
        storage.diagnosticsDirectory.appendingPathComponent("jobs", isDirectory: true)
    }

    func hostLifecycleLogURL(in sharedDirectory: URL) -> URL {
        sharedDirectory.appendingPathComponent("host-lifecycle.log")
    }

    func appendHostLifecycleEvent(_ message: String, to sharedDirectory: URL, at date: Date = Date()) {
        do {
            try FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
            let line = "\(Self.iso8601String(from: date)) \(message)\n"
            let url = hostLifecycleLogURL(in: sharedDirectory)
            let data = Data(line.utf8)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            Log.vm.warning("Could not append host lifecycle diagnostic: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func createBundle(
        context: JobDiagnosticsContext,
        sharedDirectory: URL?,
        outcome: JobDiagnosticsOutcome,
        createdAt: Date = Date()
    ) throws -> DiagnosticsBundle {
        try storage.prepareBaseDirectories()
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)

        let bundleId = UUID()
        let bundleURL = bundleRoot.appendingPathComponent(
            "job-\(context.jobId)-\(Self.bundleTimestamp(from: createdAt))-\(bundleId.uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        var retainedFiles: [String] = []
        var omittedFiles: [String] = []
        let shouldKeepFullLogs = outcome.shouldKeepFullLogs || retention.keepSuccessfulJobLogs

        if let sharedDirectory {
            copyIfPresent(
                hostLifecycleLogURL(in: sharedDirectory),
                to: bundleURL.appendingPathComponent("host-lifecycle.log"),
                retainedFiles: &retainedFiles
            )
            copyIfPresent(
                sharedDirectory.appendingPathComponent(GuestBootstrapContract.bootstrapLogFileName),
                to: bundleURL.appendingPathComponent(GuestBootstrapContract.bootstrapLogFileName),
                retainedFiles: &retainedFiles
            )
            copyIfPresent(
                sharedDirectory.appendingPathComponent(GuestBootstrapContract.exitCodeFileName),
                to: bundleURL.appendingPathComponent(GuestBootstrapContract.exitCodeFileName),
                retainedFiles: &retainedFiles
            )
            copyIfPresent(
                sharedDirectory.appendingPathComponent(GuestBootstrapContract.completionMarkerFileName),
                to: bundleURL.appendingPathComponent(GuestBootstrapContract.completionMarkerFileName),
                retainedFiles: &retainedFiles
            )

            let runnerLog = sharedDirectory.appendingPathComponent(GuestBootstrapContract.runnerLogFileName)
            if shouldKeepFullLogs {
                copyIfPresent(
                    runnerLog,
                    to: bundleURL.appendingPathComponent(GuestBootstrapContract.runnerLogFileName),
                    retainedFiles: &retainedFiles
                )
            } else if FileManager.default.fileExists(atPath: runnerLog.path) {
                omittedFiles.append(GuestBootstrapContract.runnerLogFileName)
            }

            captureAppleBuildArtifacts(
                from: sharedDirectory,
                to: bundleURL,
                retainedFiles: &retainedFiles,
                omittedFiles: &omittedFiles
            )
        }

        let metadata = JobDiagnosticsMetadata(
            bundleId: bundleId,
            jobId: context.jobId,
            runnerRequestId: context.runnerRequestId,
            organizationName: context.organizationName,
            repositoryName: context.repositoryName,
            workflowName: context.workflowName,
            runnerName: context.runnerName,
            vmInstanceId: context.vmInstanceId,
            diskImagePath: context.diskImagePath?.path,
            sharedDirectoryPath: sharedDirectory?.path,
            queuedAt: context.queuedAt,
            startedAt: context.startedAt,
            completedAt: context.completedAt,
            bundleCreatedAt: createdAt,
            outcome: outcome.status,
            failureReason: outcome.failureReason,
            retainedFiles: (retainedFiles + ["metadata.json"]).sorted(),
            omittedFiles: omittedFiles.sorted()
        )
        try writeMetadata(metadata, to: bundleURL.appendingPathComponent("metadata.json"))
        retainedFiles.append("metadata.json")
        try FileManager.default.setAttributes([.modificationDate: createdAt], ofItemAtPath: bundleURL.path)

        try enforceRetention(now: createdAt)

        Log.vm.info("Preserved diagnostics for job \(context.jobId) at \(bundleURL.path)")
        return DiagnosticsBundle(
            id: bundleId,
            jobId: context.jobId,
            url: bundleURL,
            createdAt: createdAt,
            retainedFiles: retainedFiles.sorted()
        )
    }

    func enforceRetention(now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: bundleRoot.path) else { return }

        if retention.maxAgeDays > 0 {
            let cutoff = now.addingTimeInterval(-Double(retention.maxAgeDays) * 86_400)
            for bundle in try listBundleDirectories() where bundle.createdAt < cutoff {
                try FileManager.default.removeItem(at: bundle.url)
            }
        }

        if retention.maxBundleCount >= 0 {
            let bundles = try listBundleDirectories().sorted { $0.createdAt < $1.createdAt }
            let excessCount = bundles.count - retention.maxBundleCount
            if excessCount > 0 {
                for bundle in bundles.prefix(excessCount) {
                    try FileManager.default.removeItem(at: bundle.url)
                }
            }
        }

        var bundles = try listBundleDirectories().sorted { $0.createdAt < $1.createdAt }
        var totalSize = bundles.reduce(Int64(0)) { $0 + $1.sizeBytes }
        while totalSize > retention.maxSizeBytes, let oldest = bundles.first {
            try FileManager.default.removeItem(at: oldest.url)
            totalSize -= oldest.sizeBytes
            bundles.removeFirst()
        }
    }

    private func copyIfPresent(_ source: URL, to destination: URL, retainedFiles: inout [String]) {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            retainedFiles.append(destination.lastPathComponent)
        } catch {
            Log.vm.warning("Could not copy diagnostic file \(source.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func captureAppleBuildArtifacts(
        from sharedDirectory: URL,
        to bundleURL: URL,
        retainedFiles: inout [String],
        omittedFiles: inout [String]
    ) {
        let destinationRoot = bundleURL.appendingPathComponent("apple-artifacts", isDirectory: true)
        var remainingBytes = retention.appleArtifactBudgetBytes

        guard
            let enumerator = FileManager.default.enumerator(
                at: sharedDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }

        while let artifactURL = enumerator.nextObject() as? URL {
            guard let relativePath = relativePath(for: artifactURL, under: sharedDirectory) else {
                continue
            }

            let isDirectory = (try? artifactURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if shouldSkipDiagnosticsTraversal(relativePath: relativePath) {
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            if isSensitiveAppleBuildArtifact(artifactURL) {
                omittedFiles.append("apple-artifacts/\(relativePath) (excluded: signing material)")
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            if isGitHubActionsArtifact(artifactURL) {
                omittedFiles.append("apple-artifacts/\(relativePath) (left for GitHub Actions artifacts)")
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard isAppleBuildDiagnosticArtifact(artifactURL, isDirectory: isDirectory) else {
                continue
            }

            let artifactSize = (try? Self.itemSize(at: artifactURL)) ?? 0
            guard artifactSize <= remainingBytes else {
                omittedFiles.append("apple-artifacts/\(relativePath) (exceeds diagnostics artifact budget)")
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            let destination = destinationRoot.appendingPathComponent(relativePath)
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(at: artifactURL, to: destination)
                retainedFiles.append("apple-artifacts/\(relativePath)")
                remainingBytes -= artifactSize
            } catch {
                omittedFiles.append("apple-artifacts/\(relativePath) (copy failed)")
                Log.vm.warning("Could not copy Apple build artifact \(relativePath): \(error.localizedDescription)")
            }

            if isDirectory {
                enumerator.skipDescendants()
            }
        }
    }

    private func writeMetadata(_ metadata: JobDiagnosticsMetadata, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    private func listBundleDirectories() throws -> [RetainedDiagnosticsDirectory] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: bundleRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        )

        return try contents.compactMap { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                return nil
            }

            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            return RetainedDiagnosticsDirectory(
                url: url,
                createdAt: values.contentModificationDate ?? .distantPast,
                sizeBytes: try Self.itemSize(at: url)
            )
        }
    }

    private static func itemSize(at url: URL) throws -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }

        if !isDirectory.boolValue {
            let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            return Int64(values.totalFileAllocatedSize ?? 0)
        }

        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        )

        var total: Int64 = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            let values = try fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private static func bundleTimestamp(from date: Date) -> String {
        iso8601String(from: date)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

extension DiagnosticsRetentionConfiguration {
    var appleArtifactBudgetBytes: Int64 {
        min(maxSizeBytes, 256 * 1024 * 1024)
    }
}

private func relativePath(for url: URL, under root: URL) -> String? {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return nil }
    let relative = String(path.dropFirst(rootPath.count + 1))
    guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else { return nil }
    return relative
}

private func shouldSkipDiagnosticsTraversal(relativePath: String) -> Bool {
    let topLevel = relativePath.split(separator: "/", maxSplits: 1).first.map(String.init) ?? relativePath
    return [
        GuestBootstrapContract.runnerDirectoryName,
        GuestBootstrapContract.bootstrapLogFileName,
        GuestBootstrapContract.runnerLogFileName,
        GuestBootstrapContract.exitCodeFileName,
        GuestBootstrapContract.completionMarkerFileName,
        "host-lifecycle.log",
    ].contains(topLevel)
}

private func isAppleBuildDiagnosticArtifact(_ url: URL, isDirectory: Bool) -> Bool {
    let name = url.lastPathComponent.lowercased()
    let ext = url.pathExtension.lowercased()

    if ext == "xcresult" {
        return true
    }

    if !isDirectory && ext == "xcactivitylog" {
        return true
    }

    guard !isDirectory, ["log", "txt", "json"].contains(ext) else {
        return false
    }

    return [
        "xcodebuild",
        "xcresult",
        "resultbundle",
        "notary",
        "notarization",
        "altool",
        "export",
        "archive",
        "package",
        "packaging",
    ].contains { name.contains($0) }
}

private func isGitHubActionsArtifact(_ url: URL) -> Bool {
    [
        "app",
        "dmg",
        "dsym",
        "ipa",
        "pkg",
        "xcarchive",
    ].contains(url.pathExtension.lowercased())
}

private func isSensitiveAppleBuildArtifact(_ url: URL) -> Bool {
    let name = url.lastPathComponent.lowercased()
    let ext = url.pathExtension.lowercased()

    if [
        "cer",
        "cert",
        "keychain",
        "mobileprovision",
        "p12",
        "pem",
        "provisionprofile",
    ].contains(ext) {
        return true
    }

    return [
        ".keychain",
        ".keychain-db",
        "mobileprovision",
        "provisioningprofile",
        "provisioning_profile",
        "temporary-keychain",
        "temporary.keychain",
    ].contains { name.contains($0) }
}

struct JobDiagnosticsContext: Sendable {
    var jobId: Int64
    var runnerRequestId: Int64?
    var organizationName: String?
    var repositoryName: String?
    var workflowName: String?
    var runnerName: String?
    var vmInstanceId: UUID?
    var diskImagePath: URL?
    var queuedAt: Date?
    var startedAt: Date?
    var completedAt: Date?

    init(jobId: Int64) {
        self.jobId = jobId
    }

    init(job: RunnerJob, runnerName: String? = nil) {
        self.jobId = job.id
        self.runnerRequestId = job.runnerRequestId
        self.organizationName = job.organizationName
        self.repositoryName = job.repositoryName
        self.workflowName = job.workflowName
        self.runnerName = runnerName ?? job.runnerName
        self.vmInstanceId = job.vmInstanceId
        self.queuedAt = job.queuedAt
        self.startedAt = job.startedAt
        self.completedAt = job.completedAt
    }
}

enum JobDiagnosticsOutcome: Equatable, Sendable {
    case succeeded
    case failed(reason: String)
    case unknown(reason: String? = nil)

    var status: String {
        switch self {
        case .succeeded: "succeeded"
        case .failed: "failed"
        case .unknown: "unknown"
        }
    }

    var failureReason: String? {
        switch self {
        case .succeeded:
            nil
        case .failed(let reason):
            reason
        case .unknown(let reason):
            reason
        }
    }

    var shouldKeepFullLogs: Bool {
        switch self {
        case .succeeded:
            false
        case .failed, .unknown:
            true
        }
    }
}

struct DiagnosticsBundle: Sendable {
    let id: UUID
    let jobId: Int64
    let url: URL
    let createdAt: Date
    let retainedFiles: [String]
}

private struct JobDiagnosticsMetadata: Codable, Sendable {
    let bundleId: UUID
    let jobId: Int64
    let runnerRequestId: Int64?
    let organizationName: String?
    let repositoryName: String?
    let workflowName: String?
    let runnerName: String?
    let vmInstanceId: UUID?
    let diskImagePath: String?
    let sharedDirectoryPath: String?
    let queuedAt: Date?
    let startedAt: Date?
    let completedAt: Date?
    let bundleCreatedAt: Date
    let outcome: String
    let failureReason: String?
    let retainedFiles: [String]
    let omittedFiles: [String]
}

private struct RetainedDiagnosticsDirectory: Sendable {
    let url: URL
    let createdAt: Date
    let sizeBytes: Int64
}
