import Foundation
import Virtualization

@Observable
@MainActor
final class ImageManager: Sendable {
    private(set) var downloadProgress: Double = 0
    private(set) var downloadedBytes: Int64 = 0
    private(set) var totalDownloadBytes: Int64 = 0
    private(set) var downloadSpeed: Double = 0
    private(set) var isDownloading: Bool = false

    private(set) var installProgress: Double = 0
    private var progressObservation: NSKeyValueObservation?

    private var activeDownloader: IPSWDownloader?
    private var progressTimer: Timer?
    private var speedSampleBytes: Int64 = 0
    private var speedSampleTime: Date = Date()

    var canResume: Bool {
        IPSWDownloader.hasResumeData
    }

    func downloadLatestIPSW() async throws -> URL {
        Log.image.info("Fetching latest supported restore image...")

        let downloadURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            VZMacOSRestoreImage.fetchLatestSupported { result in
                switch result {
                case .success(let image):
                    continuation.resume(returning: image.url)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
        Log.image.info("Downloading IPSW from \(downloadURL.absoluteString)...")

        let destination = Self.ipswDestination
        let cacheDir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Remove completed file if re-downloading
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        // Reset state
        downloadProgress = 0
        downloadedBytes = 0
        totalDownloadBytes = 0
        downloadSpeed = 0
        speedSampleBytes = 0
        speedSampleTime = Date()
        isDownloading = true

        let downloader = IPSWDownloader()
        activeDownloader = downloader

        // Poll the downloader's progress on a timer so updates happen regardless of focus
        startProgressTimer()

        do {
            let localURL = try await downloader.download(from: downloadURL)
            stopProgressTimer()
            syncProgress(from: downloader) // final sync

            try FileManager.default.moveItem(at: localURL, to: destination)
            IPSWDownloader.clearResumeData()
            cleanupTempIPSWFiles()

            downloadProgress = 1.0
            downloadedBytes = totalDownloadBytes
            downloadSpeed = 0
            isDownloading = false
            activeDownloader = nil

            Log.image.info("IPSW downloaded to \(destination.path)")
            return destination
        } catch {
            stopProgressTimer()
            isDownloading = false
            activeDownloader = nil
            // Resume data is saved automatically by the downloader on failure
            throw error
        }
    }

    func cancelDownload() {
        activeDownloader?.cancel()
        stopProgressTimer()
        isDownloading = false
        activeDownloader = nil
        Log.image.info("Download cancelled")
    }

    func clearResumeData() {
        IPSWDownloader.clearResumeData()
        Log.image.info("Resume data cleared")
    }

    func cleanupTempIPSWFiles() {
        let tmpDir = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tmpDir,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in contents where file.lastPathComponent.hasPrefix("ipsw-") && file.pathExtension == "ipsw" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static var ipswDestination: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Tarmac/restore.ipsw")
    }

    // MARK: - Progress Timer

    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let downloader = self.activeDownloader else { return }
                self.syncProgress(from: downloader)
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func syncProgress(from downloader: IPSWDownloader) {
        let snapshot = downloader.progressSnapshot()
        downloadedBytes = snapshot.bytesWritten
        totalDownloadBytes = snapshot.bytesExpected
        downloadProgress = snapshot.bytesExpected > 0
            ? Double(snapshot.bytesWritten) / Double(snapshot.bytesExpected)
            : 0

        let now = Date()
        let elapsed = now.timeIntervalSince(speedSampleTime)
        if elapsed >= 0.5 {
            let delta = snapshot.bytesWritten - speedSampleBytes
            downloadSpeed = Double(delta) / elapsed
            speedSampleBytes = snapshot.bytesWritten
            speedSampleTime = now
        }
    }

    // MARK: - Install

    func installMacOS(
        ipsw: URL,
        diskPath: URL,
        config: VMConfiguration,
        platformStore: PlatformDataStore
    ) async throws {
        Log.image.info("Starting macOS install from \(ipsw.lastPathComponent)")

        let hardwareModelData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            VZMacOSRestoreImage.load(from: ipsw) { result in
                switch result {
                case .success(let image):
                    guard let requirements = image.mostFeaturefulSupportedConfiguration else {
                        continuation.resume(throwing: ImageManagerError.unsupportedHardware)
                        return
                    }
                    continuation.resume(returning: requirements.hardwareModel.dataRepresentation)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }

        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
            throw ImageManagerError.unsupportedHardware
        }
        let machineIdentifier = VZMacMachineIdentifier()

        try platformStore.saveHardwareModel(hardwareModelData)
        try platformStore.saveMachineIdentifier(machineIdentifier.dataRepresentation)

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = try VZMacAuxiliaryStorage(
            creatingStorageAt: platformStore.auxiliaryStoragePath,
            hardwareModel: hardwareModel
        )

        let vmConfig = VZVirtualMachineConfiguration()
        vmConfig.platform = platform
        vmConfig.bootLoader = VZMacOSBootLoader()
        vmConfig.cpuCount = min(config.cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        vmConfig.memorySize = min(config.memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskPath, readOnly: false)
        vmConfig.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        vmConfig.networkDevices = [network]

        try vmConfig.validate()

        let vm = VZVirtualMachine(configuration: vmConfig)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)

        progressObservation = installer.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor in
                self?.installProgress = progress.fractionCompleted
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            installer.install { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }

        progressObservation = nil
        installProgress = 1.0
        Log.image.info("macOS installation completed")
    }
}

enum ImageManagerError: LocalizedError {
    case noDownloadURL
    case unsupportedHardware

    var errorDescription: String? {
        switch self {
        case .noDownloadURL:
            "No download URL available for the restore image"
        case .unsupportedHardware:
            "This Mac does not support the required virtualization hardware"
        }
    }
}

// MARK: - IPSW Downloader

/// Delegate-based downloader that supports resume and exposes atomic progress snapshots.
final class IPSWDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct ProgressSnapshot: Sendable {
        let bytesWritten: Int64
        let bytesExpected: Int64
    }

    private var continuation: CheckedContinuation<URL, Error>?
    private var tempFileURL: URL?
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?

    // Atomic progress — written from delegate queue, read from main actor
    private let lock = NSLock()
    private var _bytesWritten: Int64 = 0
    private var _bytesExpected: Int64 = 0

    private static var resumeDataURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Tarmac/ipsw-resume.data")
    }

    func progressSnapshot() -> ProgressSnapshot {
        lock.withLock {
            ProgressSnapshot(bytesWritten: _bytesWritten, bytesExpected: _bytesExpected)
        }
    }

    func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session

            if let resumeData = Self.loadResumeData() {
                Log.image.info("Resuming download from saved state")
                self.downloadTask = session.downloadTask(withResumeData: resumeData)
            } else {
                self.downloadTask = session.downloadTask(with: url)
            }
            self.downloadTask?.resume()
        }
    }

    func cancel() {
        downloadTask?.cancel(byProducingResumeData: { [weak self] data in
            if let data {
                Self.saveResumeData(data)
                Log.image.info("Resume data saved (\(data.count) bytes)")
            }
            // The didCompleteWithError delegate will fire and resume the continuation
            _ = self // prevent premature dealloc
        })
    }

    // MARK: - Resume Data Persistence

    static var hasResumeData: Bool {
        FileManager.default.fileExists(atPath: resumeDataURL.path)
    }

    static func saveResumeData(_ data: Data) {
        let dir = resumeDataURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: resumeDataURL, options: .atomic)
    }

    static func loadResumeData() -> Data? {
        try? Data(contentsOf: resumeDataURL)
    }

    static func clearResumeData() {
        try? FileManager.default.removeItem(at: resumeDataURL)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.withLock {
            _bytesWritten = totalBytesWritten
            _bytesExpected = totalBytesExpectedToWrite
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let stableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipsw-\(UUID().uuidString).ipsw")
        do {
            try FileManager.default.copyItem(at: location, to: stableURL)
            tempFileURL = stableURL
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            // Save resume data from the error if available
            let nsError = error as NSError
            if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                Self.saveResumeData(resumeData)
            }
            continuation?.resume(throwing: error)
        } else if let url = tempFileURL {
            continuation?.resume(returning: url)
        } else {
            continuation?.resume(throwing: ImageManagerError.noDownloadURL)
        }
        continuation = nil
        session.invalidateAndCancel()
    }
}
