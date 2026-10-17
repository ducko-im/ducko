import Logging

private let log = Logger(label: "im.ducko.xmpp.registrationclient")

/// Lightweight client for XEP-0077 pre-auth registration.
/// Manages its own connection lifecycle — connect, negotiate TLS, register, disconnect.
public enum XMPPRegistrationClient {
    public enum RegistrationClientError: Error {
        case connectionFailed(String)
        case tlsNegotiationFailed
        case registrationNotSupported
        case registrationFailed(String)
        case unexpectedResponse
    }

    /// Retrieves the registration form from a server without authenticating.
    public static func retrieveForm(
        domain: String,
        host: String? = nil,
        port: UInt16 = 5222
    ) async throws -> RegistrationModule.RegistrationForm {
        try await retrieveForm(domain: domain, host: host, port: port, transport: makeDefaultXMPPTransport())
    }

    static func retrieveForm(
        domain: String, host: String? = nil, port: UInt16 = 5222, transport: any XMPPTransport
    ) async throws -> RegistrationModule.RegistrationForm {
        try await withRegistrationConnection(domain: domain, host: host, port: port, transport: transport) { connection, reader in
            var iq = XMPPIQ(type: .get, id: "reg1")
            let query = XMLElement(name: "query", namespace: XMPPNamespaces.register)
            iq.element.addChild(query)
            try await connection.send(XMPPStreamWriter.stanza(iq.element))

            let response = try await awaitStanza(reader)
            guard response.name == "iq",
                  response.attribute("type") == "result",
                  let queryResult = response.child(named: "query", namespace: XMPPNamespaces.register)
            else {
                throw RegistrationClientError.unexpectedResponse
            }

            return RegistrationModule.parseForm(queryResult)
        }
    }

    /// Registers a new account on the server without authenticating first.
    public static func register(
        domain: String,
        username: String,
        password: String,
        email: String? = nil,
        host: String? = nil,
        port: UInt16 = 5222
    ) async throws {
        try await register(domain: domain, username: username, password: password, email: email, host: host, port: port, transport: makeDefaultXMPPTransport())
    }

    static func register(
        domain: String, username: String, password: String, email: String? = nil,
        host: String? = nil, port: UInt16 = 5222, transport: any XMPPTransport
    ) async throws {
        try await withRegistrationConnection(domain: domain, host: host, port: port, transport: transport) { connection, reader in
            var iq = XMPPIQ(type: .set, id: "reg1")
            let query = RegistrationModule.buildRegistrationQuery(username: username, password: password, email: email)
            iq.element.addChild(query)
            try await connection.send(XMPPStreamWriter.stanza(iq.element))

            let response = try await awaitStanza(reader)
            guard response.name == "iq" else {
                throw RegistrationClientError.unexpectedResponse
            }

            if response.attribute("type") == "error" {
                let stanzaError = XMPPStanzaError.parse(from: response.child(named: "error"))
                throw RegistrationClientError.registrationFailed(registrationFailureText(stanzaError))
            }

            guard response.attribute("type") == "result" else {
                throw RegistrationClientError.unexpectedResponse
            }

            log.info("Registration successful")
            log.debug("The registered account is \(username)@\(domain)")
        }
    }

    private static func withRegistrationConnection<Result: Sendable>(
        domain: String, host: String?, port: UInt16, transport: any XMPPTransport,
        operation: (XMPPConnection, EventReader) async throws -> Result
    ) async throws -> Result {
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
            try await negotiateStream(connection: connection, reader: reader, domain: names.stream, serverName: names.lookup)
            let result = try await operation(connection, reader)
            await connection.disconnect()
            return result
        } catch {
            await connection.disconnect()
            throw error
        }
    }

    /// Readable reason for a rejected registration: the server's non-blank text, else a phrase for the condition. A
    /// `conflict` reads as the username being taken (XEP-0077 §3.1).
    static func registrationFailureText(_ error: XMPPStanzaError?) -> String {
        guard let error else { return "The server gave no reason" }
        guard error.condition == .conflict else { return error.displayText }
        if let text = error.text, !text.allSatisfy(\.isWhitespace) { return text }
        return "The username is already taken"
    }

    static func negotiateStream(
        connection: XMPPConnection,
        reader: EventReader,
        domain: String,
        serverName: String
    ) async throws {
        try await connection.send(XMPPStreamWriter.streamOpening(to: domain))
        let features = try await awaitFeatures(reader)

        if await connection.isDirectTLS { return }

        // STARTTLS if available
        if features.child(named: "starttls", namespace: XMPPNamespaces.tls) != nil {
            let starttls = XMLElement(name: "starttls", namespace: XMPPNamespaces.tls)
            try await connection.send(XMPPStreamWriter.stanza(starttls))

            let response = try await awaitStanza(reader)
            guard XMPPConnection.isTLSProceed(response) else {
                throw RegistrationClientError.tlsNegotiationFailed
            }

            try await connection.upgradeTLS(serverName: serverName)

            // Reopen stream after TLS
            try await connection.send(XMPPStreamWriter.streamOpening(to: domain))
            _ = try await awaitFeatures(reader)
        } else {
            throw RegistrationClientError.tlsNegotiationFailed
        }
    }

    /// Wraps `EventReader.awaitFeatures()` to map errors to `RegistrationClientError`.
    private static func awaitFeatures(_ reader: EventReader) async throws -> XMLElement {
        do {
            return try await reader.awaitFeatures()
        } catch is XMPPClientError {
            throw RegistrationClientError.unexpectedResponse
        }
    }

    /// Wraps `EventReader.awaitStanza()` to map errors to `RegistrationClientError`.
    private static func awaitStanza(_ reader: EventReader) async throws -> XMLElement {
        do {
            return try await reader.awaitStanza()
        } catch is XMPPClientError {
            throw RegistrationClientError.unexpectedResponse
        }
    }
}
