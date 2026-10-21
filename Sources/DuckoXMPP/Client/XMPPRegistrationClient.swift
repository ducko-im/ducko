/// XEP-0077 pre-auth registration helpers. `RegistrationSession` owns the connection.
public enum XMPPRegistrationClient {
    public enum RegistrationClientError: Error {
        case connectionFailed(String)
        case tlsNegotiationFailed
        case registrationNotSupported
        case registrationFailed(String)
        case unexpectedResponse
        /// The stream or connection has ended, so a new session has to start over.
        case connectionClosed
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
        let session = try await RegistrationSession.open(domain: domain, host: host, port: port, transport: transport)
        do {
            let form = try await session.fetchForm()
            await session.close()
            return form
        } catch {
            await session.close()
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
