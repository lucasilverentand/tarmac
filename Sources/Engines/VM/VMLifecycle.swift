import Foundation
import Virtualization

@MainActor
final class VMLifecycle: NSObject, VMLifecycleProtocol, VZVirtualMachineDelegate, Sendable {
    private var vm: VZVirtualMachine?
    private var stateChangeContinuation: CheckedContinuation<Void, Error>?

    var isBooted: Bool { vm?.state == .running }
    private(set) var networkMACAddress: String?

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

    func bootProvisionedVM(
        vmConfig: VMConfiguration,
        diskPath: URL,
        platformStore: PlatformDataStore,
        sharedDirectoryURL: URL,
        provisioning: MacGuestProvisioningConfiguration
    ) async throws {
        let configuration = try createConfiguration(
            vmConfig: vmConfig,
            diskPath: diskPath,
            platformStore: platformStore,
            sharedDirectoryURL: sharedDirectoryURL,
            cacheDirectoryURL: nil
        )
        _ = try await boot(configuration: configuration, provisioning: provisioning)
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
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(
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
        let macAddress = VZMACAddress.randomLocallyAdministered()
        network.macAddress = macAddress
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]
        networkMACAddress = macAddress.string

        // Shared directories via VirtioFS
        var fsDevices: [VZVirtioFileSystemDeviceConfiguration] = []

        if let sharedDirURL = sharedDirectoryURL {
            let sharedDir = VZSharedDirectory(url: sharedDirURL, readOnly: false)
            let share = VZSingleDirectoryShare(directory: sharedDir)
            let fsDevice = VZVirtioFileSystemDeviceConfiguration(
                tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
            )
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

        VMInputDeviceConfigurator.attachInteractiveDevices(to: configuration)

        try configuration.validate()
        Log.vm.info("VM configuration created and validated")
        return configuration
    }

    func boot(
        configuration: VZVirtualMachineConfiguration,
        provisioning: MacGuestProvisioningConfiguration? = nil
    ) async throws -> VZVirtualMachine {
        let virtualMachine = VZVirtualMachine(configuration: configuration)
        virtualMachine.delegate = self
        do {
            self.vm = virtualMachine

            if let provisioning {
                let options = try provisioning.makeStartOptions()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    virtualMachine.start(options: options) { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            } else {
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
            }

            VMDisplaySource.shared.publish(vm: virtualMachine, label: "Runner VM")
            Log.vm.info("VM booted successfully")
            return virtualMachine
        } catch {
            self.vm = nil
            VMDisplaySource.shared.clear()
            throw error
        }
    }

    func stop(vm: VZVirtualMachine) async throws {
        // The guest bootstrap normally shuts macOS down as soon as it writes its
        // completion record. Treat that as a successful stop instead of trying
        // to force an already-stopped VZVirtualMachine through an invalid state
        // transition.
        if vm.state == .stopped {
            self.vm = nil
            VMDisplaySource.shared.clear()
            Log.vm.info("VM already stopped by guest")
            return
        }

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
        VMDisplaySource.shared.clear()
        Log.vm.info("VM stopped")
    }

    // MARK: - VZVirtualMachineDelegate

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in
            VMDisplaySource.shared.clear()
            Log.vm.error("VM stopped with error: \(error.localizedDescription)")
        }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            VMDisplaySource.shared.clear()
            Log.vm.info("Guest initiated shutdown")
        }
    }

    // MARK: - Private

    private func forceStop(vm: VZVirtualMachine) async throws {
        if vm.state == .stopped {
            self.vm = nil
            VMDisplaySource.shared.clear()
            return
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
        self.vm = nil
        VMDisplaySource.shared.clear()
        Log.vm.info("VM force-stopped")
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
