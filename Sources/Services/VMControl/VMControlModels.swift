import Foundation

struct VMControlHealthResponse: Codable, Sendable, Equatable {
    let status: String
    let service: String
}

struct VMControlVMResponse: Codable, Sendable, Equatable {
    let instance: VMControlInstanceDTO?
    let isRunning: Bool
    let baseImageExists: Bool
    let baseImageVerified: Bool

    init(
        instance: VMInstance?,
        isRunning: Bool,
        baseImageExists: Bool,
        baseImageVerified: Bool
    ) {
        self.instance = instance.map(VMControlInstanceDTO.init)
        self.isRunning = isRunning
        self.baseImageExists = baseImageExists
        self.baseImageVerified = baseImageVerified
    }
}

struct VMControlInstanceDTO: Codable, Sendable, Equatable {
    let id: String
    let jobId: Int64
    let diskImagePath: String
    let startedAt: Date
    let state: String

    init(_ instance: VMInstance) {
        id = instance.id.uuidString
        jobId = instance.jobId
        diskImagePath = instance.diskImagePath.path
        startedAt = instance.startedAt
        state = instance.state.rawValue
    }
}

struct VMControlErrorResponse: Codable, Sendable, Equatable {
    let error: String
}

enum VMControlError: LocalizedError, Equatable {
    case vmAlreadyRunning
    case vmNotRunning
    case baseImageMissing
    case queueBusy
    case vmEngineUnavailable

    var errorDescription: String? {
        switch self {
        case .vmAlreadyRunning:
            "A VM is already running"
        case .vmNotRunning:
            "No VM is running"
        case .baseImageMissing:
            "Base image does not exist on disk"
        case .queueBusy:
            "Cannot control VM while a runner job is active"
        case .vmEngineUnavailable:
            "VM engine is not available"
        }
    }
}

struct VMControlHTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.path = path
        self.headers = headers
        self.body = body
    }
}

struct VMControlHTTPResponse: Equatable, Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    static func json<T: Encodable>(_ value: T, statusCode: Int = 200) -> VMControlHTTPResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let body = (try? encoder.encode(value)) ?? Data("{\"error\":\"encoding failed\"}".utf8)
        return VMControlHTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }

    static func error(_ message: String, statusCode: Int) -> VMControlHTTPResponse {
        json(VMControlErrorResponse(error: message), statusCode: statusCode)
    }

    func serialized() -> Data {
        var headerLines = ["HTTP/1.1 \(statusCode) \(Self.reasonPhrase(for: statusCode))"]
        var responseHeaders = headers
        responseHeaders["Content-Length"] = String(body.count)
        responseHeaders["Connection"] = "close"
        for (name, value) in responseHeaders.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            headerLines.append("\(name): \(value)")
        }
        var data = Data(headerLines.joined(separator: "\r\n").utf8)
        data.append(contentsOf: "\r\n\r\n".utf8)
        data.append(body)
        return data
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}
