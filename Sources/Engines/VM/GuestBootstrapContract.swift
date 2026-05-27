import Foundation

enum GuestBootstrapContract {
    static let sharedMountTag = "shared"
    static let sharedMountPoint = "/Volumes/tarmac-shared"

    static let runnerDirectoryName = "runner"
    static let runnerEntrypointName = "run.sh"
    static let jitConfigFileName = "jitconfig"

    static let appleSigningDirectoryName = "apple-signing"
    static let appleSigningCertificateFileName = "certificate.p12"
    static let appleSigningProvisioningProfileFileName = "profile.mobileprovision"
    static let appleSigningEnvironmentFileName = "signing-env"
    static let appleSigningImportScriptFileName = "import-signing-assets.sh"

    static let bootstrapLogFileName = "bootstrap.log"
    static let runnerLogFileName = "runner.log"
    static let exitCodeFileName = "exit-code"
    static let completionMarkerFileName = "completion.json"
    static let cacheEnvironmentFileName = "cache-env"

    static let warmRunnerJobDirectoryName = "_warm"
    static let warmModeFileName = "warm-mode"
    static let jobReadyFileName = "job-ready"
    static let warmShutdownFileName = "warm-shutdown"
}
