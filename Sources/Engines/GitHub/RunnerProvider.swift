import Foundation

actor RunnerProvider {
    private let client: any GitHubClientProtocol
    private let cacheDirectory: URL
    private var cachedRunnerPath: URL?

    init(client: any GitHubClientProtocol, cacheDirectory: URL) {
        self.client = client
        self.cacheDirectory = cacheDirectory
    }

    func ensureRunner(token: String, org: String) async throws -> URL {
        if let cached = cachedRunnerPath,
           FileManager.default.fileExists(atPath: cached.appendingPathComponent("run.sh").path) {
            Log.runner.debug("Using cached runner at \(cached.path)")
            return cached
        }

        let downloads: [RunnerDownloadInfo] = try await client.request(
            method: "GET",
            path: "/orgs/\(org)/actions/runners/downloads",
            body: nil as String?,
            headers: ["Authorization": "Bearer \(token)"],
            timeoutInterval: 30
        )

        guard let macOSARM = downloads.first(where: { $0.os == "osx" && $0.architecture == "arm64" }) else {
            throw RunnerProviderError.noCompatibleRunner
        }

        let runnerDir = cacheDirectory.appendingPathComponent("runner")
        try? FileManager.default.removeItem(at: runnerDir)
        try FileManager.default.createDirectory(at: runnerDir, withIntermediateDirectories: true)

        Log.runner.info("Downloading runner from \(macOSARM.downloadUrl)")
        let (tarURL, _) = try await URLSession.shared.download(from: URL(string: macOSARM.downloadUrl)!)

        let tarDest = cacheDirectory.appendingPathComponent(macOSARM.filename)
        try? FileManager.default.removeItem(at: tarDest)
        try FileManager.default.moveItem(at: tarURL, to: tarDest)

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

    func generateJITConfig(token: String, org: String, name: String, labels: [String]) async throws -> String {
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
            runner_group_id: 1, // Default group
            labels: labels,
            work_folder: "_work"
        )

        let response: JITResponse = try await client.request(
            method: "POST",
            path: "/orgs/\(org)/actions/runners/generate-jitconfig",
            body: request,
            headers: ["Authorization": "Bearer \(token)"],
            timeoutInterval: 30
        )

        return response.encoded_jit_config
    }
}

enum RunnerProviderError: Error, LocalizedError, Sendable {
    case noCompatibleRunner
    case extractionFailed

    var errorDescription: String? {
        switch self {
        case .noCompatibleRunner: "No compatible macOS ARM64 runner found"
        case .extractionFailed: "Failed to extract runner archive"
        }
    }
}
