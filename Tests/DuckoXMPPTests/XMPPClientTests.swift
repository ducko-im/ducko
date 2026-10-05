// Split candidate.
// swiftlint:disable file_length
import DuckoTestSupport
import os
import Testing
@testable import DuckoXMPP

// MARK: - Test Helpers

/// Post-auth features with bind and session.
private let featuresBindSession = """
<features xmlns='http://etherx.jabber.org/streams'>\
<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>\
<session xmlns='urn:ietf:params:xml:ns:xmpp-session'/>\
</features>
"""

/// Session result.
private let sessionResult = "<iq type='result' id='ducko-2'/>"

/// Simulates a full connect handshake with STARTTLS on the mock transport.
/// The `initialFeatures` parameter controls the first features stanza — use `testFeaturesWithTLS`
/// for advertised STARTTLS or `testFeaturesNoTLS` for forced STARTTLS (RFC 7590 anti-stripping).
private func simulateTLSConnectFlow(_ mock: MockTransport, initialFeatures: String = testFeaturesWithTLS) async {
    await mock.waitForSent(count: 1) // stream opening
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(initialFeatures)
    await mock.waitForSent(count: 2) // starttls element
    await mock.simulateReceive(testProceed)
    await mock.waitForSent(count: 3) // post-TLS stream opening
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesNoTLS)
    await mock.waitForSent(count: 4) // auth element
    await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
    await mock.waitForSent(count: 5) // post-auth stream opening
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesBind)
    await mock.waitForSent(count: 6) // bind IQ
    await mock.simulateReceive(testBindResult)
}

/// Simulates a connect handshake with session establishment.
private func simulateSessionConnectFlow(_ mock: MockTransport) async {
    await mock.waitForSent(count: 1) // stream opening
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesNoTLS)
    await mock.waitForSent(count: 2) // auth element
    await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
    await mock.waitForSent(count: 3) // post-auth stream opening
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(featuresBindSession)
    await mock.waitForSent(count: 4) // bind IQ
    await mock.simulateReceive(testBindResult)
    await mock.waitForSent(count: 5) // session IQ
    await mock.simulateReceive(sessionResult)
}

// MARK: - Tests

enum XMPPClientTests { // swiftlint:disable:this type_body_length
    struct ConnectFlow {
        @Test
        func `Full connect with STARTTLS and PLAIN auth`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateTLSConnectFlow(mock)
            try await connectTask.value

            let isTLS = await mock.isTLSUpgraded
            #expect(isTLS)

            await disconnectFast(client)
        }

        @Test
        func `Connect without TLS`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let isTLS = await mock.isTLSUpgraded
            #expect(!isTLS)

            await disconnectFast(client)
        }

        @Test
        func `Forced STARTTLS succeeds when server accepts despite not advertising`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateTLSConnectFlow(mock, initialFeatures: testFeaturesNoTLS)
            try await connectTask.value

            let isTLS = await mock.isTLSUpgraded
            #expect(isTLS)

            await disconnectFast(client)
        }

        @Test
        func `Forced STARTTLS fails when server genuinely lacks TLS`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }

            // Server sends features without <starttls/> — client forces STARTTLS, server rejects
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesNoTLS)
            await mock.waitForSent(count: 2) // forced starttls element
            await mock.simulateReceive("<failure xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")

            do {
                try await connectTask.value
                throw XMPPClientError.unexpectedStreamState("Should have thrown")
            } catch let error as XMPPClientError {
                guard case .tlsRequired = error else {
                    throw XMPPClientError.unexpectedStreamState("Expected tlsRequired, got \(error)")
                }
            }

            await disconnectFast(client)
        }

        @Test
        func `Refused advertised STARTTLS reports a readable reason`() async {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesWithTLS)
            await mock.waitForSent(count: 2) // starttls element
            await mock.simulateReceive("<failure xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")

            await expectTLSNegotiationFailure(reason: "The server refused to start TLS", mock: mock) {
                try await connectTask.value
            }

            await disconnectFast(client)
        }

        @Test(arguments: [testFeaturesWithTLS, testFeaturesNoTLS])
        func `Plaintext after proceed fails advertised and forced STARTTLS`(initialFeatures: String) async {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(initialFeatures)
            await mock.waitForSent(count: 2) // starttls element
            // One chunk: a separate chunk could land after the client stops reading and be dropped by the mock.
            await mock.simulateReceive(testProceed + testInjectedMessage)

            await expectTLSNegotiationFailure(reason: "The server sent unexpected data after agreeing to start TLS", mock: mock) {
                try await connectTask.value
            }

            await disconnectFast(client)
        }

        @Test
        func `Plaintext pipelined with the features and proceed fails STARTTLS`() async {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesWithTLS + testProceed + testInjectedMessage)

            await expectTLSNegotiationFailure(reason: "The server sent unexpected data after agreeing to start TLS", mock: mock) {
                try await connectTask.value
            }

            await disconnectFast(client)
        }

        @Test
        func `A proceed without the TLS namespace is a refusal`() async {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesWithTLS)
            await mock.waitForSent(count: 2) // starttls element
            await mock.simulateReceive("<proceed/>")

            await expectTLSNegotiationFailure(reason: "The server refused to start TLS", mock: mock) {
                try await connectTask.value
            }

            await disconnectFast(client)
        }

        @Test
        func `Connect with legacy session establishment`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateSessionConnectFlow(mock)
            try await connectTask.value

            await disconnectFast(client)
        }

        @Test
        func `Connected event includes full JID`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .connected = event { return true }
                    return false
                }
            }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let events = try await eventsTask.value
            guard case let .connected(jid) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected connected event")
            }
            #expect(jid.bareJID.localPart == "user")
            #expect(jid.bareJID.domainPart == "example.com")
            #expect(jid.resourcePart == "ducko")

            await disconnectFast(client)
        }
    }

    struct AuthFailure {
        @Test
        func `Auth failure emits event and throws`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "wrong"),
                transport: mock, requireTLS: false
            )

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .authenticationFailed = event { return true }
                    return false
                }
            }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }

            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesNoTLS)
            await mock.waitForSent(count: 2) // auth element
            await mock.simulateReceive(
                "<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><not-authorized/></failure>"
            )

            do {
                try await connectTask.value
                throw XMPPClientError.unexpectedStreamState("Should have thrown")
            } catch is XMPPClientError {
                // Expected
            }

            let events = try await eventsTask.value
            guard case let .authenticationFailed(message) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected authenticationFailed event")
            }
            #expect(message == "Incorrect username or password")

            await disconnectFast(client)
        }
    }

    struct IQTracking {
        @Test
        func `sendIQ returns result child element`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let iqTask = Task {
                var iq = XMPPIQ(type: .get, id: "test-iq-1")
                let query = XMLElement(name: "query", namespace: "jabber:iq:roster")
                iq.element.addChild(query)
                return try await client.sendIQ(iq)
            }

            await mock.waitForSent(count: 5) // connect sends 4, test IQ is 5
            await mock.simulateReceive(
                "<iq type='result' id='test-iq-1'><query xmlns='jabber:iq:roster'><item jid='contact@example.com'/></query></iq>"
            )

            let result = try await iqTask.value
            #expect(result?.name == "query")

            await disconnectFast(client)
        }

        @Test
        func `sendIQ throws stanza error for error response`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let iqTask = Task {
                let iq = XMPPIQ(type: .get, id: "test-iq-2")
                return try await client.sendIQ(iq)
            }

            await mock.waitForSent(count: 5) // connect sends 4, test IQ is 5
            await mock.simulateReceive(
                "<iq type='error' id='test-iq-2'><error type='cancel'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
            )

            do {
                _ = try await iqTask.value
                Issue.record("Expected XMPPStanzaError to be thrown")
            } catch let error as XMPPStanzaError {
                #expect(error.errorType == .cancel)
                #expect(error.condition == .itemNotFound)
            }

            await disconnectFast(client)
        }

        @Test
        func `sendIQ on disconnected client throws notConnected`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let iq = XMPPIQ(type: .get, id: "test-iq-pre-connect")
            do {
                _ = try await client.sendIQ(iq)
                Issue.record("Expected XMPPClientError.notConnected to be thrown")
            } catch let error as XMPPClientError {
                guard case .notConnected = error else {
                    Issue.record("Expected .notConnected, got \(error)")
                    return
                }
            }
        }

        @Test
        func `sendIQ during a stalled handshake throws notConnected`() async throws {
            // Pause the mock partway through the connect flow — after stream
            // opening and features but before STARTTLS proceed — so the client
            // is stuck in `.negotiatingTLS`. A fire-and-forget sendIQ from a
            // module reacting to an event must not be allowed to leak an IQ
            // onto the wire pre-handshake, even though `state != .connected`
            // is the only state that already had a guard via `send()`.
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesWithTLS)
            await mock.waitForSent(count: 2) // <starttls/> sent — handshake now suspended waiting for <proceed>

            let iq = XMPPIQ(type: .get, id: "test-iq-mid-handshake")
            do {
                _ = try await client.sendIQ(iq)
                Issue.record("Expected XMPPClientError.notConnected to be thrown mid-handshake")
            } catch let error as XMPPClientError {
                guard case .notConnected = error else {
                    Issue.record("Expected .notConnected, got \(error)")
                    return
                }
            }

            // Tear down: drive STARTTLS to a failure so the connectTask exits.
            await mock.simulateReceive("<failure xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
            _ = try? await connectTask.value
        }

        @Test
        func `A stanza sent during a stalled handshake is refused and never written`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesWithTLS)
            await mock.waitForSent(count: 2) // <starttls/> sent — handshake now suspended waiting for <proceed>

            await #expect(throws: XMPPClientError.self) {
                try await client.send(XMPPPresence(type: .unavailable))
            }
            #expect(await mock.sentBytes.count == 2)

            // Tear down: drive STARTTLS to a failure so the connectTask exits.
            await mock.simulateReceive("<failure xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
            _ = try? await connectTask.value
        }

        @Test
        func `Disconnect cancels pending IQs`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let iqTask = Task {
                let iq = XMPPIQ(type: .get, id: "test-iq-3")
                return try await client.sendIQ(iq)
            }

            await mock.waitForSent(count: 5) // connect sends 4, test IQ is 5
            await disconnectFast(client)

            do {
                _ = try await iqTask.value
                throw XMPPClientError.unexpectedStreamState("Should have thrown")
            } catch is XMPPClientError {
                // Expected: notConnected
            }
        }
    }

    struct StanzaDispatch {
        @Test
        func `Chat message dispatches to ChatModule`() async throws {
            let mock = MockTransport()
            let chatModule = ChatModule()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(chatModule)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageReceived = event { return true }
                    return false
                }
            }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            await mock.simulateReceive(
                "<message type='chat' from='contact@example.com/res'><body>Hello!</body></message>"
            )

            let events = try await eventsTask.value
            guard case let .messageReceived(message) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageReceived event")
            }
            #expect(message.body == "Hello!")
            #expect(message.from?.description == "contact@example.com/res")

            await disconnectFast(client)
        }

        @Test
        func `Presence stanza emits presenceReceived event`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .presenceReceived = event { return true }
                    return false
                }
            }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            await mock.simulateReceive(
                "<presence from='contact@example.com/res'><show>away</show></presence>"
            )

            let events = try await eventsTask.value
            guard case let .presenceReceived(presence) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected presenceReceived event")
            }
            #expect(presence.show == .away)

            await disconnectFast(client)
        }

        @Test
        func `IQ stanza emits iqReceived event`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .iqReceived = event { return true }
                    return false
                }
            }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            await mock.simulateReceive(
                "<iq type='get' from='example.com' id='server-1'><query xmlns='jabber:iq:version'/></iq>"
            )

            let events = try await eventsTask.value
            guard case let .iqReceived(iq) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected iqReceived event")
            }
            #expect(iq.isGet)
            #expect(iq.id == "server-1")

            await disconnectFast(client)
        }
    }

    struct Disconnection {
        @Test
        func `Events stream terminates after disconnect`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            await disconnectFast(client)

            // Other disconnect tests use `collectEvents`, which breaks on a
            // predicate match and would still pass if `finish()` were dropped.
            // Drain the stream to natural completion so this regression is
            // caught — `cleanUp(reason:)` must finish the event continuation.
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in client.events {}
                }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(500))
                    throw XMPPClientError.timeout
                }
                try await group.next()
                group.cancelAll()
            }
        }

        @Test
        func `Stream close emits disconnected event`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .disconnected = event { return true }
                    return false
                }
            }

            try? await Task.sleep(for: .milliseconds(50))
            await mock.simulateReceive("</stream:stream>")
            try? await Task.sleep(for: .milliseconds(50))

            let events = try await eventsTask.value
            guard case let .disconnected(reason) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected disconnected event")
            }
            guard case let .streamError(condition, text) = reason else {
                throw XMPPClientError.unexpectedStreamState("Expected streamError reason, got \(reason)")
            }
            #expect(condition == nil)
            #expect(text == nil)
            let isConnected = await mock.isConnected
            #expect(!isConnected)
        }

        @Test
        func `A second disconnect waits for a disconnect still closing the stream`() async throws {
            let mock = MockTransport(repliesToStreamClose: false)
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let firstDisconnect = Task { await client.disconnect(streamCloseTimeout: .milliseconds(300)) }
            _ = await mock.waitForSent { $0.contains("</stream:stream>") }
            await disconnectFast(client)
            let isConnected = await mock.isConnected
            #expect(!isConnected)
            await firstDisconnect.value
        }

        @Test
        func `A connect after disconnect fails instead of opening a session`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            await disconnectFast(client)
            let outcome = try await boundedOutcome {
                try await client.connect(host: "example.com", port: 5222)
            }

            let result = try #require(outcome)
            #expect(throws: (any Error).self) { try result.get() }
            let isConnected = await mock.isConnected
            #expect(!isConnected)
            #expect(await mock.connectedHost == nil)
        }
    }

    struct StreamCloseHandshake {
        @Test
        func `disconnect resolves on the server's stream-close reply, not the timeout`() async throws {
            let mock = MockTransport(repliesToStreamClose: false)
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let reasonTask = Task { () -> DisconnectReason? in
                for await event in client.events {
                    if case let .disconnected(reason) = event { return reason }
                }
                return nil
            }

            // A long timeout proves resolution came from the reply: a broken reply path would stall for the full
            // 5 s and blow past the 500 ms bound, rather than masking the regression behind a quick fallback.
            let clock = ContinuousClock()
            let start = clock.now
            let disconnectTask = Task { await client.disconnect(streamCloseTimeout: .seconds(5)) }

            let sentClose = await mock.waitForSent(matching: { $0.contains("</stream:stream>") })
            #expect(sentClose != nil)
            await mock.simulateReceive("</stream:stream>")

            await disconnectTask.value
            #expect(clock.now - start < .milliseconds(500))

            guard case .requested = await reasonTask.value else {
                Issue.record("Expected .requested disconnect reason")
                return
            }
        }

        @Test
        func `disconnect falls back to teardown when no stream-close reply arrives`() async throws {
            let mock = MockTransport(repliesToStreamClose: false)
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let reasonTask = Task { () -> DisconnectReason? in
                for await event in client.events {
                    if case let .disconnected(reason) = event { return reason }
                }
                return nil
            }

            // Never inject the server's closing tag — the bounded fallback must still complete the disconnect.
            await client.disconnect(streamCloseTimeout: .milliseconds(50))

            guard case .requested = await reasonTask.value else {
                Issue.record("Expected .requested disconnect reason")
                return
            }
        }

        @Test
        func `stream-close reply arriving the instant the close is sent resolves without hanging`() async throws {
            let mock = MockTransport(repliesToStreamClose: false)
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let disconnectTask = Task { await client.disconnect() }

            // Inject the reply only once the close is confirmed on the wire. Register-before-send guarantees the
            // waiter slot is already installed, so a reply at the earliest possible moment resolves it.
            let sentClose = await mock.waitForSent(matching: { $0.contains("</stream:stream>") })
            #expect(sentClose != nil)
            await mock.simulateReceive("</stream:stream>")

            await disconnectTask.value

            await #expect(throws: XMPPClientError.self) {
                _ = try await client.sendIQ(XMPPIQ(type: .get, id: "post-disconnect"))
            }
        }

        @Test
        func `concurrent teardown during the stream-close wait completes the disconnect`() async throws {
            let mock = MockTransport(repliesToStreamClose: false)
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let reasonTask = Task { () -> DisconnectReason? in
                for await event in client.events {
                    if case let .disconnected(reason) = event { return reason }
                }
                return nil
            }

            // A long timeout parks disconnect on the waiter; a stream error winning the race must drain the
            // waiter via cleanUp so the disconnect completes promptly. The 500 ms bound (vs the 5 s timeout)
            // fails fast if the drain regresses.
            let clock = ContinuousClock()
            let start = clock.now
            let disconnectTask = Task { await client.disconnect(streamCloseTimeout: .seconds(5)) }

            let sentClose = await mock.waitForSent(matching: { $0.contains("</stream:stream>") })
            #expect(sentClose != nil)
            await mock.simulateReceive(
                "<error><system-shutdown xmlns='urn:ietf:params:xml:ns:xmpp-streams'/></error>"
            )

            await disconnectTask.value
            #expect(clock.now - start < .milliseconds(500))
            guard case .requested = await reasonTask.value else {
                Issue.record("Expected .requested disconnect reason")
                return
            }
        }
    }

    struct SeeOtherHost {
        @Test
        func `Stream error see-other-host emits redirect with host and port`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .disconnected = event { return true }
                    return false
                }
            }

            try? await Task.sleep(for: .milliseconds(50))
            await mock.simulateReceive("""
            <error>\
            <see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>other.example.com:5222</see-other-host>\
            </error>
            """)

            let events = try await eventsTask.value
            guard case let .disconnected(reason) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected disconnected event")
            }
            guard case let .redirect(host, port) = reason else {
                throw XMPPClientError.unexpectedStreamState("Expected redirect reason, got \(reason)")
            }
            #expect(host == "other.example.com")
            #expect(port == 5222)
        }

        @Test
        func `See-other-host without port`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .disconnected = event { return true }
                    return false
                }
            }

            try? await Task.sleep(for: .milliseconds(50))
            await mock.simulateReceive("""
            <error>\
            <see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>other.example.com</see-other-host>\
            </error>
            """)

            let events = try await eventsTask.value
            guard case let .disconnected(reason) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected disconnected event")
            }
            guard case let .redirect(host, port) = reason else {
                throw XMPPClientError.unexpectedStreamState("Expected redirect reason, got \(reason)")
            }
            #expect(host == "other.example.com")
            #expect(port == nil)
        }

        @Test
        func `IPv6 see-other-host with port`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .disconnected = event { return true }
                    return false
                }
            }

            try? await Task.sleep(for: .milliseconds(50))
            await mock.simulateReceive("""
            <error>\
            <see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>[::1]:5222</see-other-host>\
            </error>
            """)

            let events = try await eventsTask.value
            guard case let .disconnected(reason) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected disconnected event")
            }
            guard case let .redirect(host, port) = reason else {
                throw XMPPClientError.unexpectedStreamState("Expected redirect reason, got \(reason)")
            }
            #expect(host == "::1")
            #expect(port == 5222)
        }
    }

    struct Builder {
        @Test
        func `Builder creates client with modules`() async {
            let mock = MockTransport()
            var builder = XMPPClientBuilder(domain: "example.com", username: "user", password: "pass")
            builder.withTransport(mock)
            builder.withModule(ChatModule())
            let client = await builder.build()

            let chatModule = await client.module(ofType: ChatModule.self)
            #expect(chatModule != nil)

            await disconnectFast(client)
        }
    }

    struct ResourceBinding {
        @Test
        func `Bind IQ includes resource when preferredResource is set`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false,
                preferredResource: "myphone"
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let bindIQ = sentStrings.first { $0.contains("<bind") && $0.contains("urn:ietf:params:xml:ns:xmpp-bind") }
            #expect(bindIQ?.contains("<resource>myphone</resource>") == true)

            await disconnectFast(client)
        }

        @Test
        func `Bind IQ normalizes preferredResource via OpaqueString`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false,
                preferredResource: "my\u{00A0}phone" // NO-BREAK SPACE → U+0020
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let bindIQ = sentStrings.first { $0.contains("<bind") && $0.contains("urn:ietf:params:xml:ns:xmpp-bind") }
            #expect(bindIQ?.contains("<resource>my phone</resource>") == true)

            await disconnectFast(client)
        }

        @Test
        func `Bind IQ omits resource when preferredResource fails to normalize`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false,
                preferredResource: "bad\u{0007}resource" // control character → OpaqueString rejects
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let bindIQ = sentStrings.first { $0.contains("<bind") && $0.contains("urn:ietf:params:xml:ns:xmpp-bind") }
            #expect(bindIQ?.contains("<resource>") != true)

            await disconnectFast(client)
        }

        @Test
        func `xn-- domain is canonicalized to its U-label for the stream`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "xn--bcher-kva.example",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connectWithTLS(host: "host.example", port: 5223) }
            await simulateDirectTLSConnect(mock)
            try await connectTask.value

            #expect(await mock.tlsServerName == "xn--bcher-kva.example")
            let sentData = await mock.sentBytes
            let streamOpen = try #require(sentData.first.map { String(decoding: $0, as: UTF8.self) })
            #expect(streamOpen.contains("bücher.example"))

            await disconnectFast(client)
        }

        @Test
        func `Connect fails closed for a domain with no A-label`() async {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "bad domain.example", // space is not LDH; no A-label can be derived
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await #expect(throws: XMPPClientError.self) {
                try await client.connect(host: "host.example", port: 5222)
            }
        }

        @Test
        func `IDN domain uses the A-label for TLS SNI while the stream keeps the U-label`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "bücher.example",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connectWithTLS(host: "host.example", port: 5223) }
            await simulateDirectTLSConnect(mock)
            try await connectTask.value

            #expect(await mock.tlsServerName == "xn--bcher-kva.example")
            let sentData = await mock.sentBytes
            let streamOpen = try #require(sentData.first.map { String(decoding: $0, as: UTF8.self) })
            #expect(streamOpen.contains("bücher.example"))
            #expect(!streamOpen.contains("xn--bcher-kva.example"))

            await disconnectFast(client)
        }

        @Test
        func `Bind IQ omits resource when preferredResource is nil`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let bindIQ = sentStrings.first { $0.contains("<bind") && $0.contains("urn:ietf:params:xml:ns:xmpp-bind") }
            #expect(bindIQ?.contains("<resource>") != true)

            await disconnectFast(client)
        }
    }

    struct IDGeneration {
        @Test
        func `IDs are sequential`() async {
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass")
            )
            let id1 = client.generateID()
            let id2 = client.generateID()
            #expect(id1 == "ducko-1")
            #expect(id2 == "ducko-2")

            await disconnectFast(client)
        }
    }

    // MARK: - IQ Timeout

    struct IQTimeoutTests {
        @Test
        func `IQ times out when no response arrives`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let iqTask = Task {
                let iq = XMPPIQ(type: .get, id: "test-timeout")
                return try await client.sendIQ(iq, timeout: .milliseconds(200))
            }

            // Don't respond — let the timeout expire
            do {
                _ = try await iqTask.value
                throw XMPPClientError.unexpectedStreamState("Should have thrown timeout")
            } catch let error as XMPPClientError {
                guard case .timeout = error else {
                    throw XMPPClientError.unexpectedStreamState("Expected timeout, got \(error)")
                }
            }

            await disconnectFast(client)
        }
    }

    // MARK: - Stanza Interceptor

    struct StanzaInterceptorTests {
        @Test
        func `Consuming interceptor blocks message dispatch`() async throws {
            let mock = MockTransport()
            let interceptor = MessageConsumingInterceptor()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.addInterceptor(interceptor)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            // Collect events until a presence arrives
            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .presenceReceived = event { return true }
                    return false
                }
            }

            // Send a message (should be consumed) then a presence (should pass through)
            await mock.simulateReceive(
                "<message type='chat' from='contact@example.com/res'><body>Blocked!</body></message>"
            )
            await mock.simulateReceive(
                "<presence from='contact@example.com/res'/>"
            )

            let events = try await eventsTask.value
            // Should have presenceReceived but NOT messageReceived
            let hasMessage = events.contains { if case .messageReceived = $0 { return true }; return false }
            let hasPresence = events.contains { if case .presenceReceived = $0 { return true }; return false }
            #expect(!hasMessage)
            #expect(hasPresence)

            await disconnectFast(client)
        }

        @Test
        func `Non-consuming interceptor allows normal dispatch`() async throws {
            let mock = MockTransport()
            let interceptor = PassthroughInterceptor()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.addInterceptor(interceptor)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<message type='chat' from='contact@example.com/res'><body>Allowed!</body></message>"
            )

            let events = try await eventsTask.value
            guard case let .messageReceived(message) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageReceived event")
            }
            #expect(message.body == "Allowed!")

            await disconnectFast(client)
        }
    }

    // MARK: - Module Features

    struct ModuleFeatureTests {
        @Test
        func `availableFeatures aggregates from registered modules`() async {
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass")
            )
            await client.register(FeatureModuleA())
            await client.register(FeatureModuleB())

            let features = await client.availableFeatures
            #expect(features.count == 3)
            #expect(features.contains("urn:xmpp:feature-a1"))
            #expect(features.contains("urn:xmpp:feature-a2"))
            #expect(features.contains("urn:xmpp:feature-b1"))

            await disconnectFast(client)
        }

        @Test
        func `Module with no features returns empty set`() async {
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass")
            )
            await client.register(NoFeatureModule())

            let features = await client.availableFeatures
            #expect(features.isEmpty)

            await disconnectFast(client)
        }
    }

    // MARK: - Module Disconnect Hook

    struct DisconnectHookTests {
        @Test
        func `handleDisconnect is called on clean disconnect`() async throws {
            let mock = MockTransport()
            let module = DisconnectTrackingModule()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(module)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            #expect(!module.wasDisconnected)
            await disconnectFast(client)
            #expect(module.wasDisconnected)
        }

        @Test
        func `handleDisconnect runs once when a stream error ends the stream`() async throws {
            let mock = MockTransport()
            let module = DisconnectCountingModule()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(module)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .disconnected = event { return true }
                    return false
                }
            }

            try? await Task.sleep(for: .milliseconds(50))
            await mock.simulateReceive(
                "<stream:error><conflict xmlns='urn:ietf:params:xml:ns:xmpp-streams'/></stream:error>"
            )
            _ = try await eventsTask.value

            #expect(module.disconnectCount == 1)
        }

        @Test
        func `disconnect waits for a teardown already in progress`() async throws {
            let mock = MockTransport(repliesToStreamClose: false)
            let module = GatedDisconnectModule()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(module)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let disconnectTask = Task { await client.disconnect(streamCloseTimeout: .milliseconds(300)) }
            _ = await mock.waitForSent { $0.contains("</stream:stream>") }
            // The stream error starts a teardown that holds in the module. disconnect() reaches it once its stream-close
            // wait times out, and must keep waiting until the module is released.
            await mock.simulateReceive(
                "<stream:error><conflict xmlns='urn:ietf:params:xml:ns:xmpp-streams'/></stream:error>"
            )
            let entered = try await boundedOutcome { await module.entered.wait() }
            try #require(entered != nil)

            let early = try await boundedOutcome(timeout: .milliseconds(600)) { await disconnectTask.value }
            #expect(early == nil)

            await module.released.signal()
            await disconnectTask.value
            let isConnected = await mock.isConnected
            #expect(!isConnected)
        }

        @Test
        func `disconnect waits for a teardown a stream error already started`() async throws {
            let mock = MockTransport()
            let module = GatedDisconnectModule()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(module)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            await mock.simulateReceive(
                "<stream:error><conflict xmlns='urn:ietf:params:xml:ns:xmpp-streams'/></stream:error>"
            )
            let entered = try await boundedOutcome { await module.entered.wait() }
            try #require(entered != nil)

            let disconnectTask = Task { await client.disconnect(streamCloseTimeout: .milliseconds(20)) }
            let early = try await boundedOutcome(timeout: .milliseconds(300)) { await disconnectTask.value }
            #expect(early == nil)

            await module.released.signal()
            await disconnectTask.value
            let isConnected = await mock.isConnected
            #expect(!isConnected)
        }

        @Test
        func `A module calling disconnect from handleDisconnect doesn't stall the teardown`() async throws {
            let mock = MockTransport()
            let module = ReentrantDisconnectModule()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            module.attach(client)
            await client.register(module)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let disconnected = try await boundedOutcome { await disconnectFast(client) }
            #expect(disconnected != nil)
            let isConnected = await mock.isConnected
            #expect(!isConnected)
        }
    }
}

// MARK: - Test Mocks

/// Interceptor that consumes all `<message>` stanzas, passes everything else through.
private final class MessageConsumingInterceptor: StanzaInterceptor {
    func processIncoming(_ element: XMLElement) -> Bool {
        element.name == "message"
    }

    func processOutgoing(_ element: XMLElement) {}
}

/// Interceptor that never consumes anything.
private final class PassthroughInterceptor: StanzaInterceptor {
    func processIncoming(_ element: XMLElement) -> Bool {
        false
    }

    func processOutgoing(_ element: XMLElement) {}
}

/// Module that declares features for testing `availableFeatures` aggregation.
private final class FeatureModuleA: XMPPModule {
    var features: [String] {
        ["urn:xmpp:feature-a1", "urn:xmpp:feature-a2"]
    }

    func setUp(_ context: ModuleContext) {}
}

/// Module that declares features for testing `availableFeatures` aggregation.
private final class FeatureModuleB: XMPPModule {
    var features: [String] {
        ["urn:xmpp:feature-b1"]
    }

    func setUp(_ context: ModuleContext) {}
}

private final class NoFeatureModule: XMPPModule {
    func setUp(_ context: ModuleContext) {}
}

/// Module that tracks whether `handleDisconnect()` was called.
private final class DisconnectTrackingModule: XMPPModule, Sendable {
    private let _disconnected = OSAllocatedUnfairLock(initialState: false)

    var wasDisconnected: Bool {
        _disconnected.withLock { $0 }
    }

    func setUp(_ context: ModuleContext) {}

    func handleDisconnect() async {
        _disconnected.withLock { $0 = true }
    }
}

/// Module that counts `handleDisconnect()` calls. The first call stays open for a while, so a reentrant teardown
/// has time to arrive and call it again.
private final class DisconnectCountingModule: XMPPModule, Sendable {
    private let calls = OSAllocatedUnfairLock(initialState: 0)

    var disconnectCount: Int {
        calls.withLock { $0 }
    }

    func setUp(_ context: ModuleContext) {}

    func handleDisconnect() async {
        let count = calls.withLock { calls in
            calls += 1
            return calls
        }
        guard count == 1 else { return }
        let deadline = ContinuousClock.now + .milliseconds(200)
        while disconnectCount == 1, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Module whose `handleDisconnect()` signals `entered`, then stays open until `released` is signaled.
private final class GatedDisconnectModule: XMPPModule, Sendable {
    let entered = AsyncSemaphore()
    let released = AsyncSemaphore()

    func setUp(_ context: ModuleContext) {}

    func handleDisconnect() async {
        await entered.signal()
        await released.wait()
    }
}

/// Module whose `handleDisconnect()` calls back into `disconnect()` on its client.
private final class ReentrantDisconnectModule: XMPPModule, Sendable {
    private let client = OSAllocatedUnfairLock<XMPPClient?>(initialState: nil)

    func attach(_ client: XMPPClient) {
        self.client.withLock { $0 = client }
    }

    func setUp(_ context: ModuleContext) {}

    func handleDisconnect() async {
        guard let client = client.withLock({ $0 }) else { return }
        await disconnectFast(client)
    }
}
