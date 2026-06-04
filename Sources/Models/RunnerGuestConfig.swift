import Foundation

/// How the guest Actions runner is configured inside the VirtioFS shared job directory.
enum RunnerGuestConfig: Equatable, Sendable {
    case jit(config: String)
    case registrationToken(url: String, token: String, runnerName: String, labels: [String])
}

extension RunnerJob {
    var runnerGuestConfig: RunnerGuestConfig? {
        if let jitConfig,
            !jitConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .jit(config: jitConfig)
        }

        if let registrationToken,
            let runnerRegistrationURL,
            let runnerName,
            !registrationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !runnerRegistrationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !runnerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .registrationToken(
                url: runnerRegistrationURL,
                token: registrationToken,
                runnerName: runnerName,
                labels: runnerRegistrationLabels ?? []
            )
        }

        return nil
    }

    mutating func applyRunnerGuestConfig(_ config: RunnerGuestConfig) {
        switch config {
        case .jit(let config):
            jitConfig = config
            registrationToken = nil
            runnerRegistrationURL = nil
            runnerRegistrationLabels = nil
        case .registrationToken(let url, let token, let runnerName, let labels):
            jitConfig = nil
            registrationToken = token
            runnerRegistrationURL = url
            self.runnerName = runnerName
            runnerRegistrationLabels = labels
        }
    }
}

extension Organization {
    /// GitHub URL passed to `config.sh --url` for registration-token runners.
    var runnerRegistrationURL: String {
        switch accountType {
        case .repository:
            "https://github.com/\(name)/\(repositoryName ?? "")"
        case .organization:
            "https://github.com/orgs/\(name)"
        case .enterprise:
            "https://github.com/enterprises/\(name)"
        }
    }
}
