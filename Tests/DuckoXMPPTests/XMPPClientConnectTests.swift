import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Diagnostic tests verifying EventReader + connection.events pattern

private let streamOpen =
    "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' from='example.com' version='1.0'>"

private let featuresNoTLS = """
<features xmlns='http://etherx.jabber.org/streams'>\
<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\
<mechanism>PLAIN</mechanism>\
</mechanisms>\
</features>
"""

private final class TestReader: @unchecked Sendable {
    private var iterator: AsyncStream<XMLStreamEvent>.Iterator
    init(_ stream: AsyncStream<XMLStreamEvent>) {
        self.iterator = stream.makeAsyncIterator()
    }

    func next() async -> XMLStreamEvent? {
        await iterator.next()
    }
}

// MARK: - Stream reset after SASL re-stream

private actor HandshakeActor {
    private let connection: XMPPConnection

    init(transport: any XMPPTransport) {
        self.connection = XMPPConnection(transport: transport)
    }

    func run() async throws {
        try await connection.connect(host: "example.com", port: 5222)
        let reader = TestReader(connection.events)

        // Open stream
        try await connection.send(XMPPStreamWriter.streamOpening(to: "example.com"))

        // Await features (2 events)
        let e1 = await reader.next()
        guard case .streamOpened = e1 else {
            throw XMPPClientError.unexpectedStreamState("Expected .streamOpened")
        }
        let e2 = await reader.next()
        guard case let .stanzaReceived(features) = e2, features.name == "features" else {
            throw XMPPClientError.unexpectedStreamState("Expected features")
        }

        // Send auth
        var auth = XMLElement(name: "auth", namespace: "urn:ietf:params:xml:ns:xmpp-sasl")
        auth.setAttribute("mechanism", value: "PLAIN")
        auth.addText("AHVzZXIAcGFzcw==")
        try await connection.send(XMPPStreamWriter.stanza(auth))

        // Await auth response
        let e3 = await reader.next()
        guard case let .stanzaReceived(success) = e3, success.name == "success" else {
            throw XMPPClientError.unexpectedStreamState("Expected success")
        }

        // Re-open stream (reset parser for new XML document)
        await connection.resetStream()
        try await connection.send(XMPPStreamWriter.streamOpening(to: "example.com"))

        // Await features again (2 more events)
        let e4 = await reader.next()
        guard case .streamOpened = e4 else {
            throw XMPPClientError.unexpectedStreamState("Expected .streamOpened (post-auth)")
        }
        let e5 = await reader.next()
        guard case let .stanzaReceived(features2) = e5, features2.name == "features" else {
            throw XMPPClientError.unexpectedStreamState("Expected features (post-auth)")
        }

        await connection.disconnect()
    }
}

@Test
func `Parser reset enables post-SASL stream re-open`() async throws {
    let mock = MockTransport()
    let actor = HandshakeActor(transport: mock)

    let task = Task { try await actor.run() }

    // 1. Stream open + features
    await mock.waitForSent(count: 1) // stream opening
    await mock.simulateReceive(streamOpen)
    await mock.simulateReceive(featuresNoTLS)

    // 2. Auth success
    await mock.waitForSent(count: 2) // auth element
    await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")

    // 3. Post-auth stream open + bind features
    await mock.waitForSent(count: 3) // post-auth stream opening
    await mock.simulateReceive(streamOpen)
    await mock.simulateReceive("""
    <features xmlns='http://etherx.jabber.org/streams'>\
    <bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>\
    </features>
    """)

    try await task.value
}

// MARK: - Direct TLS Connect

@Test
func `Direct TLS connect skips STARTTLS`() async throws {
    let mock = MockTransport()
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock,
        requireTLS: false, allowsPLAIN: true
    )

    let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
    await simulateDirectTLSConnect(mock)

    try await connectTask.value

    // Transport should report TLS active (set by connectWithTLS on MockTransport)
    let isTLS = await mock.isTLSUpgraded
    #expect(isTLS)

    // Verify no STARTTLS stanza was sent — sent bytes should be:
    // 1. stream opening, 2. auth, 3. post-auth stream opening, 4. bind IQ
    let sentCount = await mock.sentBytes.count
    #expect(sentCount == 4)

    await disconnectFast(client)
}

// MARK: - Browser Sign-In Fixtures

/// A client signing in as `user@example.com` with an access token, with the modules whose traffic starts a session:
/// the roster GET, the initial presence, and OMEMO's device-list fetch and publish. The mock answers their IQs, so a
/// session that passes sign-in finishes connecting. It leaves resource binding to the test, which chooses the bound
/// JID.
struct BearerSessionFixture {
    let client: XMPPClient
    let omemoModule: OMEMOModule

    init(mock: MockTransport, sm: StreamManagementModule? = nil) async throws {
        self.client = XMPPClient(
            domain: "example.com", credentials: .init(username: "user", secret: .bearerToken("token")), transport: mock,
            requireTLS: false
        )
        let pepModule = PEPModule()
        self.omemoModule = OMEMOModule(pepModule: pepModule)
        try omemoModule.configureIdentity(makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1]).data)
        if let sm {
            await client.register(sm)
            await client.addInterceptor(sm)
        }
        await client.register(RosterModule())
        await client.register(PresenceModule())
        await client.register(pepModule)
        await client.register(omemoModule)
        await mock.autoReply { stanza in
            guard stanza.hasPrefix("<iq "), !stanza.contains(XMPPNamespaces.bind), !stanza.contains("type=\"result\""),
                  let id = extractIQID(from: stanza) else { return nil }
            if stanza.contains(XMPPNamespaces.roster) {
                return "<iq type='result' id='\(id)'><query xmlns='\(XMPPNamespaces.roster)'/></iq>"
            }
            return "<iq type='result' id='\(id)'/>"
        }
    }

    /// The IQs, presences and messages `mock` carried, other than the resource-binding IQ.
    static func sessionTraffic(on mock: MockTransport) async -> [XMLElement] {
        await sentElements(on: mock).filter { element in
            switch element.name {
            case "iq": element.child(named: "bind", namespace: XMPPNamespaces.bind) == nil
            case "presence", "message": true
            default: false
            }
        }
    }

    /// Expects the roster GET, the initial presence and an OMEMO device-list request on `mock`.
    func expectSessionTraffic(on mock: MockTransport, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        _ = try await awaitSent(on: mock) { $0.contains(XMPPNamespaces.omemoDevices) }
        let traffic = await Self.sessionTraffic(on: mock)
        #expect(traffic.contains { $0.child(named: "query", namespace: XMPPNamespaces.roster) != nil }, sourceLocation: sourceLocation)
        #expect(traffic.contains { $0.name == "presence" }, sourceLocation: sourceLocation)
    }

    /// Expects `connect` to fail with `.accountMismatch` on the error and the event, before any session traffic.
    func expectAccountMismatch(
        _ connect: Task<Void, any Error>, events: Task<[XMPPEvent], any Error>, mock: MockTransport,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let error = try await boundedFailure(of: connect)
        guard case let .authenticationFailed(failure) = error as? XMPPClientError else {
            Issue.record("Expected authenticationFailed, got \(String(describing: error))", sourceLocation: sourceLocation)
            await disconnectFast(client)
            return
        }
        #expect(failure.kind == .accountMismatch, sourceLocation: sourceLocation)
        #expect(failure.message.hasSuffix(", not user@example.com"), sourceLocation: sourceLocation)
        guard case let .authenticationFailed(emitted) = try await events.value.last else {
            Issue.record("Expected an authenticationFailed event", sourceLocation: sourceLocation)
            return
        }
        #expect(emitted == failure, sourceLocation: sourceLocation)
        #expect(await Self.sessionTraffic(on: mock).isEmpty, sourceLocation: sourceLocation)
        #expect(await !(mock.sentBytes.contains { String(decoding: $0, as: UTF8.self).contains(XMPPNamespaces.omemoDevices) }), sourceLocation: sourceLocation)
        #expect(await !mock.isConnected, sourceLocation: sourceLocation)
    }

    /// The client's events up to its first sign-in failure.
    func authenticationEvents() -> Task<[XMPPEvent], any Error> {
        Task { try await collectEvents(from: client) { if case .authenticationFailed = $0 { true } else { false } } }
    }
}

/// The stream header the client sent as its `index`th write, or nil when that write is not one.
private func streamHeader(_ index: Int, on mock: MockTransport) async -> String? {
    let sent = await mock.sentBytes
    guard sent.indices.contains(index) else { return nil }
    let header = String(decoding: sent[index], as: UTF8.self)
    return header.contains("<stream:stream") ? header : nil
}

// MARK: - Stream Header and Browser Sign-In

enum XMPPClientConnectTests {
    struct StreamHeader {
        @Test(arguments: [SignInSecret.password("pencil"), .bearerToken("token")])
        func `The header names the account only once STARTTLS protects the stream`(secret: SignInSecret) async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com", credentials: .init(username: "user", secret: secret), transport: mock, allowsPLAIN: true
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesWithTLS)
            await mock.waitForSent(count: 2) // starttls
            await mock.simulateReceive(testProceed)
            await mock.waitForSent(count: 3) // post-TLS stream opening

            let first = try #require(await streamHeader(0, on: mock))
            let afterTLS = try #require(await streamHeader(2, on: mock))
            #expect(!first.contains("from="))
            #expect(afterTLS.contains("from=\"user@example.com\""))

            await mock.simulateDisconnect()
            _ = try? await connectTask.value
        }

        @Test
        func `A direct-TLS stream names the account in its first header`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com", credentials: .init(username: "user", password: "pencil"), transport: mock, allowsPLAIN: true
            )

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await mock.waitForSent(count: 1) // stream opening

            #expect(try #require(await streamHeader(0, on: mock)).contains("from=\"user@example.com\""))

            await mock.simulateDisconnect()
            _ = try? await connectTask.value
        }

        @Test
        func `A plaintext stream never names the account, also after sign-in`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com", credentials: .init(username: "user", password: "pencil"), transport: mock,
                requireTLS: false, allowsPLAIN: true
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            #expect(try #require(await streamHeader(0, on: mock)).contains("from=") == false)
            #expect(try #require(await streamHeader(2, on: mock)).contains("from=") == false)

            await disconnectFast(client)
        }
    }

    struct BrowserSignIn {
        @Test
        func `A bearer client on a server without STARTTLS sends no auth`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com", credentials: .init(username: "user", secret: .bearerToken("token")), transport: mock,
                requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(offer(["OAUTHBEARER", "SCRAM-SHA-256"]))

            let error = try await boundedFailure(of: connectTask)
            #expect(failureMessage(error) == SASLAuthError.browserSignInNeedsTLS.displayText)
            #expect(await mock.sentBytes.count == 1)
            #expect(await sentElements(on: mock).isEmpty)
        }

        @Test
        func `A bearer client on a server offering no OAUTHBEARER sends no auth`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com", credentials: .init(username: "user", secret: .bearerToken("token")), transport: mock
            )

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(offer(["SCRAM-SHA-256", "PLAIN"]))

            let error = try await boundedFailure(of: connectTask)
            #expect(failureMessage(error) == SASLAuthError.browserSignInUnavailable.displayText)
            #expect(await sentElements(on: mock).isEmpty)
        }

        @Test
        func `A split offer signs a bearer client in over SASL1 when only SASL1 lists OAUTHBEARER`() async throws {
            let mock = MockTransport()
            let fixture = try await BearerSessionFixture(mock: mock)

            let connectTask = Task { try await fixture.client.connectWithTLS(host: "example.com", port: 5223) }
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(offer(["OAUTHBEARER"], sasl2Mechanisms: ["SCRAM-SHA-256"]))
            await mock.waitForSent(count: 2) // auth
            await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
            await mock.waitForSent(count: 3) // post-auth stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesBind)
            await mock.waitForSent(count: 4) // bind IQ
            await mock.simulateReceive(testBindResult)
            let outcome = try await boundedOutcome { try await connectTask.value }
            try #require(outcome != nil)
            try outcome?.get()

            let sent = await sentElements(on: mock)
            let auth = try #require(sent.first { $0.name == "auth" })
            #expect(auth.namespace == saslNamespace)
            #expect(auth.attribute("mechanism") == "OAUTHBEARER")
            #expect(!sent.contains { $0.namespace == XMPPNamespaces.sasl2 })
            try await fixture.expectSessionTraffic(on: mock)

            await fixture.omemoModule.awaitSetupAttempt()
            await disconnectFast(fixture.client)
        }

        @Test(arguments: [
            ("user@example.com/ducko", true),
            ("USER@Example.COM/ducko", true),
            ("other@example.com/ducko", false),
            ("user@other.example/ducko", false)
        ])
        func `A SASL1 bind naming another account fails before any session traffic`(boundJID: String, matches: Bool) async throws {
            let mock = MockTransport()
            let fixture = try await BearerSessionFixture(mock: mock)
            let events = fixture.authenticationEvents()

            let connectTask = Task { try await fixture.client.connectWithTLS(host: "example.com", port: 5223) }
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive("""
            <features xmlns='http://etherx.jabber.org/streams'>\
            <mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>OAUTHBEARER</mechanism></mechanisms>\
            </features>
            """)
            await mock.waitForSent(count: 2) // auth
            await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
            await mock.waitForSent(count: 3) // post-auth stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesBind)
            await mock.waitForSent(count: 4) // bind IQ
            let bindID = try #require(await extractIQID(from: mock.sentBytes[3]))
            await mock.simulateReceive(
                "<iq type='result' id='\(bindID)'><bind xmlns='\(XMPPNamespaces.bind)'><jid>\(boundJID)</jid></bind></iq>"
            )

            if matches {
                let outcome = try await boundedOutcome { try await connectTask.value }
                try #require(outcome != nil)
                try outcome?.get()
                try await fixture.expectSessionTraffic(on: mock)
                events.cancel()
                await fixture.omemoModule.awaitSetupAttempt()
                await disconnectFast(fixture.client)
            } else {
                try await fixture.expectAccountMismatch(connectTask, events: events, mock: mock)
            }
        }

        @Test(arguments: [
            (["OAUTHBEARER"], ["PLAIN"], true),
            (["PLAIN", "OAUTHBEARER"], ["PLAIN", "OAUTHBEARER"], true),
            (["PLAIN"], ["PLAIN"], false)
        ])
        func `A refused PLAIN sign-in tells whether either profile offers a browser sign-in`(
            sasl1: [String], sasl2: [String], browserOffered: Bool
        ) async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com", credentials: .init(username: "user", password: "pencil"), transport: mock
            )

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(offer(sasl1, sasl2Mechanisms: sasl2))

            let error = try await boundedFailure(of: connectTask)
            guard case let .plainSignInRefused(offered) = error as? XMPPClientError else {
                Issue.record("Expected plainSignInRefused, got \(String(describing: error))")
                await disconnectFast(client)
                return
            }
            #expect(offered == browserOffered)
            #expect(await sentElements(on: mock).isEmpty)
        }
    }
}
