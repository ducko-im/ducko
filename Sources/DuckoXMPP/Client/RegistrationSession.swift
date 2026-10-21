import Logging

private let log = Logger(label: "im.ducko.xmpp.registrationsession")

/// One unauthenticated connection for XEP-0077 registration. The form is fetched and the registration submitted on the
/// same stream, as the server expects. The session keeps no timer, so its owner must call `close()` on every exit.
public actor RegistrationSession {
    private typealias RegistrationClientError = XMPPRegistrationClient.RegistrationClientError

    private let connection: XMPPConnection
    private let reader: EventReader
    private var isClosed = false

    private init(connection: XMPPConnection, reader: EventReader) {
        self.connection = connection
        self.reader = reader
    }

    /// Connects to the server and negotiates TLS.
    public static func open(domain: String, host: String? = nil, port: UInt16 = 5222) async throws -> RegistrationSession {
        try await open(domain: domain, host: host, port: port, transport: makeDefaultXMPPTransport())
    }

    static func open(domain: String, host: String?, port: UInt16, transport: any XMPPTransport) async throws -> RegistrationSession {
        guard let names = IDNA.names(for: domain) else {
            throw RegistrationClientError.connectionFailed("Invalid domain: \(domain)")
        }
        let connection = XMPPConnection(transport: transport)
        let reader = EventReader(connection.events)
        do {
            try Task.checkCancellation()
            if let host {
                try await connection.connect(host: host, port: port)
            } else {
                try await connection.connect(domain: names.lookup)
            }
            try await XMPPRegistrationClient.negotiateStream(
                connection: connection, reader: reader, domain: names.stream, serverName: names.lookup
            )
        } catch {
            await connection.disconnect()
            throw error
        }
        return RegistrationSession(connection: connection, reader: reader)
    }

    public func fetchForm() async throws -> RegistrationModule.RegistrationForm {
        var iq = XMPPIQ(type: .get, id: XMPPClient.makeStanzaID())
        iq.element.addChild(XMLElement(name: "query", namespace: XMPPNamespaces.register))
        let response = try await exchange(iq)
        guard response.attribute("type") == "result",
              let query = response.child(named: "query", namespace: XMPPNamespaces.register)
        else {
            throw RegistrationClientError.unexpectedResponse
        }
        return RegistrationModule.parseForm(query)
    }

    /// Sends the registration and waits for the server to accept it.
    public func submit(_ submission: RegistrationModule.Submission) async throws {
        var iq = XMPPIQ(type: .set, id: XMPPClient.makeStanzaID())
        iq.element.addChild(RegistrationModule.buildRegistrationQuery(submission))
        let response = try await exchange(iq)
        if response.attribute("type") == "error" {
            let stanzaError = XMPPStanzaError.parse(from: response.child(named: "error"))
            throw RegistrationClientError.registrationFailed(XMPPRegistrationClient.registrationFailureText(stanzaError))
        }
        guard response.attribute("type") == "result" else {
            throw RegistrationClientError.unexpectedResponse
        }
        log.info("Registration successful")
    }

    /// Ends the stream and the connection. Later calls do nothing.
    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        _ = await connection.sendStreamClose()
        await connection.disconnect()
    }

    /// Sends the request and returns the server's reply to it, skipping unrelated stanzas.
    private func exchange(_ iq: XMPPIQ) async throws -> XMLElement {
        guard !isClosed else { throw RegistrationClientError.connectionClosed }
        do {
            try await connection.send(XMPPStreamWriter.stanza(iq.element))
        } catch {
            throw RegistrationClientError.connectionClosed
        }
        while true {
            guard let event = await reader.next() else {
                try Task.checkCancellation()
                throw RegistrationClientError.connectionClosed
            }
            switch event {
            case let .stanzaReceived(element):
                if element.name == "iq", element.attribute("id") == iq.id,
                   element.attribute("type") == "result" || element.attribute("type") == "error" {
                    return element
                }
                if element.name == "error" { throw RegistrationClientError.connectionClosed }
            case .streamClosed, .error:
                throw RegistrationClientError.connectionClosed
            case .streamOpened:
                throw RegistrationClientError.unexpectedResponse
            }
        }
    }
}
