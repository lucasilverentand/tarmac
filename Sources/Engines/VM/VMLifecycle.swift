import Foundation
import Virtualization

@MainActor
final class VMLifecycle: NSObject, VMLifecycleProtocol, VZVirtualMachineDelegate, Sendable {
    private var vm: VZVirtualMachine?
    private var stateChangeContinuation: CheckedContinuation<Void, Error>?

    var isBooted: Bool { vm?.state == .running }

    func bootVM(
        vmConfig: VMConfiguration,
        diskPath: URL,
        platformStore: PlatformDataStore,
        sharedDirectoryURL: URL?,
        cacheDirectoryURL: URL?
    ) async throws {
        let configuration = try createConfiguration(
            vmConfig: vmConfig,
            diskPath: diskPath,
            platformStore: platformStore,
            sharedDirectoryURL: sharedDirectoryURL,
            cacheDirectoryURL: cacheDirectoryURL
        )
        _ = try await boot(configuration: configuration)
    }

    func stopVM() async throws {
        guard let vm else { return }
        try await stop(vm: vm)
    }

    func createConfiguration(
        vmConfig: VMConfiguration,
        diskPath: URL,
        platformStore: PlatformDataStore,
        sharedDirectoryURL: URL?,
        cacheDirectoryURL: URL? = nil
    ) throws -> VZVirtualMachineConfiguration {
        guard let hardwareModelData = platformStore.loadHardwareModel(),
            let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData)
        else {
            throw VMLifecycleError.missingHardwareModel
        }

        guard let machineIdData = platformStore.loadMachineIdentifier(),
            let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIdData)
        else {
            throw VMLifecycleError.missingMachineIdentifier
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = try VZMacAuxiliaryStorage(
            url: platformStore.auxiliaryStoragePath
        )

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = min(vmConfig.cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        configuration.memorySize = min(vmConfig.memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        // Disk
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskPath, readOnly: false)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]

        // Network
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]

        // Shared directories via VirtioFS
        var fsDevices: [VZVirtioFileSystemDeviceConfiguration] = []

        if let sharedDirURL = sharedDirectoryURL {
            let sharedDir = VZSharedDirectory(url: sharedDirURL, readOnly: false)
            let share = VZSingleDirectoryShare(directory: sharedDir)
            let fsDevice = VZVirtioFileSystemDeviceConfiguration(tag: "shared")
            fsDevice.share = share
            fsDevices.append(fsDevice)
        }

        if let cacheDirURL = cacheDirectoryURL {
            let cacheDir = VZSharedDirectory(url: cacheDirURL, readOnly: false)
            let cacheShare = VZSingleDirectoryShare(directory: cacheDir)
            let cacheDevice = VZVirtioFileSystemDeviceConfiguration(tag: CacheConfiguration.guestMountTag)
            cacheDevice.share = cacheShare
            fsDevices.append(cacheDevice)
        }

        configuration.directorySharingDevices = fsDevices

        // Graphics
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: 1920,
                heightInPixels: 1080,
                pixelsPerInch: 144
            )
        ]
        configuration.graphicsDevices = [graphics]

        try configuration.validate()
        Log.vm.info("VM configuration created and validated")
        return configuration
    }

    func boot(configuration: VZVirtualMachineConfiguration) async throws -> VZVirtualMachine {
        let virtualMachine = VZVirtualMachine(configuration: configuration)
        virtualMachine.delegate = self
        self.vm = virtualMachine

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            virtualMachine.start { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }

        Log.vm.info("VM booted successfully")
        return virtualMachine
    }

    func stop(vm: VZVirtualMachine) async throws {
        guard vm.canRequestStop else {
            Log.vm.warning("VM cannot request stop, forcing stop")
            try await forceStop(vm: vm)
            return
        }

        try vm.requestStop()
        Log.vm.info("Stop requested, waiting for VM to shut down...")

        // Wait up to 30 seconds for graceful shutdown
        let deadline = Date().addingTimeInterval(30)
        while vm.state != .stopped, Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
        }

        if vm.state != .stopped {
            Log.vm.warning("VM did not stop gracefully, forcing stop")
            try await forceStop(vm: vm)
        }

        self.vm = nil
        Log.vm.info("VM stopped")
    }

    // MARK: - VZVirtualMachineDelegate

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in
            Log.vm.error("VM stopped with error: \(error.localizedDescription)")
        }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            Log.vm.info("Guest initiated shutdown")
        }
    }

    // MARK: - Private

    private func forceStop(vm: VZVirtualMachine) async throws {
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
}

enum VMLifecycleError: LocalizedError {
    case missingHardwareModel
    case missingMachineIdentifier

    var errorDescription: String? {
        switch self {
        case .missingHardwareModel:
            "No saved hardware model found. Create a base image first."
        case .missingMachineIdentifier:
            "No saved machine identifier found. Create a base image first."
        }
    }
}
