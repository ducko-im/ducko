import Dispatch
import Foundation
import Network
@testable import DuckoXMPP

actor UIRosterLoopbackServer {
    private let queue = DispatchQueue(label: "ducko.roster-loopback")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var parser = XMPPStreamParser()
    private var authenticated = false
    private(set) var mutated = false
    private var rejection = false
    private(set) var requestedVersions: [String?] = []

    func rejectMutation() {
        rejection = true
    }

    private(set) var sawStreamClose = false

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { connection in Task { await self.accept(connection) } }
        return try await listener.startAndAwaitPort(on: queue)
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
                    send("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' from='example.com' version='1.0'><stream:features>" + (authenticated ? "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/><ver xmlns='urn:xmpp:features:rosterver'/>" : "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>PLAIN</mechanism></mechanisms>") + "</stream:features>")
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
            } else if element.child(named: "query", namespace: XMPPNamespaces.roster) != nil {
                if iq.type == "get" { requestedVersions.append(iq.childElement?.attribute("ver")) }
                if iq.type == "set", rejection {
                    send("<iq type='error' id='\(id)'><error type='cancel'><forbidden xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
                    return
                }
                if iq.type == "set" { mutated = true }
                let body = mutated ? "" : "<query xmlns='jabber:iq:roster' ver='initial'><item jid='bob@example.com' name='Bob' subscription='both'/></query>"
                send("<iq type='result' id='\(id)'>\(body)</iq>")
            } else if iq.type == "set" {
                send("<iq type='result' id='\(id)'/>")
            } else if iq.type == "get" {
                send("<iq type='error' id='\(id)'><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
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
