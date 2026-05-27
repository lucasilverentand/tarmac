import Foundation
import Network

@MainActor
final class LocalVMControlHTTPServer {
    private let configuration: VMControlConfiguration
    private let handler: VMControlHandling
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    init(configuration: VMControlConfiguration, handler: VMControlHandling) {
        self.configuration = configuration
        self.handler = handler
    }

    var isListening: Bool {
        listener != nil
    }

    func start() throws {
        guard configuration.isEnabled else {
            stop()
            return
        }
        guard listener == nil else { return }

        guard let port = NWEndpoint.Port(rawValue: configuration.normalizedPort) else {
            throw LocalVMControlHTTPServerError.invalidPort(configuration.port)
        }

        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(VMControlConfiguration.loopbackHost),
            port: port
        )

        let listener = try NWListener(using: parameters, on: port)
        let port = configuration.normalizedPort
        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                Log.vmControl.error("VM control listener failed: \(error.localizedDescription)")
            case .ready:
                Log.vmControl.info(
                    "VM control REST listening on \(VMControlConfiguration.loopbackHost, privacy: .public):\(port, privacy: .public)"
                )
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { @MainActor in
                self.handle(connection: connection)
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func stop() {
        for connection in activeConnections.values {
            connection.cancel()
        }
        activeConnections.removeAll()
        listener?.cancel()
        listener = nil
    }

    private func handle(connection: NWConnection) {
        guard isLoopback(connection) else {
            Log.vmControl.warning("Rejected non-loopback VM control connection")
            connection.cancel()
            return
        }

        let connectionID = ObjectIdentifier(connection)
        activeConnections[connectionID] = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                Task { @MainActor in
                    self.activeConnections.removeValue(forKey: connectionID)
                }
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            Task { @MainActor in
                if let error {
                    Log.vmControl.debug("VM control connection receive ended: \(error.localizedDescription)")
                    self.finish(connection: connection)
                    return
                }

                var buffer = accumulated
                if let data {
                    buffer.append(data)
                }

                if self.shouldProcess(buffer: buffer, isComplete: isComplete) {
                    await self.process(buffer: buffer, on: connection)
                    return
                }

                if isComplete {
                    if buffer.isEmpty {
                        self.finish(connection: connection)
                    } else {
                        await self.process(buffer: buffer, on: connection)
                    }
                    return
                }

                self.receive(on: connection, accumulated: buffer)
            }
        }
    }

    private func shouldProcess(buffer: Data, isComplete: Bool) -> Bool {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return isComplete
        }

        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let headers = String(data: headerData, encoding: .utf8) else {
            return isComplete
        }

        let contentLength = headers
            .split(separator: "\r\n")
            .compactMap { line -> Int? in
                let lower = line.lowercased()
                guard lower.hasPrefix("content-length:") else { return nil }
                let value = lower.split(separator: ":", maxSplits: 1).last?
                return value.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
            .first ?? 0

        let bodyStart = headerEnd.upperBound
        let receivedBodyLength = buffer.count - bodyStart
        return receivedBodyLength >= contentLength
    }

    private func process(buffer: Data, on connection: NWConnection) async {
        defer { finish(connection: connection) }

        guard let request = VMControlHTTPRouter.parseRequest(from: buffer) else {
            send(
                VMControlHTTPResponse.error("Bad request", statusCode: 400).serialized(),
                on: connection
            )
            return
        }

        let response = await VMControlHTTPRouter.handle(
            request: request,
            configuration: configuration,
            handler: handler
        )
        send(response.serialized(), on: connection)
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(
            content: data,
            completion: .contentProcessed { error in
                if let error {
                    Log.vmControl.debug("VM control response send failed: \(error.localizedDescription)")
                }
            }
        )
    }

    private func finish(connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        activeConnections.removeValue(forKey: connectionID)
        connection.cancel()
    }

    private func isLoopback(_ connection: NWConnection) -> Bool {
        guard case .hostPort(let host, _) = connection.endpoint else {
            return false
        }
        switch host {
        case .ipv4(let address):
            return address == IPv4Address("127.0.0.1")
        case .ipv6(let address):
            return address == IPv6Address("::1")
        default:
            return false
        }
    }
}

enum LocalVMControlHTTPServerError: LocalizedError {
    case invalidPort(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            "Invalid VM control port: \(port)"
        }
    }
}
