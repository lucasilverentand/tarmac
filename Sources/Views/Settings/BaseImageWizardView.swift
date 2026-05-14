import SwiftUI

struct BaseImageWizardView: View {
    let configStore: ConfigStore

    @State private var currentStep = 0
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var ipswURL: URL?
    @State private var imageManager: ImageManager
    @State private var downloadStartTime: Date?

    @Environment(\.dismiss) private var dismiss

    init(configStore: ConfigStore) {
        self.configStore = configStore
        let storage = StorageManager(rootPath: configStore.storageRootPath)
        let baseImageURL = Self.resolvedBaseImageURL(configStore: configStore, storage: storage)
        let platformStore = PlatformDataStore(storage: storage)
        _imageManager = State(
            initialValue: ImageManager(storage: storage)
        )
        _currentStep = State(
            initialValue: Self.initialStep(
                storage: storage,
                baseImageURL: baseImageURL,
                platformStore: platformStore
            )
        )
        _ipswURL = State(
            initialValue: FileManager.default.fileExists(atPath: storage.restoreIPSWURL.path)
                ? storage.restoreIPSWURL
                : nil
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)

            Divider()
            navigationBar
                .padding(16)
        }
        .frame(width: 560, height: 440)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Text("Base Image Setup")
                .font(.headline)
                .padding(.top, 20)

            HStack(spacing: 16) {
                ForEach(0..<4) { step in
                    HStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(
                                    step < currentStep
                                        ? AnyShapeStyle(.green)
                                        : step == currentStep ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary)
                                )
                                .frame(width: 22, height: 22)
                            if step < currentStep {
                                Image(systemName: "checkmark")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(step + 1)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(step == currentStep ? .white : .secondary)
                            }
                        }
                        Text(stepLabel(step))
                            .font(.caption)
                            .foregroundStyle(step == currentStep ? .primary : .secondary)
                    }

                    if step < 3 {
                        Rectangle()
                            .fill(step < currentStep ? AnyShapeStyle(.green) : AnyShapeStyle(.quaternary))
                            .frame(height: 1)
                            .frame(maxWidth: 32)
                    }
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func stepLabel(_ step: Int) -> String {
        switch step {
        case 0: "Download"
        case 1: "Install"
        case 2: "Verify"
        case 3: "Ready"
        default: ""
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0: downloadStep
        case 1: installStep
        case 2: verificationStep
        case 3: completeStep
        default: EmptyView()
        }
    }

    // MARK: - Download Step

    private var downloadStep: some View {
        VStack(spacing: 20) {
            if isWorking {
                downloadProgressView
            } else {
                downloadIdleView
            }

            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    private var downloadIdleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            if imageManager.canResume {
                Text("Resume Download")
                    .font(.title3.weight(.medium))

                Text("A previous download was interrupted. You can resume where you left off or start over.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)

                HStack(spacing: 12) {
                    Button("Start Over") {
                        imageManager.clearResumeData()
                        imageManager.cleanupTempIPSWFiles()
                        startDownload()
                    }
                    .controlSize(.large)

                    Button("Resume Download") {
                        startDownload()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else {
                Text("Download macOS Restore Image")
                    .font(.title3.weight(.medium))

                Text(
                    "A macOS IPSW file (~16 GB) will be downloaded from Apple to create the base virtual machine image."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

                Button("Download IPSW") {
                    startDownload()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var downloadProgressView: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)

            Text("Downloading macOS restore image...")
                .font(.subheadline.weight(.medium))

            VStack(spacing: 8) {
                ProgressView(value: imageManager.downloadProgress)
                    .progressViewStyle(.linear)

                HStack {
                    // Downloaded / Total
                    Text(
                        "\(formatBytes(imageManager.downloadedBytes)) / \(formatBytes(imageManager.totalDownloadBytes))"
                    )
                    .monospacedDigit()

                    Spacer()

                    // Percentage
                    Text("\(Int(imageManager.downloadProgress * 100))%")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    // Speed
                    if imageManager.downloadSpeed > 0 {
                        Label(
                            "\(formatBytes(Int64(imageManager.downloadSpeed)))/s",
                            systemImage: "arrow.down"
                        )
                    }

                    Spacer()

                    // ETA
                    if let eta = estimatedTimeRemaining {
                        Label(eta, systemImage: "clock")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 360)

            Button("Cancel Download") {
                cancelDownload()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundStyle(.secondary)
        }
    }

    private var estimatedTimeRemaining: String? {
        guard imageManager.downloadSpeed > 100 else { return nil }
        let remaining = imageManager.totalDownloadBytes - imageManager.downloadedBytes
        guard remaining > 0 else { return nil }
        let seconds = Double(remaining) / imageManager.downloadSpeed
        return formatETA(seconds)
    }

    // MARK: - Install Step

    private var installStep: some View {
        VStack(spacing: 20) {
            if isWorking {
                installProgressView
            } else {
                installIdleView
            }

            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    private var installIdleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("Install macOS")
                .font(.title3.weight(.medium))

            Text(
                "macOS will be installed into a virtual machine disk image. This creates the base image that ephemeral runners will clone for each job."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)

            let config = configStore.vmConfiguration
            HStack(spacing: 24) {
                Label("\(config.cpuCount) cores", systemImage: "cpu")
                Label("\(config.memorySizeGB) GB", systemImage: "memorychip")
                Label("\(config.diskSizeGB) GB", systemImage: "externaldrive")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button("Start Installation") {
                startInstall()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var installProgressView: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)

            Text("Installing macOS...")
                .font(.subheadline.weight(.medium))

            VStack(spacing: 8) {
                ProgressView(value: imageManager.installProgress)
                    .progressViewStyle(.linear)

                HStack {
                    Text("This may take 15\u{2013}30 minutes")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(Int(imageManager.installProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 360)
        }
    }

    // MARK: - Verification Step

    private var verificationStep: some View {
        VStack(spacing: 20) {
            if isWorking {
                verificationProgressView
            } else {
                verificationIdleView
            }

            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    private var verificationIdleView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            Text("Verify Base Image")
                .font(.title3.weight(.medium))

            Text("Tarmac will boot the installed image once, then stop it before marking it ready.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Button("Verify Image") {
                startVerification()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var verificationProgressView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)

            Text("Booting base image...")
                .font(.subheadline.weight(.medium))

            VStack(spacing: 8) {
                ProgressView(value: imageManager.verificationProgress)
                    .progressViewStyle(.linear)

                HStack {
                    Text("Starting and stopping the verification VM")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(Int(imageManager.verificationProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 360)
        }
    }

    // MARK: - Complete Step

    private var completeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)

            Text("Base image ready")
                .font(.title3.weight(.medium))

            Text(
                "Your ephemeral runner is ready to provision VMs for GitHub Actions jobs. Each job will get a fresh clone of this base image."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
        }
    }

    // MARK: - Navigation

    private var navigationBar: some View {
        HStack {
            if currentStep > 0 && currentStep < 3 {
                Button("Back") {
                    currentStep -= 1
                    errorMessage = nil
                }
                .disabled(isWorking)
            }

            Spacer()

            if currentStep == 3 {
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            } else if isWorking && currentStep == 0 {
                Button("Cancel") {
                    cancelDownload()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            } else {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isWorking)
            }
        }
    }

    // MARK: - Actions

    private func startDownload() {
        isWorking = true
        errorMessage = nil
        downloadStartTime = Date()

        Task {
            do {
                let url = try await imageManager.downloadLatestIPSW()
                ipswURL = url
                isWorking = false
                currentStep = 1
                Log.image.info("IPSW download completed: \(url.path)")
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
                Log.image.error("IPSW download failed: \(error.localizedDescription)")
            }
        }
    }

    private func cancelDownload() {
        imageManager.cancelDownload()
        isWorking = false
        errorMessage = nil
    }

    private func startInstall() {
        guard let ipsw = ipswURL else {
            errorMessage = "No IPSW downloaded. Go back and download first."
            return
        }

        isWorking = true
        errorMessage = nil

        Task {
            do {
                let vmConfig = configStore.vmConfiguration
                let storage = StorageManager(rootPath: configStore.storageRootPath)
                try storage.prepareBaseDirectories()
                try storage.cleanupTransientFiles()
                let baseImagePath = resolvedBaseImagePath(storage: storage)

                let diskManager = DiskImageManager()
                let baseImageURL = URL(fileURLWithPath: baseImagePath)
                try storage.clearBaseImageReadiness()
                try diskManager.createSparseDisk(at: baseImageURL, sizeGB: vmConfig.diskSizeGB)

                let platformStore = PlatformDataStore(storage: storage)
                try await imageManager.installMacOS(
                    ipsw: ipsw,
                    diskPath: baseImageURL,
                    config: vmConfig,
                    platformStore: platformStore
                )

                currentStep = 2
                try await imageManager.verifyBaseImageBoot(
                    diskPath: baseImageURL,
                    config: vmConfig,
                    platformStore: platformStore
                )

                configStore.baseImagePath = baseImagePath
                configStore.save()
                try? FileManager.default.removeItem(at: ipsw)

                isWorking = false
                currentStep = 3
                Log.image.info("Base image installation and verification completed")
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
                if currentStep == 2 {
                    Log.image.error("Base image verification failed: \(error.localizedDescription)")
                } else {
                    Log.image.error("Base image install failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func startVerification() {
        isWorking = true
        errorMessage = nil
        currentStep = 2

        Task {
            do {
                let vmConfig = configStore.vmConfiguration
                let storage = StorageManager(rootPath: configStore.storageRootPath)
                try storage.prepareBaseDirectories()
                let baseImagePath = resolvedBaseImagePath(storage: storage)
                let baseImageURL = URL(fileURLWithPath: baseImagePath)
                let platformStore = PlatformDataStore(storage: storage)

                try await imageManager.verifyBaseImageBoot(
                    diskPath: baseImageURL,
                    config: vmConfig,
                    platformStore: platformStore
                )

                configStore.baseImagePath = baseImagePath
                configStore.save()
                try? FileManager.default.removeItem(at: storage.restoreIPSWURL)

                isWorking = false
                currentStep = 3
                Log.image.info("Base image verification completed")
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
                Log.image.error("Base image verification failed: \(error.localizedDescription)")
            }
        }
    }

    private func resolvedBaseImagePath(storage: StorageManager) -> String {
        Self.resolvedBaseImageURL(configStore: configStore, storage: storage).path
    }

    private static func resolvedBaseImageURL(configStore: ConfigStore, storage: StorageManager) -> URL {
        if !configStore.baseImagePath.isEmpty {
            return URL(fileURLWithPath: configStore.baseImagePath)
        }
        return storage.baseImageURL
    }

    private static func initialStep(
        storage: StorageManager,
        baseImageURL: URL,
        platformStore: PlatformDataStore
    ) -> Int {
        let fm = FileManager.default
        if storage.isBaseImageReady(at: baseImageURL) {
            return 3
        }
        if fm.fileExists(atPath: baseImageURL.path), platformStore.hasExistingPlatform {
            return 2
        }
        if fm.fileExists(atPath: storage.restoreIPSWURL.path) {
            return 1
        }
        return 0
    }

    // MARK: - Formatting

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    private func formatETA(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s remaining"
        }
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes < 60 {
            return secs > 0 ? "\(minutes)m \(secs)s remaining" : "\(minutes)m remaining"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h \(remainingMinutes)m remaining"
    }
}
