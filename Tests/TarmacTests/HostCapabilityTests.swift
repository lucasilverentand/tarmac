import Foundation
import Testing

@testable import Tarmac

@Suite("HostCapability")
struct HostCapabilityTests {
    @Test("Supported when Apple Silicon and macOS 26+")
    func supportedHost() {
        let host = HostCapability(
            isVirtualizationSupported: true,
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
        #expect(host.isSupported)
        #expect(host.issues.isEmpty)
    }

    @Test("Reports virtualization issue on unsupported hardware")
    func reportsVirtualizationIssue() {
        let host = HostCapability(
            isVirtualizationSupported: false,
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        )
        #expect(!host.isSupported)
        #expect(host.issues.contains { $0.contains("Virtualization") })
    }

    @Test("Reports macOS version issue when host is older than 26")
    func reportsMacOSVersionIssue() {
        let host = HostCapability(
            isVirtualizationSupported: true,
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 5, patchVersion: 0)
        )
        #expect(!host.isSupported)
        #expect(host.issues.contains { $0.contains("macOS 26") })
    }

    @Test("Reports both issues when host is Intel and older macOS")
    func reportsBothIssues() {
        let host = HostCapability(
            isVirtualizationSupported: false,
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        )
        #expect(!host.isSupported)
        #expect(host.issues.count == 2)
    }

    @Test("Restore image gating accepts macOS 26+")
    func restoreImageAcceptsMacOS26() {
        let version = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 1)
        #expect(HostCapability.isRestoreImageSupported(version: version))
    }

    @Test("Restore image gating rejects pre-macOS 26 images")
    func restoreImageRejectsOlder() {
        let version = OperatingSystemVersion(majorVersion: 15, minorVersion: 5, patchVersion: 0)
        #expect(!HostCapability.isRestoreImageSupported(version: version))
    }
}
