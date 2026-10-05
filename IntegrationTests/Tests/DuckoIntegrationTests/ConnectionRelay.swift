import Dispatch
import Foundation
import Network

/// A loopback TCP relay in front of a server. Cutting its connections drops a client the way a lost network does:
/// neither end closes its stream, so the server keeps the session for a resume.
actor ConnectionRelay {
    private let queue = DispatchQueue(label: "ducko.connection-relay")
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    /// Starts relaying to `host` and `port`, and returns the loopback port to connect to.
    func start(forwardingTo host: String, port: UInt16) async throws -> UInt16 {
        // Bound to the loopback address, so no other host can have the relay forward it to the server.
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let target = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))
        listener.newConnectionHandler = { connection in Task { await self.relay(connection, to: target) } }
        return try await listener.startAndAwaitPort(on: queue)
    }

    /// Cuts every relayed connection. The listener stays up, so the client can reconnect through it.
    func dropConnections() {
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()
    }

    func stop() {
        dropConnections()
        listener?.cancel()
    }

    private func relay(_ inbound: NWConnection, to target: NWEndpoint) {
        let outbound = NWConnection(to: target, using: .tcp)
        connections += [inbound, outbound]
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        Self.forward(from: inbound, to: outbound)
        Self.forward(from: outbound, to: inbound)
    }

    private static func forward(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if complete || error != nil {
                source.cancel()
                destination.cancel()
            } else {
                forward(from: source, to: destination)
            }
        }
    }
}
