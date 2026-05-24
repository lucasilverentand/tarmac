import Foundation

struct GitHubSetupCheckResult: Equatable, Identifiable, Sendable {
    let id = UUID()
    let organizationId: UUID
    let organizationName: String
    let checkedAt: Date
    let advertisedLabels: [String]
    let runnerGroupNames: [String]
    let scaleSetId: Int?
    let issues: [GitHubSetupCheckIssue]

    var isReady: Bool {
        issues.isEmpty
    }

    var statusText: String {
        if isReady {
            return "GitHub setup checks passed"
        }
        return issues.first?.message ?? "GitHub setup checks failed"
    }

    var readinessIssues: [RunnerHostReadinessIssue] {
        issues.map { issue in
            RunnerHostReadinessIssue(category: .github, message: issue.message)
        }
    }
}

struct GitHubSetupCheckIssue: Equatable, Identifiable, Sendable {
    let kind: GitHubSetupCheckIssueKind
    let message: String

    var id: String { "\(kind.rawValue):\(message)" }
}

enum GitHubSetupCheckIssueKind: String, Sendable {
    case missingAppId
    case missingPrivateKey
    case missingAccessToken
    case missingScaleSet
    case imageProfileNotReady
    case labelMismatch
    case installationUnavailable
    case permissionMissing
    case runnerGroupUnavailable
    case scaleSetUnavailable
    case unsupportedAccountType
    case githubUnavailable
}

extension GitHubEngine {
    func runSetupCheck(for org: Organization) async -> GitHubSetupCheckResult {
        var issues: [GitHubSetupCheckIssue] = []
        var runnerGroups: [String] = []
        let labels = Self.normalizedLabels(org.runnerLabels)

        if org.requiresGitHubAppCredentials && org.appId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(
                .init(
                    kind: .missingAppId,
                    message: "\(org.name): GitHub App ID is not configured."
                )
            )
        }

        if org.scaleSetId == nil {
            issues.append(
                .init(
                    kind: .missingScaleSet,
                    message: "\(org.name): Scale set ID is not configured."
                )
            )
        }

        if labels.isEmpty {
            issues.append(
                .init(
                    kind: .labelMismatch,
                    message: "\(org.name): Runner labels are empty, so no workflow can target this runner."
                )
            )
        } else if !labels.contains(where: { $0.localizedCaseInsensitiveCompare("self-hosted") == .orderedSame }) {
            issues.append(
                .init(
                    kind: .labelMismatch,
                    message: "\(org.name): Labels do not include GitHub's required self-hosted label."
                )
            )
        }

        issues.append(
            contentsOf: org.imageProfileReadinessIssues.map { issue in
                .init(
                    kind: .imageProfileNotReady,
                    message: "\(org.name): \(issue.message)"
                )
            }
        )

        let token: String
        if org.requiresEnterpriseAccessToken {
            guard let tokenData = keychainService.load(key: org.accessTokenKeychainKey),
                let loadedToken = String(data: tokenData, encoding: .utf8),
                !loadedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                issues.append(
                    .init(
                        kind: .missingAccessToken,
                        message: "\(org.name): Enterprise access token is not configured."
                    )
                )
                return Self.setupCheckResult(for: org, labels: labels, runnerGroups: runnerGroups, issues: issues)
            }
            token = loadedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            guard let keyData = keychainService.load(key: org.privateKeyKeychainKey) else {
                issues.append(
                    .init(
                        kind: .missingPrivateKey,
                        message: "\(org.name): Private key is not imported."
                    )
                )
                return Self.setupCheckResult(for: org, labels: labels, runnerGroups: runnerGroups, issues: issues)
            }

            do {
                token = try await tokenManager.installationToken(for: org, privateKeyData: keyData)
            } catch {
                issues.append(Self.issue(for: error, org: org.name, capability: "GitHub App installation access"))
                return Self.setupCheckResult(for: org, labels: labels, runnerGroups: runnerGroups, issues: issues)
            }
        }

        if org.requiresGitHubAppCredentials {
            await Self.appendRawCheck(
                to: &issues,
                client: client,
                method: "GET",
                path: "/installation/repositories",
                token: token,
                org: org.name,
                capability: "GitHub App installation access",
                notFoundMessage: "\(org.name): GitHub App installation was not found."
            )
        }

        await Self.appendRawCheck(
            to: &issues,
            client: client,
            method: "GET",
            path: "\(org.accountPath)/actions/runners/downloads",
            token: token,
            org: org.name,
            capability: "Actions runner downloads",
            notFoundMessage:
                "\(org.name): Actions runner downloads are unavailable for this \(org.accountType.displayName.lowercased())."
        )

        let groupData = await Self.rawCheckData(
            to: &issues,
            client: client,
            method: "GET",
            path: "\(org.accountPath)/actions/runner-groups",
            token: token,
            org: org.name,
            capability: "Runner group access",
            notFoundMessage:
                "\(org.name): Runner groups are unavailable for this \(org.accountType.displayName.lowercased()).",
            kind: .runnerGroupUnavailable
        )
        if let groupData,
            let decoded = try? JSONDecoder().decode(GitHubRunnerGroupsResponse.self, from: groupData)
        {
            runnerGroups = decoded.runnerGroups.map(\.name)
        }

        if let scaleSetId = org.scaleSetId {
            await Self.appendRawCheck(
                to: &issues,
                client: client,
                method: "GET",
                path: "\(org.accountPath)/actions/runner-scale-sets/\(scaleSetId)",
                token: token,
                org: org.name,
                capability: "Runner scale set \(scaleSetId)",
                notFoundMessage: "\(org.name): Runner scale set \(scaleSetId) is unavailable.",
                kind: .scaleSetUnavailable
            )
        }

        return Self.setupCheckResult(for: org, labels: labels, runnerGroups: runnerGroups, issues: issues)
    }

    private static func setupCheckResult(
        for org: Organization,
        labels: [String],
        runnerGroups: [String],
        issues: [GitHubSetupCheckIssue]
    ) -> GitHubSetupCheckResult {
        GitHubSetupCheckResult(
            organizationId: org.id,
            organizationName: org.name,
            checkedAt: Date(),
            advertisedLabels: labels,
            runnerGroupNames: runnerGroups,
            scaleSetId: org.scaleSetId,
            issues: issues
        )
    }

    private static func normalizedLabels(_ labels: [String]) -> [String] {
        labels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func appendRawCheck(
        to issues: inout [GitHubSetupCheckIssue],
        client: any GitHubClientProtocol,
        method: String,
        path: String,
        token: String,
        org: String,
        capability: String,
        notFoundMessage: String,
        kind: GitHubSetupCheckIssueKind = .permissionMissing
    ) async {
        _ = await rawCheckData(
            to: &issues,
            client: client,
            method: method,
            path: path,
            token: token,
            org: org,
            capability: capability,
            notFoundMessage: notFoundMessage,
            kind: kind
        )
    }

    private static func rawCheckData(
        to issues: inout [GitHubSetupCheckIssue],
        client: any GitHubClientProtocol,
        method: String,
        path: String,
        token: String,
        org: String,
        capability: String,
        notFoundMessage: String,
        kind: GitHubSetupCheckIssueKind = .permissionMissing
    ) async -> Data? {
        do {
            let (data, response) = try await client.requestRaw(
                method: method,
                path: path,
                body: nil as String?,
                headers: ["Authorization": "Bearer \(token)"],
                timeoutInterval: 30
            )

            guard (200..<300).contains(response.statusCode) else {
                issues.append(
                    issue(
                        statusCode: response.statusCode,
                        org: org,
                        capability: capability,
                        notFoundMessage: notFoundMessage,
                        kind: kind
                    )
                )
                return nil
            }

            return data
        } catch {
            issues.append(issue(for: error, org: org, capability: capability))
            return nil
        }
    }

    private static func issue(
        statusCode: Int,
        org: String,
        capability: String,
        notFoundMessage: String,
        kind: GitHubSetupCheckIssueKind
    ) -> GitHubSetupCheckIssue {
        switch statusCode {
        case 401, 403:
            return .init(
                kind: .permissionMissing,
                message: "\(org): Permission missing for \(capability). GitHub returned HTTP \(statusCode)."
            )
        case 404:
            return .init(kind: kind, message: notFoundMessage)
        case 500...599:
            return .init(
                kind: .githubUnavailable,
                message: "\(org): GitHub returned HTTP \(statusCode) while checking \(capability)."
            )
        default:
            return .init(
                kind: kind,
                message: "\(org): GitHub returned HTTP \(statusCode) while checking \(capability)."
            )
        }
    }

    private static func issue(for error: Error, org: String, capability: String) -> GitHubSetupCheckIssue {
        if let apiError = error as? GitHubAPIError,
            case .httpError(let statusCode, _) = apiError
        {
            return issue(
                statusCode: statusCode,
                org: org,
                capability: capability,
                notFoundMessage: "\(org): GitHub App installation was not found.",
                kind: .installationUnavailable
            )
        }

        return .init(
            kind: .githubUnavailable,
            message: "\(org): Could not check \(capability): \(error.localizedDescription)"
        )
    }
}

private struct GitHubRunnerGroupsResponse: Decodable {
    let runnerGroups: [GitHubRunnerGroup]

    enum CodingKeys: String, CodingKey {
        case runnerGroups = "runner_groups"
    }
}

private struct GitHubRunnerGroup: Decodable {
    let name: String
}
