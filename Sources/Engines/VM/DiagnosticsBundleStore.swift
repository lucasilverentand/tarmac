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

            copyAppleDistributionDiagnostics(
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

    private func copyAppleDistributionDiagnostics(
        from sharedDirectory: URL,
        to bundleURL: URL,
        retainedFiles: inout [String],
        omittedFiles: inout [String]
    ) {
        let sourceRoot = sharedDirectory.appendingPathComponent("apple-distribution-diagnostics", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return
        }

        let destinationRoot = bundleURL.appendingPathComponent("apple-distribution-diagnostics", isDirectory: true)
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let sourcePath = sourceRoot.standardizedFileURL.path

        while let fileURL = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else {
                continue
            }

            let filePath = fileURL.standardizedFileURL.path
            guard filePath.hasPrefix(sourcePath + "/") else { continue }
            let relativePath = String(filePath.dropFirst(sourcePath.count + 1))
            let bundleRelativePath = "apple-distribution-diagnostics/\(relativePath)"

            if Self.shouldOmitAppleDistributionDiagnostic(fileURL) {
                omittedFiles.append(bundleRelativePath)
                continue
            }

            do {
                let destination = destinationRoot.appendingPathComponent(relativePath)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )

                if let contents = try String(data: Data(contentsOf: fileURL), encoding: .utf8) {
                    try Self.redactAppleCredentialValues(in: contents)
                        .write(to: destination, atomically: true, encoding: .utf8)
                } else {
                    try FileManager.default.copyItem(at: fileURL, to: destination)
                }
                retainedFiles.append(bundleRelativePath)
            } catch {
                Log.vm.warning(
                    "Could not copy Apple distribution diagnostic \(relativePath): \(error.localizedDescription)"
                )
            }
        }
    }

    private static func shouldOmitAppleDistributionDiagnostic(_ url: URL) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        let sensitiveSuffixes = [
            ".p12",
            ".pem",
            ".p8",
            ".mobileprovision",
            ".provisionprofile",
            ".keychain",
            ".keychain-db",
            ".cer",
            ".crt",
            ".certsigningrequest",
        ]
        return sensitiveSuffixes.contains { filename.hasSuffix($0) }
    }

    private static func redactAppleCredentialValues(in contents: String) -> String {
        let keys = [
            "apple[_-]?id",
            "asc[_-]?issuer[_-]?id",
            "asc[_-]?key[_-]?id",
            "notarytool[_-]?password",
            "app[_-]?specific[_-]?password",
            "api[_-]?key",
            "private[_-]?key",
            "password",
            "token",
        ]
        let pattern = #"(?i)(["']?(?:\#(keys.joined(separator: "|")))["']?\s*[:=]\s*)["']?[^"',\n]+["']?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return contents }
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return regex.stringByReplacingMatches(
            in: contents,
            range: range,
            withTemplate: "$1\"<redacted>\""
        )
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
