import Darwin
import Foundation
import Virtualization

private struct SmokeConfig {
    var storageRoot: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Tarmac/Storage", isDirectory: true)
    var ipsw: URL?
    var downloadLatest = false
    var install = false
    var boot = true
    var keepRunning = false
    var bootHoldSeconds: UInt64 = 30
    var cpuCount = 4
    var memoryGB = 8
    var diskSizeGB = 80
}

private struct SmokeStorage {
    let root: URL

    var baseImage: URL { root.appendingPathComponent("BaseImage.img") }
    var restoreIPSW: URL { root.appendingPathComponent("restore.ipsw") }
    var platformDirectory: URL { root.appendingPathComponent("Platform", isDirectory: true) }
    var disksDirectory: URL { root.appendingPathComponent("disks", isDirectory: true) }
    var tmpDirectory: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    var smokeSharedDirectory: URL { root.appendingPathComponent("smoke-shared", isDirectory: true) }
    var hardwareModel: URL { platformDirectory.appendingPathComponent("hardwareModel.bin") }
    var machineIdentifier: URL { platformDirectory.appendingPathComponent("machineIdentifier.bin") }
    var auxiliaryStorage: URL { platformDirectory.appendingPathComponent("auxiliaryStorage.bin") }

    func prepare() throws {
        for directory in [root, platformDirectory, disksDirectory, tmpDirectory, smokeSharedDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

private enum SmokeError: LocalizedError {
    case missingBaseImage(URL)
    case missingIPSW(URL)
    case missingPlatformData(URL)
    case unsupportedRestoreImage(URL)
    case diskCreateFailed(URL, Int32)
    case cloneFailed(URL, URL, Int32)
    case badArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingBaseImage(let url):
            "No base image exists at \(url.path). Run with --install plus --ipsw <path> or --download-latest."
        case .missingIPSW(let url):
            "No restore IPSW exists at \(url.path). Pass --ipsw <path> or --download-latest."
        case .missingPlatformData(let url):
            "Missing platform data in \(url.path). Reinstall the base image."
        case .unsupportedRestoreImage(let url):
            "Restore image is not supported on this Mac: \(url.path)"
        case .diskCreateFailed(let url, let code):
            "Could not create sparse disk at \(url.path): errno \(code)"
        case .cloneFailed(let source, let destination, let code):
            "Could not clone \(source.path) to \(destination.path): errno \(code)"
        case .badArgument(let message):
            message
        }
    }
}

@main
private struct TarmacVMSmoke {
    static func main() async {
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        do {
            let config = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            let runner = SmokeRunner(config: config)
            try await runner.run()
        } catch {
            fputs("VM smoke failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func parseArguments(_ arguments: [String]) throws -> SmokeConfig {
        var config = SmokeConfig()
        var index = 0

        func value(after flag: String) throws -> String {
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw SmokeError.badArgument("Missing value after \(flag)")
            }
            index = valueIndex
            return arguments[valueIndex]
        }

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--storage-root":
                config.storageRoot = URL(fileURLWithPath: try value(after: arg)).standardizedFileURL
            case "--ipsw":
                config.ipsw = URL(fileURLWithPath: try value(after: arg)).standardizedFileURL
                config.install = true
            case "--download-latest":
                config.downloadLatest = true
                config.install = true
            case "--install":
                config.install = true
            case "--no-boot":
                config.boot = false
            case "--keep-running":
                config.keepRunning = true
            case "--boot-hold-seconds":
                guard let seconds = UInt64(try value(after: arg)) else {
                    throw SmokeError.badArgument("Invalid seconds value for \(arg)")
                }
                config.bootHoldSeconds = seconds
            case "--cpus":
                guard let cpus = Int(try value(after: arg)) else {
                    throw SmokeError.badArgument("Invalid CPU count for \(arg)")
                }
                config.cpuCount = cpus
            case "--memory-gb":
                guard let memory = Int(try value(after: arg)) else {
                    throw SmokeError.badArgument("Invalid memory value for \(arg)")
                }
                config.memoryGB = memory
            case "--disk-size-gb":
                guard let disk = Int(try value(after: arg)) else {
                    throw SmokeError.badArgument("Invalid disk size for \(arg)")
                }
                config.diskSizeGB = disk
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                throw SmokeError.badArgument("Unknown argument: \(arg)")
            }

            index += 1
        }

        return config
    }

    private static func printUsage() {
        print(
            """
            Usage: script/vm_smoke.sh [options]

            Options:
              --storage-root <path>       Storage root. Defaults to Tarmac's app storage.
              --install                   Install or replace the base image before booting.
              --ipsw <path>               Install from this IPSW.
              --download-latest           Download Apple's latest supported IPSW, then install.
              --no-boot                   Install only.
              --keep-running              Leave the VM running until this process is stopped.
              --boot-hold-seconds <n>     Seconds to keep the VM running after start. Default: 30.
              --cpus <n>                  Requested CPU count. Default: 4.
              --memory-gb <n>             Requested memory. Default: 8.
              --disk-size-gb <n>          Base disk size for install. Default: 80.
            """
        )
    }
}

@MainActor
private final class SmokeRunner: NSObject, VZVirtualMachineDelegate {
    private let config: SmokeConfig
    private let storage: SmokeStorage
    private var virtualMachine: VZVirtualMachine?

    init(config: SmokeConfig) {
        self.config = config
        self.storage = SmokeStorage(root: config.storageRoot)
    }

    func run() async throws {
        try storage.prepare()
        print("Storage: \(storage.root.path)")

        if config.install {
            let ipsw = try await resolveIPSW()
            try await installBaseImage(from: ipsw)
        }

        guard FileManager.default.fileExists(atPath: storage.baseImage.path) else {
            throw SmokeError.missingBaseImage(storage.baseImage)
        }

        guard config.boot else {
            print("Install smoke passed; boot skipped by --no-boot.")
            return
        }

        try await bootSmoke()
    }

    private func resolveIPSW() async throws -> URL {
        if let ipsw = config.ipsw {
            guard FileManager.default.fileExists(atPath: ipsw.path) else {
                throw SmokeError.missingIPSW(ipsw)
            }
            return ipsw
        }

        if FileManager.default.fileExists(atPath: storage.restoreIPSW.path) {
            return storage.restoreIPSW
        }

        guard config.downloadLatest else {
            throw SmokeError.missingIPSW(storage.restoreIPSW)
        }

        let remoteURL = try await latestRestoreImageURL()
        print("Downloading \(remoteURL.absoluteString)")
        let (temporaryURL, _) = try await URLSession.shared.download(from: remoteURL)
        try? FileManager.default.removeItem(at: storage.restoreIPSW)
        try FileManager.default.moveItem(at: temporaryURL, to: storage.restoreIPSW)
        print("Downloaded IPSW: \(storage.restoreIPSW.path)")
        return storage.restoreIPSW
    }

    private func latestRestoreImageURL() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.fetchLatestSupported { result in
                switch result {
                case .success(let image):
                    continuation.resume(returning: image.url)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func installBaseImage(from ipsw: URL) async throws {
        print("Installing base image from \(ipsw.path)")
        let requirements = try await restoreRequirements(from: ipsw)
        let hardwareModel = requirements.hardwareModel
        let machineIdentifier = VZMacMachineIdentifier()

        try createSparseDisk(at: storage.baseImage, sizeGB: config.diskSizeGB, overwrite: true)
        try hardwareModel.dataRepresentation.write(to: storage.hardwareModel)
        try machineIdentifier.dataRepresentation.write(to: storage.machineIdentifier)
        try? FileManager.default.removeItem(at: storage.auxiliaryStorage)

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = try VZMacAuxiliaryStorage(
            creatingStorageAt: storage.auxiliaryStorage,
            hardwareModel: hardwareModel
        )

        let vmConfig = try virtualMachineConfiguration(
            platform: platform,
            disk: storage.baseImage,
            minimumCPUCount: requirements.minimumSupportedCPUCount,
            minimumMemorySize: requirements.minimumSupportedMemorySize
        )

        let vm = VZVirtualMachine(configuration: vmConfig)
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
        var lastProgress = -1
        let observation = installer.progress.observe(\.fractionCompleted) { progress, _ in
            let percent = Int(progress.fractionCompleted * 100)
            if percent != lastProgress {
                lastProgress = percent
                print("Install progress: \(percent)%")
            }
        }
        defer { observation.invalidate() }

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

        print("Base image installed: \(storage.baseImage.path)")
    }

    private func restoreRequirements(from ipsw: URL) async throws -> VZMacOSConfigurationRequirements {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: ipsw) { result in
                switch result {
                case .success(let image):
                    guard let requirements = image.mostFeaturefulSupportedConfiguration else {
                        continuation.resume(throwing: SmokeError.unsupportedRestoreImage(ipsw))
                        return
                    }
                    continuation.resume(returning: requirements)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func bootSmoke() async throws {
        let disk = storage.disksDirectory.appendingPathComponent("smoke-\(UUID().uuidString).img")
        let sharedDir = storage.smokeSharedDirectory
        try "tarmac vm smoke\n".write(
            to: sharedDir.appendingPathComponent("README.txt"),
            atomically: true,
            encoding: .utf8
        )

        try cloneDisk(from: storage.baseImage, to: disk)
        defer { try? FileManager.default.removeItem(at: disk) }

        let platform = try existingPlatform()
        let vmConfig = try virtualMachineConfiguration(platform: platform, disk: disk, sharedDirectory: sharedDir)
        let vm = VZVirtualMachine(configuration: vmConfig)
        vm.delegate = self
        virtualMachine = vm

        print("Starting VM from clone \(disk.lastPathComponent)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.start { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }

        print("VM start succeeded.")
        if config.keepRunning {
            print("VM is running. Stop this process to end the smoke run.")
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(5))
            }
        } else {
            try await Task.sleep(for: .seconds(config.bootHoldSeconds))
            try await stop(vm)
            print("VM stopped cleanly.")
        }

        virtualMachine = nil
    }

    private func existingPlatform() throws -> VZMacPlatformConfiguration {
        guard
            let hardwareModelData = try? Data(contentsOf: storage.hardwareModel),
            let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData),
            let machineIdentifierData = try? Data(contentsOf: storage.machineIdentifier),
            let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIdentifierData),
            FileManager.default.fileExists(atPath: storage.auxiliaryStorage.path)
        else {
            throw SmokeError.missingPlatformData(storage.platformDirectory)
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: storage.auxiliaryStorage)
        return platform
    }

    private func virtualMachineConfiguration(
        platform: VZMacPlatformConfiguration,
        disk: URL,
        sharedDirectory: URL? = nil,
        minimumCPUCount: Int = VZVirtualMachineConfiguration.minimumAllowedCPUCount,
        minimumMemorySize: UInt64 = VZVirtualMachineConfiguration.minimumAllowedMemorySize
    ) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = min(
            max(config.cpuCount, minimumCPUCount),
            VZVirtualMachineConfiguration.maximumAllowedCPUCount
        )
        configuration.memorySize = min(
            max(UInt64(config.memoryGB) * 1024 * 1024 * 1024, minimumMemorySize),
            VZVirtualMachineConfiguration.maximumAllowedMemorySize
        )

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(widthInPixels: 1280, heightInPixels: 800, pixelsPerInch: 144)
        ]
        configuration.graphicsDevices = [graphics]

        if let sharedDirectory {
            let shared = VZSharedDirectory(url: sharedDirectory, readOnly: false)
            let share = VZSingleDirectoryShare(directory: shared)
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: "shared")
            fs.share = share
            configuration.directorySharingDevices = [fs]
        }

        try configuration.validate()
        return configuration
    }

    private func createSparseDisk(at url: URL, sizeGB: Int, overwrite: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if overwrite, fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw SmokeError.diskCreateFailed(url, errno)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let sizeBytes = Int64(sizeGB) * 1024 * 1024 * 1024
        guard ftruncate(handle.fileDescriptor, off_t(sizeBytes)) == 0 else {
            throw SmokeError.diskCreateFailed(url, errno)
        }
    }

    private func cloneDisk(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let result = source.path.withCString { src in
            destination.path.withCString { dst in
                Darwin.clonefile(src, dst, 0)
            }
        }

        if result != 0 {
            do {
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                throw SmokeError.cloneFailed(source, destination, errno)
            }
        }
    }

    private func stop(_ vm: VZVirtualMachine) async throws {
        guard vm.state != .stopped else { return }
        if vm.canRequestStop {
            try vm.requestStop()
            let deadline = Date().addingTimeInterval(30)
            while vm.state != .stopped, Date() < deadline {
                try await Task.sleep(for: .milliseconds(500))
            }
            if vm.state == .stopped {
                return
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.stop { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fputs("VM stopped with error: \(error.localizedDescription)\n", stderr)
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("Guest requested shutdown.")
    }
}
