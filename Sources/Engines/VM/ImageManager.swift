import Foundation
import Virtualization

@Observable
@MainActor
final class ImageManager: Sendable {
    private let storage: StorageManager

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

    init(storage: StorageManager = StorageManager(rootDirectory: StorageManager.defaultRootDirectory)) {
        self.storage = storage
    }

    var canResume: Bool {
        IPSWDownloader.hasResumeData(resumeDataURL: storage.ipswResumeDataURL, partialFileURL: storage.partialIPSWURL)
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

        try storage.prepareBaseDirectories()
        try storage.cleanupTransientFiles()

        if let warning = storage.storageWarning(minimumFreeBytes: 25 * 1024 * 1024 * 1024) {
            Log.image.warning("\(warning)")
        }

        let destination = storage.restoreIPSWURL
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

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

        let downloader = IPSWDownloader(
            resumeDataURL: storage.ipswResumeDataURL,
            partialFileURL: storage.partialIPSWURL
        )
        activeDownloader = downloader

        // Poll the downloader's progress on a timer so updates happen regardless of focus
        startProgressTimer()

        do {
            let localURL = try await downloader.download(from: downloadURL)
            stopProgressTimer()
            syncProgress(from: downloader)  // final sync

            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: localURL, to: destination)
            IPSWDownloader.clearResumeData(
                resumeDataURL: storage.ipswResumeDataURL,
                partialFileURL: storage.partialIPSWURL
            )
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
        IPSWDownloader.clearResumeData(
            resumeDataURL: storage.ipswResumeDataURL,
            partialFileURL: storage.partialIPSWURL
        )
        Log.image.info("Resume data cleared")
    }

    func cleanupTempIPSWFiles() {
        let tmpDir = storage.tmpDirectory
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: tmpDir,
                includingPropertiesForKeys: nil
            )
        else { return }

        for file in contents where file.lastPathComponent.hasPrefix("ipsw-") && file.pathExtension == "ipsw" {
            try? FileManager.default.removeItem(at: file)
        }
        try? FileManager.default.removeItem(at: storage.partialIPSWURL)
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
        downloadProgress =
            snapshot.bytesExpected > 0
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

        let hardwareModelData = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            VZMacOSRestoreImage.load(from: ipsw) { result in
                switch result {
                case .success(let image):
                    guard HostCapability.isRestoreImageSupported(version: image.operatingSystemVersion) else {
                        continuation.resume(
                            throwing: ImageManagerError.unsupportedGuestVersion(
                                found: image.operatingSystemVersion,
                                minimumMajor: HostCapability.minimumMajorVersion
                            )
                        )
                        return
                    }
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
    case unsupportedGuestVersion(found: OperatingSystemVersion, minimumMajor: Int)

    var errorDescription: String? {
        switch self {
        case .noDownloadURL:
            "No download URL available for the restore image"
        case .unsupportedHardware:
            "This Mac does not support the required virtualization hardware"
        case .unsupportedGuestVersion(let found, let minimumMajor):
            "Restore image is macOS \(found.majorVersion).\(found.minorVersion); "
                + "Tarmac requires macOS \(minimumMajor) or later."
        }
    }
}

// MARK: - IPSW Downloader

/// Delegate-based downloader that stores partial IPSW data inside Tarmac's storage root.
final class IPSWDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct ProgressSnapshot: Sendable {
        let bytesWritten: Int64
        let bytesExpected: Int64
    }

    private struct ResumeState: Codable {
        let url: URL
        let bytesWritten: Int64
    }

    private let resumeDataURL: URL
    private let partialFileURL: URL

    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var downloadTask: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var sourceURL: URL?

    // Atomic progress — written from delegate queue, read from main actor
    private let lock = NSLock()
    private var _bytesWritten: Int64 = 0
    private var _bytesExpected: Int64 = 0
    private var _shouldAppend = false

    init(resumeDataURL: URL, partialFileURL: URL) {
        self.resumeDataURL = resumeDataURL
        self.partialFileURL = partialFileURL
    }

    func progressSnapshot() -> ProgressSnapshot {
        lock.withLock {
            ProgressSnapshot(bytesWritten: _bytesWritten, bytesExpected: _bytesExpected)
        }
    }

    func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.sourceURL = url
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session

            var request = URLRequest(url: url)
            if let resumeState = loadResumeState(),
                resumeState.url == url,
                FileManager.default.fileExists(atPath: partialFileURL.path),
                resumeState.bytesWritten > 0
            {
                request.setValue("bytes=\(resumeState.bytesWritten)-", forHTTPHeaderField: "Range")
                lock.withLock {
                    _bytesWritten = resumeState.bytesWritten
                    _bytesExpected = resumeState.bytesWritten
                    _shouldAppend = true
                }
                Log.image.info("Resuming download from byte \(resumeState.bytesWritten)")
            } else {
                try? FileManager.default.removeItem(at: partialFileURL)
                try? FileManager.default.removeItem(at: resumeDataURL)
                lock.withLock {
                    _bytesWritten = 0
                    _bytesExpected = 0
                    _shouldAppend = false
                }
            }

            self.downloadTask = session.dataTask(with: request)
            self.downloadTask?.resume()
        }
    }

    func cancel() {
        saveResumeState()
        downloadTask?.cancel()
    }

    // MARK: - Resume Data Persistence

    static func hasResumeData(resumeDataURL: URL, partialFileURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: resumeDataURL.path)
            && FileManager.default.fileExists(atPath: partialFileURL.path)
    }

    static func clearResumeData(resumeDataURL: URL, partialFileURL: URL) {
        try? FileManager.default.removeItem(at: resumeDataURL)
        try? FileManager.default.removeItem(at: partialFileURL)
    }

    private func saveResumeState() {
        guard let sourceURL else { return }
        let snapshot = progressSnapshot()
        guard snapshot.bytesWritten > 0 else { return }

        let state = ResumeState(url: sourceURL, bytesWritten: snapshot.bytesWritten)
        do {
            try FileManager.default.createDirectory(
                at: resumeDataURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: resumeDataURL, options: .atomic)
            Log.image.info("Resume state saved at byte \(snapshot.bytesWritten)")
        } catch {
            Log.image.error("Failed to save resume state: \(error.localizedDescription)")
        }
    }

    private func loadResumeState() -> ResumeState? {
        guard let data = try? Data(contentsOf: resumeDataURL) else { return nil }
        return try? JSONDecoder().decode(ResumeState.self, from: data)
    }

    private func closeFileHandle() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            try FileManager.default.createDirectory(
                at: partialFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let shouldAppend = lock.withLock { _shouldAppend && statusCode == 206 }
            if !shouldAppend {
                FileManager.default.createFile(atPath: partialFileURL.path, contents: nil)
                lock.withLock {
                    _bytesWritten = 0
                    _shouldAppend = false
                }
            }

            let handle = try FileHandle(forWritingTo: partialFileURL)
            if shouldAppend {
                try handle.seekToEnd()
            }
            fileHandle = handle

            let expected = response.expectedContentLength
            lock.withLock {
                if expected > 0 {
                    _bytesExpected = _bytesWritten + expected
                }
            }
            completionHandler(.allow)
        } catch {
            continuation?.resume(throwing: error)
            continuation = nil
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try fileHandle?.write(contentsOf: data)
            lock.withLock {
                _bytesWritten += Int64(data.count)
                if _bytesExpected < _bytesWritten {
                    _bytesExpected = _bytesWritten
                }
            }
        } catch {
            saveResumeState()
            dataTask.cancel()
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        closeFileHandle()
        if let error {
            saveResumeState()
            continuation?.resume(throwing: error)
        } else if FileManager.default.fileExists(atPath: partialFileURL.path) {
            continuation?.resume(returning: partialFileURL)
        } else {
            continuation?.resume(throwing: ImageManagerError.noDownloadURL)
        }
        continuation = nil
        session.invalidateAndCancel()
    }
}
