import Foundation

enum GuestBootstrapContract {
    static let verificationVersion = 2

    static let sharedMountTag = "shared"
    static let sharedMountPoint = "/Volumes/tarmac-shared"

    static let runnerDirectoryName = "runner"
    static let runnerEntrypointName = "run.sh"
    static let originalRunnerEntrypointName = "run-tarmac-original.sh"
    static let jitConfigFileName = "jitconfig"
    static let registrationTokenFileName = "registration-token"
    static let runnerURLFileName = "runner-url"
    static let runnerNameFileName = "runner-name"
    static let runnerLabelsFileName = "runner-labels"
    static let runnerProviderFileName = "runner-provider"

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
    static let workerResourceUsageFileName = "worker-resource-usage.json"
    static let workerResourceUsagePIDFileName = "worker-resource-usage.pid"
    static let interactiveSessionReadyFileName = "interactive-session-ready"

    static let warmRunnerJobDirectoryName = "_warm"
    static let warmModeFileName = "warm-mode"
    static let warmReadyFileName = "warm-ready"
    static let jobReadyFileName = "job-ready"
    static let warmShutdownFileName = "warm-shutdown"
}
