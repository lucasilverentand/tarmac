import Foundation

struct SharedDirectoryManager: Sendable {
    let baseDirectory: URL

    init(cacheDirectoryPath: String) {
        self.baseDirectory = URL(fileURLWithPath: cacheDirectoryPath)
    }

    func prepareForJob(jobId: Int64, runnerPath: URL, jitConfig: String) throws -> URL {
        let jobDir = jobDirectory(for: jobId)
        let fm = FileManager.default

        try fm.createDirectory(at: jobDir, withIntermediateDirectories: true)

        // Symlink the runner into the job directory
        let runnerLink = jobDir.appendingPathComponent("runner")
        if fm.fileExists(atPath: runnerLink.path) {
            try fm.removeItem(at: runnerLink)
        }
        try fm.createSymbolicLink(at: runnerLink, withDestinationURL: runnerPath)

        // Write the JIT config
        let jitConfigPath = jobDir.appendingPathComponent("jitconfig")
        try jitConfig.write(to: jitConfigPath, atomically: true, encoding: .utf8)

        // Ensure persistent cache directory exists
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

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
        baseDirectory.appendingPathComponent("jobs")
    }

    private func jobDirectory(for jobId: Int64) -> URL {
        jobsDirectory.appendingPathComponent("\(jobId)")
    }

    var cacheDirectory: URL {
        baseDirectory.appendingPathComponent("cache")
    }
}
