import SwiftUI

enum VerifyDisplayState: Equatable {
    case idle
    case running
    case success
    case failed(message: String)
}

enum BaseImagePreparationState: Equatable {
    case idle
    case booting
    case installingBootstrap
    case running
    case stopping
    case ready
    case failed(message: String)
}

struct BaseImageWizardView: View {
    let configStore: ConfigStore

    @State private var currentStep = 0
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var ipswURL: URL?
    @State private var imageManager: ImageManager
    @State private var downloadStartTime: Date?
    @State private var verificationStatus: VerifyDisplayState = .idle
    @State private var preparationStatus: BaseImagePreparationState = .idle
    @State private var preparationLifecycle: VMLifecycle?
    @State private var usesAutomatedProvisioning = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    init(configStore: ConfigStore) {
        self.configStore = configStore
        let storage = StorageManager(rootPath: configStore.storageRootPath)

        let retainedIPSW =
            FileManager.default.fileExists(atPath: storage.restoreIPSWURL.path)
            ? storage.restoreIPSWURL : nil
        let platformStore = PlatformDataStore(storage: storage)
        let canResumeUnverifiedBase =
            FileManager.default.fileExists(atPath: storage.baseImageURL.path)
            && FileManager.default.fileExists(atPath: platformStore.auxiliaryStoragePath.path)
            && platformStore.loadHardwareModel() != nil
            && platformStore.loadMachineIdentifier() != nil
            && !storage.isBaseImageVerified()
        _currentStep = State(initialValue: canResumeUnverifiedBase ? 2 : (retainedIPSW == nil ? 0 : 1))
        _ipswURL = State(initialValue: retainedIPSW)
        _usesAutomatedProvisioning = State(initialValue: canResumeUnverifiedBase)
        _imageManager = State(
            initialValue: ImageManager(storage: storage)
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
        .frame(width: 680, height: 500)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Text("Base Image Setup")
                .font(.headline)
                .padding(.top, 20)

            HStack(spacing: 16) {
                ForEach(0..<5) { step in
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

                    if step < 4 {
                        Rectangle()
                            .fill(step < currentStep ? AnyShapeStyle(.green) : AnyShapeStyle(.quaternary))
                            .frame(height: 1)
                            .frame(maxWidth: 24)
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
        case 2: "Prepare"
        case 3: "Verify"
        case 4: "Done"
        default: ""
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0: downloadStep
        case 1: installStep
        case 2: prepareStep
        case 3: verifyStep
        case 4: completeStep
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
                Text("Download macOS 27 Restore Image")
                    .font(.title3.weight(.medium))

                Text(
                    "A macOS 27 IPSW file (~23 GB) will be downloaded from Apple to create a fully provisioned runner image. Older macOS releases cannot create the owner account automatically."
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

            Text("Downloading macOS 27 restore image...")
                .font(.subheadline.weight(.medium))

            VStack(spacing: 8) {
                ProgressView(value: imageManager.downloadProgress)
                    .progressViewStyle(.linear)
                    .animation(.linear(duration: 0.1), value: imageManager.downloadProgress)

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

            Text("Install macOS 27")
                .font(.title3.weight(.medium))

            Text(
                "macOS 27 will be installed and provisioned with a secure tarmac owner, automatic login, and the runner bootstrap. Each job receives a fresh clone of this image."
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

            Text(imageManager.installStatus)
                .font(.subheadline.weight(.medium))

            VStack(spacing: 8) {
                ProgressView(value: imageManager.installProgress)
                    .progressViewStyle(.linear)
                    .animation(.linear(duration: 0.1), value: imageManager.installProgress)

                HStack {
                    Text(formatElapsed(imageManager.installElapsedSeconds))
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

    // MARK: - Prepare Step

    private var prepareStep: some View {
        VStack(spacing: 18) {
            Image(
                systemName: preparationStatus == .ready
                    ? "person.crop.circle.badge.checkmark"
                    : (usesAutomatedProvisioning ? "gearshape.2" : "hand.tap")
            )
                .font(.system(size: 42))
                .foregroundStyle(preparationStatus == .ready ? Color.green : Color.accentColor)

            Text(preparationTitle)
                .font(.title3.weight(.medium))

            Text(preparationMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)

            if preparationStatus == .running, !usesAutomatedProvisioning {
                Text("cd '/Volumes/My Shared Files' && sudo ./install-tarmac-runner-bootstrap.sh")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            preparationActions
        }
    }

    private var preparationTitle: String {
        switch preparationStatus {
        case .idle: usesAutomatedProvisioning ? "Ready for unattended setup" : "Create the VM owner"
        case .booting: usesAutomatedProvisioning ? "Provisioning the VM owner" : "Booting setup VM"
        case .installingBootstrap: "Installing the runner bootstrap"
        case .running: "Finish setup inside the VM"
        case .stopping: "Saving the prepared image"
        case .ready: "Preparation saved"
        case .failed: "Preparation failed"
        }
    }

    private var preparationMessage: String {
        switch preparationStatus {
        case .idle:
            if usesAutomatedProvisioning {
                "Tarmac will create the tarmac administrator with a Keychain-protected password, enable automatic login, and skip Setup Assistant."
            } else {
                "Boot the installed image, switch the VM display to Take Over, and complete Setup Assistant with an administrator account named tarmac. A real first account is required to make the virtual Mac bootable."
            }
        case .booting:
            usesAutomatedProvisioning
                ? "Starting macOS 27 with Apple's first-boot guest provisioning protocol."
                : "Starting the installed image with keyboard, pointer, and the guest bootstrap share attached."
        case .installingBootstrap:
            "The tarmac desktop is active. Installing the LaunchDaemon through the temporary private provisioning channel."
        case .running:
            "Complete Setup Assistant with the tarmac account. Then open Terminal in the guest and run the command below using that account's password. The installer enables automatic login and disables screen lock and sleep."
        case .stopping:
            "Stopping the setup VM cleanly so its owner account and automatic-login settings remain in the base image."
        case .ready:
            "The setup VM stopped cleanly. Verification will only pass if macOS logs in as tarmac and the interactive desktop session becomes active."
        case .failed(let message):
            message
        }
    }

    @ViewBuilder
    private var preparationActions: some View {
        if usesAutomatedProvisioning {
            switch preparationStatus {
            case .idle, .failed:
                HStack(spacing: 12) {
                    Button("Verify Existing Image") {
                        startVerify()
                    }
                    .controlSize(.large)

                    Button("Run Unattended Setup") {
                        startAutomatedPreparation()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            case .booting, .installingBootstrap, .running, .stopping:
                ProgressView()
                    .controlSize(.large)
            case .ready:
                Button("Verify Automatic Login") {
                    startVerify()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        } else {
            switch preparationStatus {
            case .idle, .failed:
                HStack(spacing: 12) {
                    Button("Verify Existing Image") {
                        startVerify()
                    }
                    .controlSize(.large)

                    Button("Boot Setup VM") {
                        startPreparation()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            case .booting, .installingBootstrap, .stopping:
                ProgressView()
                    .controlSize(.large)
            case .running:
                HStack(spacing: 12) {
                    Button("Open VM Display") {
                        openWindow(id: "vm-display")
                    }
                    .controlSize(.large)

                    Button("Stop & Continue") {
                        stopPreparation()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            case .ready:
                Button("Verify Automatic Login") {
                    startVerify()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Verify Step

    private var verifyStep: some View {
        VStack(spacing: 20) {
            switch verificationStatus {
            case .idle, .running:
                verifyRunningView
            case .failed(let message):
                verifyFailedView(message: message)
            case .success:
                verifyRunningView
            }
        }
    }

    private var verifyRunningView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)

            Text("Verifying base image")
                .font(.title3.weight(.medium))

            Text(
                "Tarmac is booting a clone of the base image and checking that the guest bootstrap LaunchDaemon can see the shared job directory."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)

            ProgressView()
                .controlSize(.large)
        }
    }

    private func verifyFailedView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.red)

            Text("Verification failed")
                .font(.title3.weight(.medium))

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .lineLimit(4)

            if message.localizedCaseInsensitiveContains("guest bootstrap") {
                Text(
                    "Install `Resources/GuestBootstrap/install-tarmac-runner-bootstrap.sh` inside the base image with automatic login enabled, then retry verification."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button("Retry Verification") {
                startVerify()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Complete Step

    private var completeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)

            Text("Base image created")
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
                .disabled(isWorking || preparationIsActive)
            }

            Spacer()

            if currentStep == 4 {
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
                .disabled(isWorking || preparationIsActive)
            }
        }
    }

    private var preparationIsActive: Bool {
        switch preparationStatus {
        case .booting, .installingBootstrap, .running, .stopping:
            true
        case .idle, .ready, .failed:
            false
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
                try diskManager.createSparseDisk(at: baseImageURL, sizeGB: vmConfig.diskSizeGB, overwrite: true)

                let platformStore = PlatformDataStore(storage: storage)
                let installedVersion = try await imageManager.installMacOS(
                    ipsw: ipsw,
                    diskPath: baseImageURL,
                    config: vmConfig,
                    platformStore: platformStore
                )

                configStore.baseImagePath = baseImagePath
                configStore.save()
                // A fresh install invalidates any previous verification marker.
                try? storage.clearBaseImageVerified()

                isWorking = false
                currentStep = 2
                usesAutomatedProvisioning =
                    installedVersion.majorVersion >= MacOSRestoreCatalog.unattendedProvisioningMajorVersion
                preparationStatus = usesAutomatedProvisioning ? .booting : .idle
                Log.image.info("Base image installation completed; starting owner provisioning")
                if usesAutomatedProvisioning {
                    startAutomatedPreparation()
                }
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
                Log.image.error("Base image install failed: \(error.localizedDescription)")
            }
        }
    }

    private func startVerify() {
        errorMessage = nil
        verificationStatus = .running
        currentStep = 3

        Task {
            do {
                let vmConfig = configStore.vmConfiguration
                let storage = StorageManager(rootPath: configStore.storageRootPath)
                let baseImagePath = resolvedBaseImagePath(storage: storage)

                let engine = VMEngine(
                    cacheDirectoryPath: configStore.storageRootPath,
                    baseImagePath: baseImagePath
                )
                try await engine.verifyBaseImage(config: vmConfig)
                let cleanupResult = try storage.cleanupInstallerArtifactsAfterVerification(
                    keepRestoreImage: configStore.keepInstallerAfterVerification
                )

                verificationStatus = .success
                currentStep = 4
                if cleanupResult.removedItems > 0 {
                    Log.image.info(
                        "Cleaned \(cleanupResult.removedItems) installer artifact(s) after base image verification"
                    )
                }
                Log.vm.info("Base image verification completed")
            } catch {
                verificationStatus = .failed(message: error.localizedDescription)
                Log.vm.error("Base image verification failed: \(error.localizedDescription)")
            }
        }
    }

    private func startPreparation() {
        preparationStatus = .booting
        errorMessage = nil

        Task {
            do {
                let storage = StorageManager(rootPath: configStore.storageRootPath)
                try storage.prepareBaseDirectories()
                try storage.clearBaseImageVerified()
                let sharedDirectory = try prepareGuestBootstrapShare(storage: storage)
                let lifecycle = VMLifecycle()
                preparationLifecycle = lifecycle

                try await lifecycle.bootVM(
                    vmConfig: configStore.vmConfiguration,
                    diskPath: URL(fileURLWithPath: resolvedBaseImagePath(storage: storage)),
                    platformStore: PlatformDataStore(storage: storage),
                    sharedDirectoryURL: sharedDirectory,
                    cacheDirectoryURL: nil
                )

                preparationStatus = .running
                openWindow(id: "vm-display")
            } catch {
                preparationLifecycle = nil
                preparationStatus = .failed(message: error.localizedDescription)
                Log.vm.error("Setup VM failed: \(error.localizedDescription)")
            }
        }
    }

    private func startAutomatedPreparation() {
        usesAutomatedProvisioning = true
        preparationStatus = .booting
        errorMessage = nil

        Task {
            let storage = StorageManager(rootPath: configStore.storageRootPath)
            let lifecycle = VMLifecycle()
            do {
                try storage.prepareBaseDirectories()
                try storage.clearBaseImageVerified()
                let credentials = try MacGuestCredentialStore(
                    keychainService: configStore.keychainService
                ).loadOrCreate()
                let sharedDirectory = try prepareGuestBootstrapShare(storage: storage)
                preparationLifecycle = lifecycle

                var lastBootError: Error?
                for attempt in 1...10 {
                    do {
                        try await lifecycle.bootProvisionedVM(
                            vmConfig: configStore.vmConfiguration,
                            diskPath: URL(fileURLWithPath: resolvedBaseImagePath(storage: storage)),
                            platformStore: PlatformDataStore(storage: storage),
                            sharedDirectoryURL: sharedDirectory,
                            provisioning: credentials
                        )
                        lastBootError = nil
                        break
                    } catch {
                        lastBootError = error
                        let installerStillReleasing = error.localizedDescription
                            .localizedCaseInsensitiveContains("lock auxiliary storage")
                        guard installerStillReleasing, attempt < 10 else { throw error }
                        Log.vm.info("Waiting for the macOS installer to release auxiliary storage (attempt \(attempt))")
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                if let lastBootError {
                    throw lastBootError
                }

                guard let macAddress = lifecycle.networkMACAddress else {
                    throw MacGuestProvisioningError.missingNetworkAddress
                }

                preparationStatus = .installingBootstrap
                let guestAddress = try await MacGuestBootstrapInstaller().install(
                    credentials: credentials,
                    macAddress: macAddress
                )
                Log.vm.info("Provisioned guest bootstrap at \(guestAddress)")

                preparationStatus = .stopping
                try await lifecycle.stopVM()
                preparationLifecycle = nil
                preparationStatus = .ready
                startVerify()
            } catch {
                if lifecycle.isBooted {
                    try? await lifecycle.stopVM()
                }
                preparationLifecycle = nil
                preparationStatus = .failed(message: error.localizedDescription)
                Log.vm.error("Automated guest provisioning failed: \(error.localizedDescription)")
            }
        }
    }

    private func stopPreparation() {
        guard let preparationLifecycle else {
            preparationStatus = .ready
            return
        }

        preparationStatus = .stopping
        Task {
            do {
                try await preparationLifecycle.stopVM()
                self.preparationLifecycle = nil
                preparationStatus = .ready
            } catch {
                preparationStatus = .failed(message: "Could not stop the setup VM: \(error.localizedDescription)")
            }
        }
    }

    private func prepareGuestBootstrapShare(storage: StorageManager) throws -> URL {
        let directory = storage.tmpDirectory.appendingPathComponent("guest-bootstrap", isDirectory: true)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let resources = [
            ("install-tarmac-runner-bootstrap", "sh", 0o755),
            ("tarmac-runner-bootstrap", "sh", 0o755),
            ("studio.seventwo.tarmac.runner-bootstrap", "plist", 0o644),
        ]
        for (name, extensionName, permissions) in resources {
            guard let source = Bundle.main.url(forResource: name, withExtension: extensionName) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let destination = directory.appendingPathComponent("\(name).\(extensionName)")
            try fileManager.copyItem(at: source, to: destination)
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
        }
        return directory
    }

    private func resolvedBaseImagePath(storage: StorageManager) -> String {
        if !configStore.baseImagePath.isEmpty {
            return configStore.baseImagePath
        }
        return storage.baseImageURL.path
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

    private func formatElapsed(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s elapsed"
        }

        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes < 60 {
            return remainingSeconds > 0 ? "\(minutes)m \(remainingSeconds)s elapsed" : "\(minutes)m elapsed"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return remainingMinutes > 0 ? "\(hours)h \(remainingMinutes)m elapsed" : "\(hours)h elapsed"
    }
}
