import DuckoTestSupport
import Testing
@testable import DuckoXMPP

struct XMPPRegistrationClientTests {
    @Test(arguments: [false, true])
    func `pre-auth operation closes its transport after success`(register: Bool) async throws {
        let transport = MockTransport()
        let task = registrationTask(transport: transport, register: register)
        do {
            try await negotiate(transport)
            let request = try await awaitOutgoingIQ(on: transport, type: register ? .set : .get, namespace: XMPPNamespaces.register) { _ in true }
            if register {
                #expect(request.xml.contains("<username>new-user</username>"))
            }
            await transport.simulateReceive("<iq type='result' id='\(request.id)'><query xmlns='jabber:iq:register'><username/><password/></query></iq>")
        } catch {
            task.cancel()
            await transport.disconnect()
            _ = await task.result
            throw error
        }
        let form = try await task.value
        if !register {
            #expect(form?.legacyFields.map(\.name) == ["username", "password"])
        }
        #expect(await transport.disconnectCount == 1)
        #expect(await transport.isConnected == false)
        #expect(await transport.tlsServerName == "example.com")
    }

    @Test(arguments: [false, true])
    func `partial connect failure releases the registration transport`(register: Bool) async {
        let transport = MockTransport()
        await transport.failNextConnect(XMPPClientError.connectionFailed("fixture"), afterOpening: true)
        let task = registrationTask(transport: transport, register: register)
        await #expect(throws: XMPPClientError.self) { try await task.value }
        #expect(await transport.disconnectCount == 1)
        #expect(await transport.isConnected == false)
    }

    @Test(arguments: [false, true])
    func `invalid registration domain never opens a transport`(register: Bool) async {
        let transport = MockTransport()
        let task = registrationTask(transport: transport, register: register, domain: "bad domain.example")
        await #expect(throws: XMPPRegistrationClient.RegistrationClientError.self) { try await task.value }
        #expect(await transport.connectedHost == nil)
        #expect(await transport.disconnectCount == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func `registration cancellation releases the transport during negotiation or response wait`(register: Bool, afterTLS: Bool) async throws {
        let transport = MockTransport()
        let task = registrationTask(transport: transport, register: register)
        do {
            if afterTLS {
                try await negotiate(transport)
                _ = try await awaitOutgoingIQ(on: transport, type: register ? .set : .get, namespace: XMPPNamespaces.register) { _ in true }
            } else {
                try await awaitSent(on: transport) { $0.hasPrefix("<?xml") || $0.hasPrefix("<stream:stream") }
            }
        } catch {
            task.cancel()
            await transport.disconnect()
            _ = await task.result
            throw error
        }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(await transport.disconnectCount == 1)
        #expect(await transport.isConnected == false)
    }

    @Test(arguments: [false, true])
    func `registration rejection preserves operation-specific errors and closes transport`(register: Bool) async throws {
        let transport = MockTransport()
        let task = registrationTask(transport: transport, register: register)
        do {
            try await negotiate(transport)
            let request = try await awaitOutgoingIQ(on: transport, type: register ? .set : .get, namespace: XMPPNamespaces.register) { _ in true }
            await transport.simulateReceive("<iq type='error' id='\(request.id)'><error type='cancel'><conflict xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
        } catch {
            task.cancel()
            await transport.disconnect()
            _ = await task.result
            throw error
        }
        let error = await #expect(throws: XMPPRegistrationClient.RegistrationClientError.self) { try await task.value }
        if register {
            guard case let .registrationFailed(text) = error else {
                Issue.record("Expected registration rejection")
                return
            }
            #expect(text == "The username is already taken")
        } else {
            guard case .unexpectedResponse = error else {
                Issue.record("Expected invalid form response")
                return
            }
        }
        #expect(await transport.disconnectCount == 1)
        #expect(await transport.isConnected == false)
    }

    @Test
    func `form and registration go out on one connection with distinct ids`() async throws {
        let transport = MockTransport()
        let task = Task {
            let session = try await openSession(on: transport)
            let form = try await session.fetchForm()
            try await session.submit(.legacy(form.legacyFields.map { RegistrationModule.LegacyField(name: $0.name, value: "x") }))
            await session.close()
        }
        do {
            try await negotiate(transport)
            let get = try await awaitOutgoingIQ(on: transport, type: .get, namespace: XMPPNamespaces.register) { _ in true }
            // A reply to another request is not the form.
            await transport.simulateReceive("<iq type='result' id='other'/>")
            await transport.simulateReceive("<iq type='result' id='\(get.id)'><query xmlns='jabber:iq:register'><username/><nick/></query></iq>")
            let set = try await awaitOutgoingIQ(on: transport, type: .set, namespace: XMPPNamespaces.register) { _ in true }
            #expect(set.id != get.id)
            #expect(set.xml.contains("<nick>x</nick>"))
            await transport.simulateReceive("<iq type='result' id='\(set.id)'/>")
        } catch {
            task.cancel()
            await transport.disconnect()
            _ = await task.result
            throw error
        }
        try await task.value
        #expect(await transport.connectCount == 1)
        #expect(await transport.disconnectCount == 1)
    }

    @Test
    func `a registration after the server closed the stream asks to start over without reconnecting`() async throws {
        let transport = MockTransport()
        let opening = Task { try await openSession(on: transport) }
        do {
            try await negotiate(transport)
        } catch {
            opening.cancel()
            await transport.disconnect()
            _ = await opening.result
            throw error
        }
        let session = try await opening.value
        await transport.simulateReceive("</stream:stream>")

        let error = await #expect(throws: XMPPRegistrationClient.RegistrationClientError.self) {
            try await session.submit(.legacy([RegistrationModule.LegacyField(name: "username", value: "new-user")]))
        }
        guard case .connectionClosed = error else {
            Issue.record("Expected connectionClosed, got \(String(describing: error))")
            return
        }
        await session.close()
        #expect(await transport.connectCount == 1)
        #expect(await transport.isConnected == false)
    }

    private func openSession(on transport: MockTransport, domain: String = "example.com") async throws -> RegistrationSession {
        try await RegistrationSession.open(domain: domain, host: "example.com", port: 5222, transport: transport)
    }

    private func registrationTask(
        transport: MockTransport, register: Bool, domain: String = "example.com"
    ) -> Task<RegistrationModule.RegistrationForm?, any Error> {
        Task {
            guard register else {
                return try await XMPPRegistrationClient.retrieveForm(domain: domain, host: "example.com", transport: transport)
            }
            let session = try await openSession(on: transport, domain: domain)
            do {
                try await session.submit(.legacy([
                    RegistrationModule.LegacyField(name: "username", value: "new-user"),
                    RegistrationModule.LegacyField(name: "password", value: "secret")
                ]))
            } catch {
                await session.close()
                throw error
            }
            await session.close()
            return nil
        }
    }

    private func negotiate(_ transport: MockTransport) async throws {
        try await awaitSent(on: transport) { $0.hasPrefix("<?xml") || $0.hasPrefix("<stream:stream") }
        await transport.simulateReceive(testServerStreamOpen)
        await transport.simulateReceive(testFeaturesWithTLS)
        try await awaitSent(on: transport) { $0.contains("<starttls") }
        // Clear before triggering the next phase so its stream opening cannot match the first one.
        await transport.clearSentBytes()
        await transport.simulateReceive(testProceed)
        try await awaitSent(on: transport) { $0.hasPrefix("<?xml") || $0.hasPrefix("<stream:stream") }
        await transport.simulateReceive(testServerStreamOpen)
        await transport.simulateReceive(testFeaturesNoTLS)
    }

    @Test
    func `RegistrationClientError cases`() {
        let err1 = XMPPRegistrationClient.RegistrationClientError.connectionFailed("timeout")
        let err2 = XMPPRegistrationClient.RegistrationClientError.tlsNegotiationFailed
        let err3 = XMPPRegistrationClient.RegistrationClientError.registrationNotSupported
        let err4 = XMPPRegistrationClient.RegistrationClientError.registrationFailed("conflict")
        let err5 = XMPPRegistrationClient.RegistrationClientError.unexpectedResponse

        switch err1 {
        case let .connectionFailed(msg): #expect(msg == "timeout")
        case .tlsNegotiationFailed, .registrationNotSupported, .registrationFailed, .unexpectedResponse, .connectionClosed:
            Issue.record("Wrong case")
        }

        switch err2 {
        case .tlsNegotiationFailed: break
        case .connectionFailed, .registrationNotSupported, .registrationFailed, .unexpectedResponse, .connectionClosed:
            Issue.record("Wrong case")
        }

        switch err3 {
        case .registrationNotSupported: break
        case .connectionFailed, .tlsNegotiationFailed, .registrationFailed, .unexpectedResponse, .connectionClosed:
            Issue.record("Wrong case")
        }

        switch err4 {
        case let .registrationFailed(msg): #expect(msg == "conflict")
        case .connectionFailed, .tlsNegotiationFailed, .registrationNotSupported, .unexpectedResponse, .connectionClosed:
            Issue.record("Wrong case")
        }

        switch err5 {
        case .unexpectedResponse: break
        case .connectionFailed, .tlsNegotiationFailed, .registrationNotSupported, .registrationFailed, .connectionClosed:
            Issue.record("Wrong case")
        }
    }

    @Test(arguments: [
        (XMPPStanzaError?.none, "The server gave no reason"),
        (XMPPStanzaError(errorType: .cancel, condition: .conflict), "The username is already taken"),
        (XMPPStanzaError(errorType: .cancel, condition: .conflict, text: "Name reserved"), "Name reserved"),
        (XMPPStanzaError(errorType: .cancel, condition: .conflict, text: "  "), "The username is already taken"),
        (XMPPStanzaError(errorType: .modify, condition: .notAcceptable), "The recipient does not accept this request")
    ])
    func `Registration failure text reads the stanza error`(error: XMPPStanzaError?, expected: String) {
        #expect(XMPPRegistrationClient.registrationFailureText(error) == expected)
    }

    @Test
    func `Registration STARTTLS reopens the stream after the upgrade`() async throws {
        let mock = MockTransport()
        let connection = XMPPConnection(transport: mock)
        let negotiation = try await startNegotiation(on: connection)

        await mock.waitForSent(count: 1) // stream opening
        await mock.simulateReceive(testServerStreamOpen)
        await mock.simulateReceive(testFeaturesWithTLS)
        await mock.waitForSent(count: 2) // starttls element
        await mock.simulateReceive(testProceed)
        await mock.waitForSent(count: 3) // post-TLS stream opening
        await mock.simulateReceive(testServerStreamOpen)
        await mock.simulateReceive(testFeaturesNoTLS)

        try await negotiation.value
        let isTLS = await mock.isTLSUpgraded
        #expect(isTLS)

        await connection.disconnect()
    }

    @Test
    func `Registration treats a proceed without the TLS namespace as a refusal`() async throws {
        let mock = MockTransport()
        let connection = XMPPConnection(transport: mock)
        let negotiation = try await startNegotiation(on: connection)

        await mock.waitForSent(count: 1) // stream opening
        await mock.simulateReceive(testServerStreamOpen)
        await mock.simulateReceive(testFeaturesWithTLS)
        await mock.waitForSent(count: 2) // starttls element
        await mock.simulateReceive("<proceed/>")

        let error = await #expect(throws: XMPPRegistrationClient.RegistrationClientError.self) {
            try await negotiation.value
        }
        guard case .tlsNegotiationFailed = error else {
            Issue.record("Expected tlsNegotiationFailed, got \(String(describing: error))")
            return
        }
        let isTLS = await mock.isTLSUpgraded
        #expect(!isTLS)

        await connection.disconnect()
    }

    private func startNegotiation(on connection: XMPPConnection) async throws -> Task<Void, any Error> {
        try await connection.connect(host: "example.com", port: 5222)
        let reader = EventReader(connection.events)
        return Task {
            try await XMPPRegistrationClient.negotiateStream(
                connection: connection, reader: reader, domain: "example.com", serverName: "example.com"
            )
        }
    }

    @Test
    func `Retrieving a form for a domain with no A-label fails closed`() async {
        // The IDNA guard throws before any network I/O (a space is not LDH, so no A-label).
        await #expect(throws: XMPPRegistrationClient.RegistrationClientError.self) {
            _ = try await XMPPRegistrationClient.retrieveForm(domain: "bad domain.example")
        }
    }
}
