import Foundation
import Security
@testable import Tarmac

enum TestFactories {
    static func makeJob(
        id: Int64 = 1,
        status: JobStatus = .pending,
        org: String = "test-org",
        workflowName: String? = "CI",
        repositoryName: String? = "test-repo",
        queuedAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) -> RunnerJob {
        RunnerJob(
            id: id,
            organizationName: org,
            status: status,
            workflowName: workflowName,
            repositoryName: repositoryName,
            queuedAt: queuedAt,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    static func makeOrg(
        name: String = "test-org",
        appId: String = "123456",
        installationId: Int = 12345,
        scaleSetId: Int? = 42,
        labels: [String] = ["self-hosted", "macOS", "ARM64"],
        isEnabled: Bool = true,
        filterMode: RepositoryFilterMode = .all,
        filteredRepositories: [String] = []
    ) -> Organization {
        Organization(
            name: name,
            appId: appId,
            installationId: installationId,
            scaleSetId: scaleSetId,
            labels: labels,
            isEnabled: isEnabled,
            filterMode: filterMode,
            filteredRepositories: filteredRepositories
        )
    }

    static func makeJobStore() -> JobStore {
        let suiteName = "test-jobstore-\(UUID().uuidString)"
        return JobStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    @MainActor
    static func makeConfigStore() -> (ConfigStore, UserDefaults) {
        let suiteName = "test-config-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keychain = PreviewKeychainService()
        let store = ConfigStore(defaults: defaults, keychainService: keychain)
        return (store, defaults)
    }

    static func makeTestKeyData() throws -> Data {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        guard let keyData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        let base64 = keyData.base64EncodedString(options: .lineLength64Characters)
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n\(base64)\n-----END RSA PRIVATE KEY-----"
        return pem.data(using: .utf8)!
    }

    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tarmac-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
