import Foundation

struct SharedDirectoryManager: Sendable {
    let baseDirectory: URL
    private let storage: StorageManager

    init(cacheDirectoryPath: String) {
        self.init(storage: StorageManager(rootPath: cacheDirectoryPath))
    }

    init(storage: StorageManager) {
        self.storage = storage
        self.baseDirectory = storage.rootDirectory
    }

    func prepareForJob(jobId: Int64, runnerPath: URL, jitConfig: String) throws -> URL {
        let jobDir = jobDirectory(for: jobId)
        let fm = FileManager.default

        try validateRunner(at: runnerPath, fileManager: fm)
        guard !jitConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SharedDirectoryError.emptyJITConfig
        }

        if fm.fileExists(atPath: jobDir.path) {
            try fm.removeItem(at: jobDir)
        }
        try fm.createDirectory(at: jobDir, withIntermediateDirectories: true)

        let runnerDestination = jobDir.appendingPathComponent(GuestBootstrapContract.runnerDirectoryName)
        try fm.copyItem(at: runnerPath, to: runnerDestination)

        let jitConfigPath = jobDir.appendingPathComponent(GuestBootstrapContract.jitConfigFileName)
        try jitConfig.write(to: jitConfigPath, atomically: true, encoding: .utf8)

        try fm.createDirectory(at: storage.actionsCacheDirectory, withIntermediateDirectories: true)

        Log.vm.info("Shared directory prepared for job \(jobId) at \(jobDir.path)")
        return jobDir
    }

    func cleanupJob(jobId: Int64) throws {
        let jobDir = jobDirectory(for: jobId)
        guard FileManager.default.fileExists(atPath: jobDir.path) else { return }
        try FileManager.default.removeItem(at: jobDir)
        Log.vm.info("Cleaned up shared directory for job \(jobId)")
    }

    // MARK: - Paths

    private var jobsDirectory: URL {
        storage.jobsDirectory
    }

    private func jobDirectory(for jobId: Int64) -> URL {
        jobsDirectory.appendingPathComponent("\(jobId)")
    }

    var cacheDirectory: URL {
        storage.actionsCacheDirectory
    }

    private func validateRunner(at runnerPath: URL, fileManager fm: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: runnerPath.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SharedDirectoryError.missingRunnerPackage(runnerPath)
        }

        let runScript = runnerPath.appendingPathComponent(GuestBootstrapContract.runnerEntrypointName)
        guard fm.fileExists(atPath: runScript.path) else {
            throw SharedDirectoryError.missingRunnerEntrypoint(runScript)
        }
        guard fm.isExecutableFile(atPath: runScript.path) else {
            throw SharedDirectoryError.runnerEntrypointNotExecutable(runScript)
        }
    }
}

enum SharedDirectoryError: LocalizedError {
    case missingRunnerPackage(URL)
    case missingRunnerEntrypoint(URL)
    case runnerEntrypointNotExecutable(URL)
    case emptyJITConfig

    var errorDescription: String? {
        switch self {
        case .missingRunnerPackage(let url):
            "Runner package is missing at \(url.path)"
        case .missingRunnerEntrypoint(let url):
            "Runner package is missing \(url.lastPathComponent) at \(url.path)"
        case .runnerEntrypointNotExecutable(let url):
            "Runner entrypoint is not executable at \(url.path)"
        case .emptyJITConfig:
            "JIT configuration is empty"
        }
    }
}
