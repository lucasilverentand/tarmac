import CryptoKit
import Foundation

protocol RunnerArchiveDownloading: Sendable {
    func download(from url: URL) async throws -> URL
}

struct URLSessionRunnerArchiveDownloader: RunnerArchiveDownloading {
    func download(from url: URL) async throws -> URL {
        let (fileURL, _) = try await URLSession.shared.download(from: url)
        return fileURL
    }
}

actor RunnerProvider {
    private let client: any GitHubClientProtocol
    private let storage: StorageManager
    private let downloader: any RunnerArchiveDownloading
    private var cachedRunnerPath: URL?

    init(
        client: any GitHubClientProtocol,
        cacheDirectory: URL,
        downloader: any RunnerArchiveDownloading = URLSessionRunnerArchiveDownloader()
    ) {
        self.init(client: client, storage: StorageManager(rootDirectory: cacheDirectory), downloader: downloader)
    }

    init(
        client: any GitHubClientProtocol,
        storage: StorageManager,
        downloader: any RunnerArchiveDownloading = URLSessionRunnerArchiveDownloader()
    ) {
        self.client = client
        self.storage = storage
        self.downloader = downloader
    }

    func ensureRunner(token: String, accountPath: String) async throws -> URL {
        if let cached = cachedRunnerPath,
            FileManager.default.fileExists(atPath: cached.appendingPathComponent("run.sh").path)
        {
            Log.runner.debug("Using cached runner at \(cached.path)")
            return cached
        }

        let runnerDir = storage.runnerDirectory
        if FileManager.default.fileExists(atPath: runnerDir.appendingPathComponent("run.sh").path) {
            cachedRunnerPath = runnerDir
            Log.runner.debug("Using persisted runner at \(runnerDir.path)")
            return runnerDir
        }

        let downloads: [RunnerDownloadInfo] = try await client.request(
            method: "GET",
            path: "\(accountPath)/actions/runners/downloads",
            body: nil as String?,
            headers: ["Authorization": "Bearer \(token)"],
            timeoutInterval: 30
        )

        guard let macOSARM = downloads.first(where: { $0.os == "osx" && $0.architecture == "arm64" }) else {
            throw RunnerProviderError.noCompatibleRunner
        }

        try? FileManager.default.removeItem(at: runnerDir)
        try FileManager.default.createDirectory(at: runnerDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage.tmpDirectory, withIntermediateDirectories: true)

        Log.runner.info("Downloading runner from \(macOSARM.downloadUrl)")
        let tarURL = try await downloader.download(from: URL(string: macOSARM.downloadUrl)!)

        let tarDest = storage.tmpDirectory.appendingPathComponent(macOSARM.filename)
        try? FileManager.default.removeItem(at: tarDest)
        try FileManager.default.moveItem(at: tarURL, to: tarDest)
        try validateChecksum(for: tarDest, expected: macOSARM.sha256Checksum)

        // Extract
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", tarDest.path, "-C", runnerDir.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw RunnerProviderError.extractionFailed
        }

        try? FileManager.default.removeItem(at: tarDest)

        cachedRunnerPath = runnerDir
        Log.runner.info("Runner extracted to \(runnerDir.path)")
        return runnerDir
    }

    private func validateChecksum(for fileURL: URL, expected: String?) throws {
        guard let expected = expected?.trimmingCharacters(in: .whitespacesAndNewlines),
            !expected.isEmpty
        else {
            return
        }

        let data = try Data(contentsOf: fileURL)
        let actual = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()

        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            try? FileManager.default.removeItem(at: fileURL)
            throw RunnerProviderError.checksumMismatch(expected: expected.lowercased(), actual: actual)
        }
    }

    func generateJITConfig(
        token: String,
        accountPath: String,
        name: String,
        labels: [String],
        runnerGroupId: Int? = nil
    ) async throws -> String {
        struct JITRequest: Encodable, Sendable {
            let name: String
            let runner_group_id: Int
            let labels: [String]
            let work_folder: String
        }

        struct JITResponse: Decodable, Sendable {
            let encoded_jit_config: String
        }

        let request = JITRequest(
            name: name,
            // Prefer the scale set's runner group (discovered at session creation);
            // fall back to the default group 1 when GitHub did not report one.
            runner_group_id: runnerGroupId ?? 1,
            labels: labels,
            work_folder: "_work"
        )

        let response: JITResponse = try await client.request(
            method: "POST",
            path: "\(accountPath)/actions/runners/generate-jitconfig",
            body: request,
            headers: ["Authorization": "Bearer \(token)"],
            timeoutInterval: 30
        )

        return response.encoded_jit_config
    }

    func generateRegistrationToken(token: String, accountPath: String) async throws -> String {
        struct RegistrationTokenResponse: Decodable, Sendable {
            let token: String
        }

        let response: RegistrationTokenResponse = try await client.request(
            method: "POST",
            path: "\(accountPath)/actions/runners/registration-token",
            body: nil as String?,
            headers: ["Authorization": "Bearer \(token)"],
            timeoutInterval: 30
        )

        return response.token
    }
}

enum RunnerProviderError: Error, Equatable, LocalizedError, Sendable {
    case noCompatibleRunner
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .noCompatibleRunner: "No compatible macOS ARM64 runner found"
        case let .checksumMismatch(expected, actual):
            "Runner archive checksum mismatch (expected \(expected), got \(actual))"
        case .extractionFailed: "Failed to extract runner archive"
        }
    }
}
