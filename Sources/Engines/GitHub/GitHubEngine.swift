import Foundation

actor GitHubEngine {
    let tokenManager: TokenManager
    let runnerProvider: RunnerProvider
    private let client: any GitHubClientProtocol
    private let keychainService: any KeychainServiceProtocol

    init(
        client: any GitHubClientProtocol = GitHubClient(),
        keychainService: any KeychainServiceProtocol = KeychainService(),
        cacheDirectory: URL
    ) {
        self.client = client
        self.keychainService = keychainService
        self.tokenManager = TokenManager(client: client)
        self.runnerProvider = RunnerProvider(client: client, cacheDirectory: cacheDirectory)
    }

    func installationToken(for org: Organization) async throws -> String {
        guard let keyData = keychainService.load(key: org.privateKeyKeychainKey) else {
            throw TokenError.noPrivateKey
        }
        return try await tokenManager.installationToken(for: org, privateKeyData: keyData)
    }

    func ensureRunner(for org: Organization) async throws -> URL {
        let token = try await installationToken(for: org)
        return try await runnerProvider.ensureRunner(token: token, org: org.name)
    }

    func generateJITConfig(for org: Organization, runnerName: String) async throws -> String {
        let token = try await installationToken(for: org)
        return try await runnerProvider.generateJITConfig(
            token: token,
            org: org.name,
            name: runnerName,
            labels: org.labels
        )
    }
}
