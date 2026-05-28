import Testing

@testable import Tarmac

@Suite("GitHubAPIError runner registration fallback")
struct GitHubAPIErrorTests {
    @Test("eligible status codes include 404 and transient server errors")
    func eligibleStatusCodes() {
        for code in [404, 408, 429, 500, 502, 503, 504] {
            let error = GitHubAPIError.httpError(statusCode: code, message: "x")
            #expect(error.isRunnerRegistrationFallbackEligible)
        }
    }

    @Test("auth and validation errors are not fallback eligible")
    func ineligibleStatusCodes() {
        for code in [401, 403, 422] {
            let error = GitHubAPIError.httpError(statusCode: code, message: "x")
            #expect(!error.isRunnerRegistrationFallbackEligible)
        }
    }
}
