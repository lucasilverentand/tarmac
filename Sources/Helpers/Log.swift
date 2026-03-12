import OSLog

enum Log {
    static let subsystem = "studio.seventwo.tarmac"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let github = Logger(subsystem: subsystem, category: "github")
    static let jwt = Logger(subsystem: subsystem, category: "jwt")
    static let token = Logger(subsystem: subsystem, category: "token")
    static let queue = Logger(subsystem: subsystem, category: "queue")
    static let poller = Logger(subsystem: subsystem, category: "poller")
    static let vm = Logger(subsystem: subsystem, category: "vm")
    static let image = Logger(subsystem: subsystem, category: "image")
    static let keychain = Logger(subsystem: subsystem, category: "keychain")
    static let config = Logger(subsystem: subsystem, category: "config")
    static let runner = Logger(subsystem: subsystem, category: "runner")
    static let cache = Logger(subsystem: subsystem, category: "cache")
}
