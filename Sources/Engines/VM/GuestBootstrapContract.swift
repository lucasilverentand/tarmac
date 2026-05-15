import Foundation

enum GuestBootstrapContract {
    static let sharedMountTag = "shared"
    static let sharedMountPoint = "/Volumes/tarmac-shared"

    static let runnerDirectoryName = "runner"
    static let runnerEntrypointName = "run.sh"
    static let jitConfigFileName = "jitconfig"

    static let bootstrapLogFileName = "bootstrap.log"
    static let runnerLogFileName = "runner.log"
    static let exitCodeFileName = "exit-code"
}
