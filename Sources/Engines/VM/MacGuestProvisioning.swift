import Foundation
import Security
import Virtualization

struct MacGuestProvisioningConfiguration: Equatable, Sendable {
    static let defaultFullName = "Tarmac Runner"
    static let defaultUsername = "tarmac"

    let fullName: String
    let username: String
    let password: String
    let logsInAutomatically: Bool
    let enablesRemoteLogin: Bool

    init(
        fullName: String = Self.defaultFullName,
        username: String = Self.defaultUsername,
        password: String,
        logsInAutomatically: Bool = true,
        enablesRemoteLogin: Bool = true
    ) {
        self.fullName = fullName
        self.username = username
        self.password = password
        self.logsInAutomatically = logsInAutomatically
        self.enablesRemoteLogin = enablesRemoteLogin
    }

    func makeStartOptions() throws -> VZMacOSVirtualMachineStartOptions {
        let provisioning = VZMacGuestProvisioningOptions()
        provisioning.fullName = fullName
        provisioning.username = username
        provisioning.password = password
        provisioning.logsInAutomatically = logsInAutomatically
        provisioning.enablesRemoteLogin = enablesRemoteLogin
        try provisioning.validate()

        let options = VZMacOSVirtualMachineStartOptions()
        try options.setGuestProvisioning(provisioning)
        return options
    }
}

struct MacGuestCredentialStore: Sendable {
    static let passwordKey = "vm.guest.tarmac.provisioning-password"

    let keychainService: any KeychainServiceProtocol

    func loadOrCreate() throws -> MacGuestProvisioningConfiguration {
        if let data = keychainService.load(key: Self.passwordKey),
            let password = String(data: data, encoding: .utf8),
            !password.isEmpty
        {
            return MacGuestProvisioningConfiguration(password: password)
        }

        let password = try Self.generatePassword()
        guard keychainService.save(key: Self.passwordKey, data: Data(password.utf8)) else {
            throw MacGuestProvisioningError.couldNotStorePassword
        }
        return MacGuestProvisioningConfiguration(password: password)
    }

    private static func generatePassword() throws -> String {
        var randomBytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes) == errSecSuccess else {
            throw MacGuestProvisioningError.couldNotGeneratePassword
        }

        let encoded = Data(randomBytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "T27-\(encoded)"
    }
}

enum MacOSRestoreCatalog {
    static let unattendedProvisioningMajorVersion = 27
    static let betaBuild = "26A5378n"
    static let betaRestoreURL = URL(
        string:
            "https://updates.cdn-apple.com/2026SummerSeed/fullrestores/140-37973/"
            + "1ACA049C-10F0-4F1D-8E38-E52B9168C4BC/UniversalMac_27.0_26A5378n_Restore.ipsw"
    )!

    static func preferredRestoreURL(
        latestSupportedURL: URL,
        latestSupportedVersion: OperatingSystemVersion
    ) -> URL {
        if latestSupportedVersion.majorVersion >= unattendedProvisioningMajorVersion {
            return latestSupportedURL
        }
        return betaRestoreURL
    }
}

enum DHCPLeaseParser {
    static func ipv4Address(in contents: String, macAddress: String) -> String? {
        let target = normalizedMACAddress(macAddress)
        for block in contents.components(separatedBy: "}") {
            var blockMACAddress: String?
            var blockIPAddress: String?

            for rawLine in block.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("hw_address=") {
                    let value = String(line.dropFirst("hw_address=".count))
                    blockMACAddress = normalizedMACAddress(
                        value.hasPrefix("1,") ? String(value.dropFirst(2)) : value
                    )
                } else if line.hasPrefix("ip_address=") {
                    blockIPAddress = String(line.dropFirst("ip_address=".count))
                }
            }

            if blockMACAddress == target, let blockIPAddress {
                return blockIPAddress
            }
        }
        return nil
    }

    private static func normalizedMACAddress(_ value: String) -> String {
        value.lowercased().split(separator: ":").map { component in
            guard let byte = UInt8(component, radix: 16) else { return String(component) }
            return String(format: "%02x", byte)
        }.joined(separator: ":")
    }
}

actor MacGuestBootstrapInstaller {
    private let leaseFileURL: URL

    init(leaseFileURL: URL = URL(fileURLWithPath: "/var/db/dhcpd_leases")) {
        self.leaseFileURL = leaseFileURL
    }

    @discardableResult
    func install(
        credentials: MacGuestProvisioningConfiguration,
        macAddress: String,
        timeoutSeconds: TimeInterval = 600
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastDetails = "Waiting for the guest DHCP lease."

        while Date() < deadline {
            try Task.checkCancellation()
            if let leases = try? String(contentsOf: leaseFileURL, encoding: .utf8),
                let ipAddress = DHCPLeaseParser.ipv4Address(in: leases, macAddress: macAddress)
            {
                let attempt = runBootstrapAttempt(ipAddress: ipAddress, credentials: credentials)
                if attempt.exitCode == 0 {
                    Log.vm.info("Installed guest bootstrap over the provisioning channel at \(ipAddress)")
                    return ipAddress
                }
                lastDetails = attempt.output
                Log.vm.debug(
                    "Guest provisioning attempt at \(ipAddress) exited \(attempt.exitCode): \(attempt.output, privacy: .public)"
                )
            }

            try await Task.sleep(for: .seconds(3))
        }

        throw MacGuestProvisioningError.bootstrapTimedOut(details: lastDetails)
    }

    private func runBootstrapAttempt(
        ipAddress: String,
        credentials: MacGuestProvisioningConfiguration
    ) -> (exitCode: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
        process.arguments = ["-c", Self.expectScript]
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["TARMAC_GUEST_PASSWORD"] = credentials.password
        environment["TARMAC_GUEST_IP_ADDRESS"] = ipAddress
        environment["TARMAC_GUEST_USERNAME"] = credentials.username
        process.environment = environment

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let details = String(data: data, encoding: .utf8) ?? "Guest bootstrap command failed."
            return (process.terminationStatus, details)
        } catch {
            return (127, error.localizedDescription)
        }
    }

    private static let expectScript = #"""
        set timeout 20
        set ip_address $env(TARMAC_GUEST_IP_ADDRESS)
        set username $env(TARMAC_GUEST_USERNAME)
        set password $env(TARMAC_GUEST_PASSWORD)
        log_user 0
        spawn /usr/bin/ssh \
            -o BatchMode=no \
            -o ConnectTimeout=5 \
            -o LogLevel=ERROR \
            -o NumberOfPasswordPrompts=2 \
            -o PreferredAuthentications=password \
            -o PubkeyAuthentication=no \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            "$username@$ip_address" \
            "sudo -S -p Password: '/Volumes/My Shared Files/install-tarmac-runner-bootstrap.sh' --runner-user '$username' --skip-auto-login"
        expect {
            -nocase -re "password:" {
                send -- "$password\r"
                exp_continue
            }
            timeout {
                exit 124
            }
            eof {}
        }
        set result [wait]
        exit [lindex $result 3]
        """#
}

enum MacGuestProvisioningError: LocalizedError {
    case couldNotGeneratePassword
    case couldNotStorePassword
    case missingNetworkAddress
    case bootstrapTimedOut(details: String)

    var errorDescription: String? {
        switch self {
        case .couldNotGeneratePassword:
            "Could not generate a secure guest provisioning password."
        case .couldNotStorePassword:
            "Could not store the guest provisioning password in Keychain."
        case .missingNetworkAddress:
            "The provisioned VM has no network address for bootstrap installation."
        case .bootstrapTimedOut(let details):
            "Timed out waiting for the provisioned macOS guest to accept its bootstrap. \(details)"
        }
    }
}
