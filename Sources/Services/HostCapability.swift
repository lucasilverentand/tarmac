import Foundation
import Virtualization

/// Reports whether the host meets Tarmac's hard requirements:
/// Apple Silicon Mac running macOS 27 or later, with the
/// `Virtualization.framework` available.
struct HostCapability: Sendable {
    /// macOS 27 is required for unattended guest provisioning.
    static let minimumMajorVersion = 27

    let isVirtualizationSupported: Bool
    let isSupportedOSVersion: Bool
    let operatingSystemVersion: OperatingSystemVersion

    var isSupported: Bool {
        isVirtualizationSupported && isSupportedOSVersion
    }

    /// Issues that block the app from running. Empty when fully supported.
    var issues: [String] {
        var result: [String] = []
        if !isVirtualizationSupported {
            result.append(
                "This Mac does not support Apple's Virtualization framework. "
                    + "Tarmac requires an Apple Silicon Mac."
            )
        }
        if !isSupportedOSVersion {
            result.append(
                "Tarmac requires macOS \(Self.minimumMajorVersion) or later "
                    + "(running \(operatingSystemVersion.majorVersion)."
                    + "\(operatingSystemVersion.minorVersion))."
            )
        }
        return result
    }

    init(
        isVirtualizationSupported: Bool,
        operatingSystemVersion: OperatingSystemVersion
    ) {
        self.isVirtualizationSupported = isVirtualizationSupported
        self.operatingSystemVersion = operatingSystemVersion
        self.isSupportedOSVersion = operatingSystemVersion.majorVersion >= Self.minimumMajorVersion
    }

    /// Probes the live host.
    static func current(processInfo: ProcessInfo = .processInfo) -> HostCapability {
        HostCapability(
            isVirtualizationSupported: VZVirtualMachine.isSupported,
            operatingSystemVersion: processInfo.operatingSystemVersion
        )
    }

    /// Validates that a restore image supports unattended owner provisioning.
    static func isRestoreImageSupported(version: OperatingSystemVersion) -> Bool {
        version.majorVersion >= minimumMajorVersion
    }
}
