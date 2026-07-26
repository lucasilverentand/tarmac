import Foundation
import Testing

@testable import Tarmac

@Suite("Guest bootstrap resources")
struct GuestBootstrapResourceTests {
    @Test("bootstrap resources are present and executable")
    func resourcesArePresentAndExecutable() throws {
        let resources = resourceDirectory()
        let bootstrap = resources.appendingPathComponent("tarmac-runner-bootstrap.sh")
        let installer = resources.appendingPathComponent("install-tarmac-runner-bootstrap.sh")
        let plist = resources.appendingPathComponent("studio.seventwo.tarmac.runner-bootstrap.plist")

        #expect(FileManager.default.isExecutableFile(atPath: bootstrap.path))
        #expect(FileManager.default.isExecutableFile(atPath: installer.path))
        #expect(FileManager.default.fileExists(atPath: plist.path))
    }

    @Test("launch daemon points at installed bootstrap")
    func launchDaemonPointsAtBootstrap() throws {
        let plist = resourceDirectory()
            .appendingPathComponent("studio.seventwo.tarmac.runner-bootstrap.plist")
        let data = try Data(contentsOf: plist)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dictionary = try #require(object as? [String: Any])

        #expect(dictionary["Label"] as? String == "studio.seventwo.tarmac.runner-bootstrap")
        #expect(dictionary["RunAtLoad"] as? Bool == true)

        let arguments = try #require(dictionary["ProgramArguments"] as? [String])
        #expect(arguments == ["/usr/local/libexec/tarmac-runner-bootstrap"])
    }

    @Test("bootstrap script implements runner contract")
    func bootstrapScriptImplementsContract() throws {
        let script = resourceDirectory().appendingPathComponent("tarmac-runner-bootstrap.sh")
        let contents = try String(contentsOf: script, encoding: .utf8)

        #expect(contents.contains("SHARED_TAG=\"\(GuestBootstrapContract.sharedMountTag)\""))
        #expect(contents.contains("SHARED_MOUNT=\"\(GuestBootstrapContract.sharedMountPoint)\""))
        #expect(contents.contains("CACHE_TAG=\"\(CacheConfiguration.guestMountTag)\""))
        #expect(contents.contains("CACHE_MOUNT=\"\(CacheConfiguration.guestMountPoint)\""))
        #expect(
            contents.contains("CACHE_ENV_FILE=\"${SHARED_MOUNT}/\(GuestBootstrapContract.cacheEnvironmentFileName)\"")
        )
        #expect(contents.contains("TARMAC_ACTIONS_CACHE"))
        #expect(contents.contains("TARMAC_SWIFTPM_CACHE_PATH"))
        #expect(!contents.contains("TARMAC_XCODE_DERIVED_DATA_PATH"))
        #expect(contents.contains("TARMAC_COCOAPODS_CACHE_PATH"))
        #expect(contents.contains("TARMAC_FLUTTER_PUB_CACHE_PATH"))
        #expect(contents.contains("PUB_CACHE"))
        #expect(contents.contains("NPM_CONFIG_CACHE"))
        #expect(contents.contains("TARMAC_YARN_CACHE_PATH"))
        #expect(contents.contains("TARMAC_PNPM_STORE_PATH"))
        #expect(contents.contains("TARMAC_BUN_INSTALL_CACHE_PATH"))
        #expect(contents.contains("SIGNING_IMPORT_SCRIPT_FILE"))
        #expect(contents.contains(GuestBootstrapContract.appleSigningDirectoryName))
        #expect(contents.contains(GuestBootstrapContract.appleSigningImportScriptFileName))
        #expect(contents.contains("configure_apple_signing"))
        #expect(contents.contains("Ephemeral Apple signing assets"))
        for target in CacheConfiguration.guestCacheTargets {
            #expect(contents.contains(target.directoryName))
            #expect(contents.contains(target.environmentVariable))
        }
        #expect(contents.contains("/sbin/mount_virtiofs"))
        #expect(!contents.contains("/sbin/mount_virtiofs -u root -g wheel"))
        #expect(contents.contains("while [[ \"${attempt}\" -le 30 ]]"))
        #expect(!contents.contains("/usr/bin/seq"))
        #expect(contents.contains("./run.sh --jitconfig"))
        #expect(contents.contains("registration-token"))
        #expect(contents.contains("./config.sh"))
        #expect(contents.contains("--unattended"))
        #expect(contents.contains("./act_runner register"))
        #expect(contents.contains("--no-interactive"))
        #expect(contents.contains("--ephemeral"))
        #expect(contents.contains("runner-provider"))
        #expect(contents.contains("rm -f \"${SHARED_MOUNT}/registration-token\""))
        #expect(contents.contains("rm -f \"${SHARED_MOUNT}/runner/.runner\""))
        #expect(contents.contains("bootstrap.log"))
        #expect(contents.contains("runner.log"))
        #expect(contents.contains("exit-code"))
        #expect(contents.contains("completion.json"))
        #expect(contents.contains("RUNNER_USER=\"tarmac\""))
        #expect(contents.contains("next_available_runner_uid"))
        #expect(contents.contains("wait_for_interactive_session"))
        #expect(contents.contains("configure_seeded_interactive_session"))
        #expect(contents.contains("tarmac-runner-autologin-password"))
        #expect(contents.contains("rm -f \"${AUTO_LOGIN_PASSWORD_FILE}\""))
        #expect(contents.contains("killall loginwindow"))
        #expect(contents.contains(GuestBootstrapContract.interactiveSessionReadyFileName))
        #expect(contents.contains("/dev/console"))
        #expect(contents.contains("ensure_local_cache_dirs"))
        #expect(contents.contains("repairing runner ownership"))
        #expect(contents.contains("${RUNNER_HOME}/Library/Caches/org.swift.swiftpm"))
        #expect(contents.contains("${RUNNER_HOME}/.cache/clang/ModuleCache"))
        #expect(contents.contains("/sbin/shutdown -h now"))
        #expect(contents.contains("run_warm_loop"))
        #expect(contents.contains("warm-mode"))
        #expect(contents.contains("warm-ready"))
        #expect(contents.contains("job-ready"))
        #expect(contents.contains("warm-shutdown"))
        #expect(contents.contains("TARMAC_SKIP_SHUTDOWN=1"))
    }

    @Test("installer configures persistent interactive login")
    func installerConfiguresInteractiveLogin() throws {
        let installer = resourceDirectory().appendingPathComponent("install-tarmac-runner-bootstrap.sh")
        let contents = try String(contentsOf: installer, encoding: .utf8)

        #expect(contents.contains("TARMAC_RUNNER_PASSWORD"))
        #expect(contents.contains("-autologin set"))
        #expect(contents.contains("autoLoginUser"))
        #expect(contents.contains("/etc/kcpassword"))
        #expect(contents.contains("FileVault is On"))
        #expect(contents.contains("askForPassword -int 0"))
        #expect(contents.contains("pmset -a sleep 0 displaysleep 0 disksleep 0"))
        #expect(contents.contains("--skip-auto-login"))
        #expect(!contents.contains("RUNNER_PASSWORD=\"tarmac\""))
    }

    @Test("offline injector preserves Setup Assistant ownership")
    func offlineInjectorRequiresExistingOwner() throws {
        let script = resourceDirectory()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("script/install_guest_bootstrap_offline.sh")
        let contents = try String(contentsOf: script, encoding: .utf8)

        #expect(contents.contains("No local macOS owner account exists"))
        #expect(contents.contains("PlistBuddy"))
        #expect(!contents.contains("touch \"$data_mount/private/var/db/.AppleSetupDone\""))
    }

    private func resourceDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/GuestBootstrap")
    }
}
