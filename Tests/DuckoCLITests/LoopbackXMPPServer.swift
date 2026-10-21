import Dispatch
import DuckoCore
import Foundation
import Network
import Testing
@testable import DuckoXMPP

/// Answers the IQs a `LoopbackXMPPServer` test cares about.
protocol LoopbackIQResponder: Sendable {
    /// The reply to the IQ `element` with `id`, or nil to leave it to the server's default answer.
    mutating func reply(to element: DuckoXMPP.XMLElement, id: String) -> String?
}

/// A plaintext XMPP server on a loopback port that signs in any PLAIN credentials and binds `alice@example.com/fixture`.
/// It confirms other sets, bounces other gets with `service-unavailable`, and lets `responder` answer first.
actor LoopbackXMPPServer<Responder: LoopbackIQResponder> {
    private let queue = DispatchQueue(label: "ducko.loopback-xmpp")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var parser = XMPPStreamParser()
    private(set) var authenticated = false
    private var responder: Responder
    private(set) var sawStreamClose = false

    init(responder: Responder) {
        self.responder = responder
    }

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { connection in Task { await self.accept(connection) } }
        let states = AsyncThrowingStream<UInt16, Error>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port { states.continuation.yield(port.rawValue); states.continuation.finish() }
            case let .failed(error): states.continuation.finish(throwing: error)
            case .cancelled: states.continuation.finish(throwing: CancellationError())
            case .setup, .waiting: break
            @unknown default: break
            }
        }
        listener.start(queue: queue)
        for try await port in states.stream {
            return port
        }
        throw CancellationError()
    }

    private func accept(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            Task { await self.received(data, ended: complete || error != nil) }
        }
    }

    private func received(_ data: Data?, ended: Bool) {
        if let data {
            for event in parser.parse(Array(data)) {
                switch event {
                case .streamOpened:
                    send("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' from='example.com' version='1.0'><stream:features>" + (authenticated ? "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>" : "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>PLAIN</mechanism></mechanisms>") + "</stream:features>")
                case let .stanzaReceived(element): handle(element)
                case .streamClosed:
                    sawStreamClose = true
                    send("</stream:stream>")
                case .error: break
                }
            }
        }
        if !ended { receive() }
    }

    private func handle(_ element: DuckoXMPP.XMLElement) {
        if element.name == "auth" {
            authenticated = true
            parser = XMPPStreamParser()
            send("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
        } else if element.name == "iq", let id = element.attribute("id") {
            let iq = XMPPIQ(element: element)
            if element.child(named: "bind", namespace: XMPPNamespaces.bind) != nil {
                send("<iq type='result' id='\(id)'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><jid>alice@example.com/fixture</jid></bind></iq>")
            } else if let reply = responder.reply(to: element, id: id) {
                send(reply)
            } else if iq.type == "set" {
                send("<iq type='result' id='\(id)'/>")
            } else if iq.type == "get" {
                // An addressed request is answered from the JID it addressed, as a server bounce does.
                let from = element.attribute("to").map { " from='\($0)'" } ?? ""
                send("<iq type='error' id='\(id)'\(from)><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
            }
        }
    }

    private func send(_ text: String) {
        connection?.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    func stop() {
        connection?.cancel(); listener?.cancel()
    }
}

/// Runs `body` against a `LoopbackXMPPServer` answering with `responder`, in a throwaway profile named after
/// `profileName` that holds an account signing in to it. The server stops and the profile goes on every exit.
@MainActor
func withLoopbackServer<Responder: LoopbackIQResponder, T>(
    responder: Responder,
    profile profileName: String,
    _ body: (LoopbackXMPPServer<Responder>, ThrowawayProfile) async throws -> T
) async throws -> T {
    let server = LoopbackXMPPServer(responder: responder)
    let port = try await server.start()
    do {
        let profile = try ThrowawayProfile(named: profileName)
        defer { profile.remove() }
        try await profile.addLoopbackAccount(port: port)
        let result = try await body(server, profile)
        await server.stop()
        return result
    } catch {
        await server.stop()
        throw error
    }
}

extension ThrowawayProfile {
    /// Saves an account that signs in to a `LoopbackXMPPServer` on `port`.
    func addLoopbackAccount(port: UInt16) async throws {
        let store = try makeStore()
        let account = try Account(id: UUID(), jid: #require(BareJID.parse("alice@example.com")), isEnabled: true, connectOnLaunch: false, host: "127.0.0.1", port: Int(port), requireTLS: false, createdAt: Date())
        try await store.saveAccount(account)
        FileCredentialStore(fileURL: directory.appending(path: "credentials.json")).savePassword("local-fixture", for: account.jid.description)
    }
}
