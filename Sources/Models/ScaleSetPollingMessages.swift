import Foundation

/// User-facing copy for scale-set session polling failures.
/// See `Docs/github-runner-api-strategy.md` for the product boundary and JIT fallback.
enum ScaleSetPollingMessages {
    static let strategyReference = "Docs/github-runner-api-strategy.md"

    static func unavailable(
        org: String,
        accountType: GitHubAccountType,
        statusCode: Int,
        operation: String
    ) -> String {
        """
        \(org): Scale-set job polling is unavailable (HTTP \(statusCode) while \(operation)). \
        Verify the scale set ID and that this \(accountType.displayName.lowercased()) supports scale-set sessions \
        on GitHub.com. Without the session API, Tarmac cannot receive queued jobs from the scale set. \
        The documented fallback is ephemeral JIT runners matched by GitHub's normal runner routing \
        (see \(strategyReference)); Tarmac does not implement that alternate poller yet.
        """
    }

    static func unavailable(
        organization: Organization,
        statusCode: Int,
        operation: String
    ) -> String {
        unavailable(
            org: organization.name,
            accountType: organization.accountType,
            statusCode: statusCode,
            operation: operation
        )
    }

    static func setupSessionUnavailable(organization: Organization, statusCode: Int) -> String {
        unavailable(
            organization: organization,
            statusCode: statusCode,
            operation: "creating a scale-set session"
        )
    }

    static func setupScaleSetMetadataUnavailable(org: String, scaleSetId: Int) -> String {
        """
        \(org): Runner scale set \(scaleSetId) is unavailable. Confirm the scale set exists and that session \
        polling is supported for this account (see \(strategyReference)).
        """
    }
}
