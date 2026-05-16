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
        #expect(contents.contains("TARMAC_XCODE_DERIVED_DATA_PATH"))
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
        #expect(contents.contains("./run.sh --jitconfig"))
        #expect(contents.contains("bootstrap.log"))
        #expect(contents.contains("runner.log"))
        #expect(contents.contains("exit-code"))
        #expect(contents.contains("completion.json"))
        #expect(contents.contains("/sbin/shutdown -h now"))
    }

    private func resourceDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/GuestBootstrap")
    }
}
