import Foundation
import Virtualization

/// Reports whether the host meets Tarmac's hard requirements:
/// Apple Silicon Mac running macOS 26 or later, with the
/// `Virtualization.framework` available.
struct HostCapability: Sendable {
    /// Minimum supported macOS host version. Mirrors the guest baseline.
    static let minimumMajorVersion = 26

    let isVirtualizationSupported: Bool
    let isMacOS26OrLater: Bool
    let operatingSystemVersion: OperatingSystemVersion

    var isSupported: Bool {
        isVirtualizationSupported && isMacOS26OrLater
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
        if !isMacOS26OrLater {
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
        self.isMacOS26OrLater = operatingSystemVersion.majorVersion >= Self.minimumMajorVersion
    }

    /// Probes the live host.
    static func current(processInfo: ProcessInfo = .processInfo) -> HostCapability {
        HostCapability(
            isVirtualizationSupported: VZVirtualMachine.isSupported,
            operatingSystemVersion: processInfo.operatingSystemVersion
        )
    }

    /// Validates that a restore image's guest OS meets the macOS 26 baseline.
    static func isRestoreImageSupported(version: OperatingSystemVersion) -> Bool {
        version.majorVersion >= minimumMajorVersion
    }
}
