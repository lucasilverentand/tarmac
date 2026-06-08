import Foundation

struct SharedDirectoryManager: Sendable {
    let baseDirectory: URL
    private let storage: StorageManager

    init(cacheDirectoryPath: String) {
        self.init(storage: StorageManager(rootPath: cacheDirectoryPath))
    }

    init(storage: StorageManager) {
        self.storage = storage
        self.baseDirectory = storage.rootDirectory
    }

    func prepareForJob(
        jobId: Int64,
        runnerPath: URL,
        guestConfig: RunnerGuestConfig,
        signingInjection: AppleSigningInjection? = nil
    ) throws -> URL {
        let jobDir = jobDirectory(for: jobId)
        let fm = FileManager.default

        try validateRunner(at: runnerPath, fileManager: fm)
        try validateGuestConfig(guestConfig)

        if fm.fileExists(atPath: jobDir.path) {
            try fm.removeItem(at: jobDir)
        }
        try fm.createDirectory(at: jobDir, withIntermediateDirectories: true)
        try allowGuestWrites(to: jobDir, fileManager: fm)

        let runnerDestination = jobDir.appendingPathComponent(GuestBootstrapContract.runnerDirectoryName)
        try fm.copyItem(at: runnerPath, to: runnerDestination)
        try writeGuestConfig(guestConfig, in: jobDir, fileManager: fm)
        try precreateGuestWritableResultFiles(in: jobDir, fileManager: fm)

        if let signingInjection {
            try writeSigningInjection(signingInjection, in: jobDir, fileManager: fm)
        }

        try fm.createDirectory(at: storage.actionsCacheDirectory, withIntermediateDirectories: true)
        try allowGuestWrites(to: storage.actionsCacheDirectory, fileManager: fm)

        Log.vm.info("Shared directory prepared for job \(jobId) at \(jobDir.path)")
        return jobDir
    }

    func cleanupJob(jobId: Int64) throws {
        let jobDir = jobDirectory(for: jobId)
        guard FileManager.default.fileExists(atPath: jobDir.path) else { return }
        try FileManager.default.removeItem(at: jobDir)
        Log.vm.info("Cleaned up shared directory for job \(jobId)")
    }

    var warmRunnerDirectory: URL {
        jobsDirectory.appendingPathComponent(GuestBootstrapContract.warmRunnerJobDirectoryName, isDirectory: true)
    }

    func prepareWarmRunnerJob(
        jobId: Int64,
        runnerPath: URL,
        guestConfig: RunnerGuestConfig,
        signingInjection: AppleSigningInjection? = nil
    ) throws -> URL {
        let jobDir = warmRunnerDirectory
        let fm = FileManager.default

        try validateRunner(at: runnerPath, fileManager: fm)
        try validateGuestConfig(guestConfig)

        try fm.createDirectory(at: jobDir, withIntermediateDirectories: true)
        try allowGuestWrites(to: jobDir, fileManager: fm)
        try clearWarmRunnerJobArtifacts(in: jobDir, fileManager: fm)

        let runnerDestination = jobDir.appendingPathComponent(GuestBootstrapContract.runnerDirectoryName)
        if fm.fileExists(atPath: runnerDestination.path) {
            try fm.removeItem(at: runnerDestination)
        }
        try fm.copyItem(at: runnerPath, to: runnerDestination)
        try writeGuestConfig(guestConfig, in: jobDir, fileManager: fm)
        try precreateGuestWritableResultFiles(in: jobDir, fileManager: fm)

        if let signingInjection {
            try writeSigningInjection(signingInjection, in: jobDir, fileManager: fm)
        } else {
            let signingDir = jobDir.appendingPathComponent(
                GuestBootstrapContract.appleSigningDirectoryName,
                isDirectory: true
            )
            if fm.fileExists(atPath: signingDir.path) {
                try fm.removeItem(at: signingDir)
            }
        }

        try fm.createDirectory(at: storage.actionsCacheDirectory, withIntermediateDirectories: true)
        try allowGuestWrites(to: storage.actionsCacheDirectory, fileManager: fm)

        Log.vm.info("Warm runner shared directory prepared for job \(jobId) at \(jobDir.path)")
        return jobDir
    }

    func enableWarmMode(in directory: URL) throws {
        let warmModeURL = directory.appendingPathComponent(GuestBootstrapContract.warmModeFileName)
        try "1\n".write(to: warmModeURL, atomically: true, encoding: .utf8)
    }

    func signalJobReady(in directory: URL) throws {
        let jobReadyURL = directory.appendingPathComponent(GuestBootstrapContract.jobReadyFileName)
        let fm = FileManager.default
        if fm.fileExists(atPath: jobReadyURL.path) {
            try fm.removeItem(at: jobReadyURL)
        }
        fm.createFile(atPath: jobReadyURL.path, contents: Data())
    }

    func requestWarmShutdown(in directory: URL) throws {
        let shutdownURL = directory.appendingPathComponent(GuestBootstrapContract.warmShutdownFileName)
        let fm = FileManager.default
        if fm.fileExists(atPath: shutdownURL.path) {
            try fm.removeItem(at: shutdownURL)
        }
        fm.createFile(atPath: shutdownURL.path, contents: Data())
    }

    func clearWarmRunnerJobArtifacts(in directory: URL, fileManager: FileManager = .default) throws {
        for fileName in [
            GuestBootstrapContract.completionMarkerFileName,
            GuestBootstrapContract.exitCodeFileName,
            GuestBootstrapContract.jobReadyFileName,
            GuestBootstrapContract.warmShutdownFileName,
        ] {
            let url = directory.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: - Paths

    private var jobsDirectory: URL {
        storage.jobsDirectory
    }

    private func jobDirectory(for jobId: Int64) -> URL {
        jobsDirectory.appendingPathComponent("\(jobId)")
    }

    var cacheDirectory: URL {
        storage.actionsCacheDirectory
    }

    private func validateGuestConfig(_ guestConfig: RunnerGuestConfig) throws {
        switch guestConfig {
        case .jit(let config):
            guard !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SharedDirectoryError.emptyJITConfig
            }
        case .registrationToken(let url, let token, let runnerName, let labels):
            guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SharedDirectoryError.incompleteRegistrationConfig
            }
            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SharedDirectoryError.incompleteRegistrationConfig
            }
            guard !runnerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SharedDirectoryError.incompleteRegistrationConfig
            }
            guard !labels.isEmpty else {
                throw SharedDirectoryError.incompleteRegistrationConfig
            }
        }
    }

    private func writeGuestConfig(
        _ guestConfig: RunnerGuestConfig,
        in jobDir: URL,
        fileManager fm: FileManager
    ) throws {
        let jitConfigPath = jobDir.appendingPathComponent(GuestBootstrapContract.jitConfigFileName)
        let registrationTokenPath = jobDir.appendingPathComponent(GuestBootstrapContract.registrationTokenFileName)
        let runnerURLPath = jobDir.appendingPathComponent(GuestBootstrapContract.runnerURLFileName)
        let runnerNamePath = jobDir.appendingPathComponent(GuestBootstrapContract.runnerNameFileName)
        let runnerLabelsPath = jobDir.appendingPathComponent(GuestBootstrapContract.runnerLabelsFileName)

        for path in [jitConfigPath, registrationTokenPath, runnerURLPath, runnerNamePath, runnerLabelsPath] {
            if fm.fileExists(atPath: path.path) {
                try fm.removeItem(at: path)
            }
        }

        switch guestConfig {
        case .jit(let config):
            try config.write(to: jitConfigPath, atomically: true, encoding: .utf8)
        case .registrationToken(let url, let token, let runnerName, let labels):
            try token.write(to: registrationTokenPath, atomically: true, encoding: .utf8)
            try url.write(to: runnerURLPath, atomically: true, encoding: .utf8)
            try runnerName.write(to: runnerNamePath, atomically: true, encoding: .utf8)
            try labels.joined(separator: ",").write(to: runnerLabelsPath, atomically: true, encoding: .utf8)
        }
    }

    private func validateRunner(at runnerPath: URL, fileManager fm: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: runnerPath.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SharedDirectoryError.missingRunnerPackage(runnerPath)
        }

        let runScript = runnerPath.appendingPathComponent(GuestBootstrapContract.runnerEntrypointName)
        guard fm.fileExists(atPath: runScript.path) else {
            throw SharedDirectoryError.missingRunnerEntrypoint(runScript)
        }
        guard fm.isExecutableFile(atPath: runScript.path) else {
            throw SharedDirectoryError.runnerEntrypointNotExecutable(runScript)
        }
    }

    private func allowGuestWrites(to directory: URL, fileManager fm: FileManager) throws {
        try fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
    }

    private func precreateGuestWritableResultFiles(in directory: URL, fileManager fm: FileManager) throws {
        for fileName in [
            GuestBootstrapContract.bootstrapLogFileName,
            GuestBootstrapContract.runnerLogFileName,
        ] {
            let url = directory.appendingPathComponent(fileName)
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            fm.createFile(atPath: url.path, contents: Data())
            try fm.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
        }
    }

    private func writeSigningInjection(
        _ injection: AppleSigningInjection,
        in jobDir: URL,
        fileManager fm: FileManager
    ) throws {
        guard !injection.certificateData.isEmpty else {
            throw SharedDirectoryError.emptySigningCertificate
        }
        guard !injection.certificatePassphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SharedDirectoryError.emptySigningPassphrase
        }
        guard !injection.provisioningProfileData.isEmpty else {
            throw SharedDirectoryError.emptyProvisioningProfile
        }

        let signingDir = jobDir.appendingPathComponent(
            GuestBootstrapContract.appleSigningDirectoryName,
            isDirectory: true
        )
        try fm.createDirectory(at: signingDir, withIntermediateDirectories: true)

        let certificateURL = signingDir.appendingPathComponent(
            GuestBootstrapContract.appleSigningCertificateFileName
        )
        let profileURL = signingDir.appendingPathComponent(
            GuestBootstrapContract.appleSigningProvisioningProfileFileName
        )
        let environmentURL = signingDir.appendingPathComponent(
            GuestBootstrapContract.appleSigningEnvironmentFileName
        )
        let scriptURL = signingDir.appendingPathComponent(
            GuestBootstrapContract.appleSigningImportScriptFileName
        )

        try injection.certificateData.write(to: certificateURL, options: .atomic)
        try injection.provisioningProfileData.write(to: profileURL, options: .atomic)
        try signingEnvironment(for: injection).write(to: environmentURL, atomically: true, encoding: .utf8)
        try signingImportScript().write(to: scriptURL, atomically: true, encoding: .utf8)

        for url in [certificateURL, profileURL, environmentURL] {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
    }

    private func signingEnvironment(for injection: AppleSigningInjection) -> String {
        let asset = injection.asset
        let profileInstallName =
            asset.provisioningProfileUUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(asset.id.uuidString).mobileprovision"
            : "\(asset.provisioningProfileUUID).mobileprovision"
        let signingDir = [
            GuestBootstrapContract.sharedMountPoint,
            GuestBootstrapContract.appleSigningDirectoryName,
        ].joined(separator: "/")
        let certificatePath = "\(signingDir)/\(GuestBootstrapContract.appleSigningCertificateFileName)"
        let profilePath =
            "\(signingDir)/\(GuestBootstrapContract.appleSigningProvisioningProfileFileName)"
        let profileInstallPath = "/var/root/Library/MobileDevice/Provisioning Profiles/\(profileInstallName)"

        return """
            export TARMAC_APPLE_SIGNING_DIR=\(shellQuoted(signingDir))
            export TARMAC_APPLE_CERTIFICATE_PATH=\(shellQuoted(certificatePath))
            export TARMAC_APPLE_PROVISIONING_PROFILE_PATH=\(shellQuoted(profilePath))
            export TARMAC_APPLE_CERTIFICATE_PASSPHRASE=\(shellQuoted(injection.certificatePassphrase))
            export TARMAC_APPLE_KEYCHAIN_PASSWORD=\(shellQuoted(UUID().uuidString))
            export TARMAC_APPLE_KEYCHAIN_PATH=\(shellQuoted("/tmp/tarmac-apple-signing-\(asset.id.uuidString).keychain-db"))
            export TARMAC_APPLE_TEAM_ID=\(shellQuoted(asset.teamId))
            export TARMAC_APPLE_BUNDLE_IDENTIFIER_PATTERN=\(shellQuoted(asset.bundleIdentifierPattern))
            export TARMAC_APPLE_CERTIFICATE_COMMON_NAME=\(shellQuoted(asset.certificateCommonName))
            export TARMAC_APPLE_PROVISIONING_PROFILE_UUID=\(shellQuoted(asset.provisioningProfileUUID))
            export TARMAC_APPLE_PROVISIONING_PROFILE_INSTALL_PATH=\(shellQuoted(profileInstallPath))
            """
    }

    private func signingImportScript() -> String {
        """
        #!/bin/bash
        set -u -o pipefail

        : "${TARMAC_APPLE_SIGNING_DIR:=\(GuestBootstrapContract.sharedMountPoint)/\(GuestBootstrapContract.appleSigningDirectoryName)}"

        if [[ -f "${TARMAC_APPLE_SIGNING_DIR}/\(GuestBootstrapContract.appleSigningEnvironmentFileName)" ]]; then
            # shellcheck disable=SC1090
            . "${TARMAC_APPLE_SIGNING_DIR}/\(GuestBootstrapContract.appleSigningEnvironmentFileName)"
        fi

        cleanup_apple_signing() {
            if [[ -n "${TARMAC_APPLE_PROVISIONING_PROFILE_INSTALL_PATH:-}" ]]; then
                /bin/rm -f "${TARMAC_APPLE_PROVISIONING_PROFILE_INSTALL_PATH}" >/dev/null 2>&1 || true
            fi
            if [[ -n "${TARMAC_APPLE_KEYCHAIN_PATH:-}" ]]; then
                /usr/bin/security delete-keychain "${TARMAC_APPLE_KEYCHAIN_PATH}" >/dev/null 2>&1 || true
            fi
            if [[ -n "${TARMAC_APPLE_SIGNING_DIR:-}" ]]; then
                /bin/rm -rf "${TARMAC_APPLE_SIGNING_DIR}" >/dev/null 2>&1 || true
            fi
        }

        trap cleanup_apple_signing EXIT HUP INT TERM

        /usr/bin/security create-keychain -p "${TARMAC_APPLE_KEYCHAIN_PASSWORD}" "${TARMAC_APPLE_KEYCHAIN_PATH}"
        /usr/bin/security unlock-keychain -p "${TARMAC_APPLE_KEYCHAIN_PASSWORD}" "${TARMAC_APPLE_KEYCHAIN_PATH}"
        /usr/bin/security set-keychain-settings -lut 21600 "${TARMAC_APPLE_KEYCHAIN_PATH}"
        /usr/bin/security import "${TARMAC_APPLE_CERTIFICATE_PATH}" \\
            -k "${TARMAC_APPLE_KEYCHAIN_PATH}" \\
            -P "${TARMAC_APPLE_CERTIFICATE_PASSPHRASE}" \\
            -T /usr/bin/codesign \\
            -T /usr/bin/security
        /usr/bin/security set-key-partition-list \\
            -S apple-tool:,apple:,codesign: \\
            -s \\
            -k "${TARMAC_APPLE_KEYCHAIN_PASSWORD}" \\
            "${TARMAC_APPLE_KEYCHAIN_PATH}"

        /bin/mkdir -p "$(/usr/bin/dirname "${TARMAC_APPLE_PROVISIONING_PROFILE_INSTALL_PATH}")"
        /bin/cp "${TARMAC_APPLE_PROVISIONING_PROFILE_PATH}" "${TARMAC_APPLE_PROVISIONING_PROFILE_INSTALL_PATH}"

        export TARMAC_APPLE_SIGNING_CONFIGURED=1
        """
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum SharedDirectoryError: LocalizedError {
    case missingRunnerPackage(URL)
    case missingRunnerEntrypoint(URL)
    case runnerEntrypointNotExecutable(URL)
    case emptyJITConfig
    case incompleteRegistrationConfig
    case emptySigningCertificate
    case emptySigningPassphrase
    case emptyProvisioningProfile

    var errorDescription: String? {
        switch self {
        case .missingRunnerPackage(let url):
            "Runner package is missing at \(url.path)"
        case .missingRunnerEntrypoint(let url):
            "Runner package is missing \(url.lastPathComponent) at \(url.path)"
        case .runnerEntrypointNotExecutable(let url):
            "Runner entrypoint is not executable at \(url.path)"
        case .emptyJITConfig:
            "JIT configuration is empty"
        case .incompleteRegistrationConfig:
            "Registration token runner configuration is incomplete"
        case .emptySigningCertificate:
            "Apple signing certificate is empty"
        case .emptySigningPassphrase:
            "Apple signing certificate passphrase is empty"
        case .emptyProvisioningProfile:
            "Apple provisioning profile is empty"
        }
    }
}
