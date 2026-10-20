import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeClient(
    mock: MockTransport, previousState: SMResumeState? = nil, preferredResource: String? = nil
) async -> (XMPPClient, StreamManagementModule) {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false,
        preferredResource: preferredResource
    )
    let sm = StreamManagementModule(previousState: previousState)
    await client.register(sm)
    await client.addInterceptor(sm)
    return (client, sm)
}

/// The top-level elements the client sent, parsed, so a check matches by name and namespace rather than by how the
/// serializer happens to quote them. The stream header parses to none.
private func sentElements(on mock: MockTransport) async -> [XMLElement] {
    await mock.sentBytes.compactMap { try? stanza(String(decoding: $0, as: UTF8.self)) }
}

private func sentAuthenticate(on mock: MockTransport) async throws -> XMLElement {
    try #require(await sentElements(on: mock).first { $0.name == "authenticate" && $0.namespace == XMPPNamespaces.sasl2 })
}

/// Waits, within `boundedOutcome`'s deadline, for the client to send a stream-management `<enable/>`.
private func waitForSentEnable(on mock: MockTransport) async throws {
    let task = Task { await mock.waitForSent { $0.hasPrefix("<enable ") } }
    if try await boundedOutcome(of: { _ = await task.value }) == nil {
        task.cancel()
    }
    try #require(await task.value != nil, "No <enable/> was sent")
}

/// The session `sm-resume-1`, signed in as `user@example.com/ducko`, with one message the server has not yet
/// acknowledged.
private func carriedState(incomingCounter: UInt32 = 4, serverFeatures: XMLElement? = nil) throws -> SMResumeState {
    try SMResumeState(
        resumptionId: "sm-resume-1", incomingCounter: incomingCounter, outgoingCounter: 1,
        outgoingQueue: [stanza("<message to='contact@example.com' id='queued'><body>Queued</body></message>")],
        connectedJID: #require(FullJID.parse("user@example.com/ducko")), location: nil,
        serverFeatures: serverFeatures
    )
}

/// SASL2 success that starts a Bind 2 session with nothing enabled inline.
private let successBoundOnly = """
<success xmlns='urn:xmpp:sasl:2'>\
<authorization-identifier>user@example.com/ducko</authorization-identifier>\
<bound xmlns='urn:xmpp:bind:0'/>\
</success>
"""

private func isStreamResumed(_ event: XMPPEvent) -> Bool {
    if case .streamResumed = event { return true }
    return false
}

// MARK: - Tests

enum XMPPClientSASL2Tests {
    struct SASL2Connect {
        @Test
        func `Connects via SASL2 and Bind 2 when server supports it`() async throws {
            let mock = MockTransport()
            let (client, sm) = await makeClient(mock: mock)
            await client.register(CarbonsModule())

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Connect(mock)
            try await connectTask.value

            let authenticate = try await sentAuthenticate(on: mock)
            #expect(authenticate.child(named: "bind", namespace: XMPPNamespaces.bind2) != nil)

            // SM should be enabled inline
            #expect(sm.isResumable)

            await disconnectFast(client)
        }

        @Test
        func `Authenticate carries the configured user agent without an id, and its software as the Bind 2 tag`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com", credentials: .init(username: "user", password: "pass"), transport: mock,
                requireTLS: false, userAgent: SASL2UserAgent(software: "TestClient", device: "Test Mac")
            )

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Connect(mock)
            try await connectTask.value

            let authenticate = try await sentAuthenticate(on: mock)
            let userAgent = try #require(authenticate.child(named: "user-agent", namespace: XMPPNamespaces.sasl2))
            #expect(userAgent.childText(named: "software") == "TestClient")
            #expect(userAgent.childText(named: "device") == "Test Mac")
            #expect(userAgent.attribute("id") == nil)
            #expect(authenticate.child(named: "bind", namespace: XMPPNamespaces.bind2)?.childText(named: "tag") == "TestClient")

            await disconnectFast(client)
        }

        @Test
        func `The Bind 2 tag is the client's name, not the account's resource`() async throws {
            let mock = MockTransport()
            let (client, _) = await makeClient(mock: mock, preferredResource: "MyMac")

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Connect(mock)
            try await connectTask.value

            let bind = try await sentAuthenticate(on: mock).child(named: "bind", namespace: XMPPNamespaces.bind2)
            #expect(bind?.childText(named: "tag") == "Ducko")

            await disconnectFast(client)
        }
    }

    struct FallbackToSASL1 {
        @Test
        func `Falls back to SASL1 when server does not advertise SASL2`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            // Use the standard SASL1 flow
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            // Verify auth element used SASL1 namespace
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let authSent = sentStrings.first { $0.contains("urn:ietf:params:xml:ns:xmpp-sasl") }
            #expect(authSent != nil)

            // No SASL2 auth should have been sent
            let sasl2Sent = sentStrings.first { $0.contains("urn:xmpp:sasl:2") }
            #expect(sasl2Sent == nil)

            await disconnectFast(client)
        }

        @Test
        func `Signs in through SASL1 when SASL2 is offered without TLS`() async throws {
            let mock = MockTransport()
            let (client, _) = await makeClient(mock: mock)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive("""
            <features xmlns='http://etherx.jabber.org/streams'>\
            <mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>PLAIN</mechanism></mechanisms>\
            <authentication xmlns='urn:xmpp:sasl:2'><mechanism>PLAIN</mechanism><inline><bind xmlns='urn:xmpp:bind:0'/></inline></authentication>\
            </features>
            """)
            await mock.waitForSent(count: 2) // auth element
            await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
            await mock.waitForSent(count: 3) // post-auth stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesBind)
            await mock.waitForSent(count: 4) // bind IQ
            await mock.simulateReceive(testBindResult)
            try await connectTask.value

            let sent = await sentElements(on: mock)
            #expect(sent.contains { $0.name == "auth" && $0.namespace == saslNamespace })
            #expect(!sent.contains { $0.namespace == XMPPNamespaces.sasl2 })

            await disconnectFast(client)
        }
    }

    struct InlineEnable {
        @Test
        func `SM is enabled inline via Bind 2 and skips separate enable`() async throws {
            let mock = MockTransport()
            let (client, sm) = await makeClient(mock: mock)

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Connect(mock)
            try await connectTask.value

            #expect(sm.isResumable)
            let bind = try await sentAuthenticate(on: mock).child(named: "bind", namespace: XMPPNamespaces.bind2)
            #expect(bind?.child(named: "enable", namespace: XMPPNamespaces.sm) != nil)
            #expect(await !sentElements(on: mock).contains { $0.name == "enable" && $0.namespace == XMPPNamespaces.sm })

            await disconnectFast(client)
        }

        @Test
        func `SM is enabled after binding when Bind 2 does not list it`() async throws {
            let mock = MockTransport()
            let (client, sm) = await makeClient(mock: mock)

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Handshake(mock, features: testSASL2Features(bind2Inline: [XMPPNamespaces.carbons]), replies: [successBoundOnly])
            try await waitForSentEnable(on: mock)
            await mock.simulateReceive("<enabled xmlns='urn:xmpp:sm:3' id='sm-post-bind' max='300'/>")
            try await connectTask.value

            let bind = try await sentAuthenticate(on: mock).child(named: "bind", namespace: XMPPNamespaces.bind2)
            #expect(bind?.child(named: "enable", namespace: XMPPNamespaces.sm) == nil)
            #expect(sm.resumeState?.resumptionId == "sm-post-bind")

            await mock.ackSyncRequests(from: sm)
            await disconnectFast(client)
        }

        /// The post-sign-in features still list `<sm/>`, so a second `<enable/>` would go out if the inline one had not
        /// counted.
        @Test(arguments: ["<failed xmlns='urn:xmpp:sm:3'/>", ""])
        func `An inline SM enable is the stream's only one, whether it failed or went unanswered`(answer: String) async throws {
            let mock = MockTransport()
            let (client, sm) = await makeClient(mock: mock)
            let success = """
            <success xmlns='urn:xmpp:sasl:2'>\
            <authorization-identifier>user@example.com/ducko</authorization-identifier>\
            <bound xmlns='urn:xmpp:bind:0'>\(answer)</bound>\
            </success>
            """

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Handshake(mock, features: testFeaturesSASL2, replies: [success])
            // Bounded: a second `<enable/>` would wait for an answer that never comes.
            let outcome = try await boundedOutcome { try await connectTask.value }
            try #require(outcome != nil)
            try outcome?.get()

            #expect(!sm.isEnabled)
            #expect(await !sentElements(on: mock).contains { $0.name == "enable" && $0.namespace == XMPPNamespaces.sm })

            await disconnectFast(client)
        }

        @Test
        func `A client without stream management requests no inline enable`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com", credentials: .init(username: "user", password: "pass"), transport: mock, requireTLS: false
            )

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Handshake(mock, features: testFeaturesSASL2, replies: [successBoundOnly])
            try await connectTask.value

            let bind = try #require(try await sentAuthenticate(on: mock).child(named: "bind", namespace: XMPPNamespaces.bind2))
            #expect(bind.child(named: "enable", namespace: XMPPNamespaces.sm) == nil)

            await disconnectFast(client)
        }

        @Test
        func `Carbons are enabled inline and module skips separate IQ`() async throws {
            let mock = MockTransport()
            let (client, _) = await makeClient(mock: mock)
            await client.register(CarbonsModule())

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Connect(mock)
            try await connectTask.value

            let bind = try await sentAuthenticate(on: mock).child(named: "bind", namespace: XMPPNamespaces.bind2)
            #expect(bind?.child(named: "enable", namespace: XMPPNamespaces.carbons) != nil)
            #expect(await !sentElements(on: mock).contains { $0.name == "iq" && $0.child(named: "enable", namespace: XMPPNamespaces.carbons) != nil })

            await disconnectFast(client)
        }

        @Test
        func `Carbons are enabled after binding when Bind 2 does not list them`() async throws {
            let mock = MockTransport()
            let (client, _) = await makeClient(mock: mock)
            await client.register(CarbonsModule())

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Handshake(mock, features: testSASL2Features(bind2Inline: [XMPPNamespaces.sm]), replies: [testSASL2SuccessWithBind])
            let (_, id) = try await awaitOutgoingIQ(on: mock, type: .set, namespace: XMPPNamespaces.carbons) { _ in true }
            await mock.simulateReceive("<iq type='result' id='\(id)'/>")
            try await connectTask.value

            let bind = try await sentAuthenticate(on: mock).child(named: "bind", namespace: XMPPNamespaces.bind2)
            #expect(bind?.child(named: "enable", namespace: XMPPNamespaces.carbons) == nil)

            await disconnectFast(client)
        }
    }

    struct InlineResume {
        @Test(arguments: ["user@example.com", "user@example.com/ducko"])
        func `A resumed success continues the session and resends what was unacknowledged`(authorizationIdentifier: String) async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeClient(mock: mock, previousState: carriedState())
            let events = Task { try await collectEvents(from: client, until: isStreamResumed) }

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Handshake(
                mock, features: testFeaturesSASL2,
                replies: [testSASL2SuccessResumed(authorizationIdentifier: authorizationIdentifier)], postAuthFeatures: nil
            )
            try await connectTask.value

            #expect(try await events.value.contains(where: isStreamResumed))
            let resume = try await sentAuthenticate(on: mock).child(named: "resume", namespace: XMPPNamespaces.sm)
            #expect(resume?.attribute("previd") == "sm-resume-1")
            #expect(resume?.attribute("h") == "4")
            #expect(await sentElements(on: mock).contains { $0.name == "message" && $0.attribute("id") == "queued" })
            #expect(sm.isEnabled)

            await mock.ackSyncRequests(from: sm)
            await disconnectFast(client)
        }

        @Test
        func `A failed resume continues with the bound session from zero`() async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeClient(mock: mock, previousState: carriedState())
            let events = Task { try await collectEvents(from: client) { if case .connected = $0 { true } else { false } } }

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Handshake(mock, features: testFeaturesSASL2, replies: [testSASL2SuccessResumeFailed])
            try await connectTask.value

            #expect(try await !(events.value.contains(where: isStreamResumed)))
            let state = try #require(sm.resumeState)
            #expect(state.resumptionId == "sm-resume-2")
            #expect(state.incomingCounter == 0)
            #expect(state.outgoingCounter == 0)
            #expect(state.outgoingQueue.isEmpty)

            await mock.ackSyncRequests(from: sm)
            await disconnectFast(client)
        }

        @Test
        func `A failed resume whose Bind 2 can't enable SM enables it after binding`() async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeClient(mock: mock, previousState: carriedState())
            let resumeFailed = """
            <success xmlns='urn:xmpp:sasl:2'>\
            <authorization-identifier>user@example.com/ducko</authorization-identifier>\
            <failed xmlns='urn:xmpp:sm:3'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></failed>\
            <bound xmlns='urn:xmpp:bind:0'/>\
            </success>
            """

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Handshake(mock, features: testSASL2Features(bind2Inline: [XMPPNamespaces.carbons]), replies: [resumeFailed])
            try await waitForSentEnable(on: mock)
            await mock.simulateReceive("<enabled xmlns='urn:xmpp:sm:3' id='sm-post-bind' max='300'/>")
            try await connectTask.value

            #expect(sm.resumeState?.resumptionId == "sm-post-bind")

            await mock.ackSyncRequests(from: sm)
            await disconnectFast(client)
        }

        @Test
        func `A first sign-in sends no resume`() async throws {
            let mock = MockTransport()
            let (client, sm) = await makeClient(mock: mock)

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Connect(mock)
            try await connectTask.value

            #expect(try await sentAuthenticate(on: mock).child(named: "resume", namespace: XMPPNamespaces.sm) == nil)

            await mock.ackSyncRequests(from: sm)
            await disconnectFast(client)
        }

        @Test
        func `Without inline SM in SASL2, nothing is resumed and the new session starts from zero`() async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeClient(mock: mock, previousState: carriedState())

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Handshake(
                mock, features: testSASL2Features(bind2Inline: [XMPPNamespaces.sm], inlineSM: false), replies: [testSASL2SuccessWithBind]
            )
            try await connectTask.value

            #expect(try await sentAuthenticate(on: mock).child(named: "resume", namespace: XMPPNamespaces.sm) == nil)
            let state = try #require(sm.resumeState)
            #expect(state.resumptionId == "sm-resume-1")
            #expect(state.incomingCounter == 0)
            #expect(state.outgoingCounter == 0)
            #expect(state.outgoingQueue.isEmpty)

            await mock.ackSyncRequests(from: sm)
            await disconnectFast(client)
        }

        @Test
        func `A resumed success without a session to resume fails sign-in`() async {
            let mock = MockTransport()
            let (client, _) = await makeClient(mock: mock)

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Handshake(mock, features: testFeaturesSASL2, replies: [testSASL2SuccessResumed()], postAuthFeatures: nil)

            let error = await #expect(throws: XMPPClientError.self) { try await connectTask.value }
            guard case .authenticationFailed = error else {
                Issue.record("Expected authenticationFailed, got \(String(describing: error))")
                return
            }
        }

        @Test
        func `Stanzas and features the server sends after a resumed success are handled as on a running stream`() async throws {
            let mock = MockTransport()
            let (client, sm) = try await makeClient(mock: mock, previousState: carriedState(incomingCounter: 4))
            await client.register(ChatModule())
            let messages = Task { try await collectEvents(from: client) { if case .messageReceived = $0 { true } else { false } } }

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Handshake(
                mock, features: testFeaturesSASL2,
                replies: [
                    testSASL2SuccessResumed(h: 1)
                        + "<message type='chat' from='contact@example.com/res' id='replayed'><body>Replayed</body></message>"
                ],
                postAuthFeatures: nil
            )
            try await connectTask.value
            #expect(try await messages.value.contains { if case .messageReceived = $0 { true } else { false } })

            let ack = await awaitSentResponse(
                on: mock, afterReceiving: "<r xmlns='urn:xmpp:sm:3'/>" + testPostSASL2Features, matching: { $0.hasPrefix("<a ") }
            )
            #expect(try ack.map(stanza)?.attribute("h") == "5")
            #expect(sm.resumeState?.incomingCounter == 5)
            #expect(await client.acceptsStanzas)

            await mock.ackSyncRequests(from: sm)
            await disconnectFast(client)
        }

        @Test
        func `A resumed session keeps sending client state the session's features allowed`() async throws {
            let mock = MockTransport()
            let csiFeatures = try stanza("<features xmlns='http://etherx.jabber.org/streams'><csi xmlns='urn:xmpp:csi:0'/></features>")
            let (client, sm) = try await makeClient(mock: mock, previousState: carriedState(serverFeatures: csiFeatures))
            let csi = CSIModule()
            await client.register(csi)

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Handshake(mock, features: testFeaturesSASL2, replies: [testSASL2SuccessResumed(h: 1)], postAuthFeatures: nil)
            try await connectTask.value

            try await csi.sendInactive()
            #expect(await sentElements(on: mock).contains { $0.name == "inactive" && $0.namespace == XMPPNamespaces.csi })

            await mock.ackSyncRequests(from: sm)
            await disconnectFast(client)
        }
    }

    struct UnsupportedStep {
        @Test
        func `A continue is aborted and fails sign-in with readable text`() async {
            let mock = MockTransport()
            let (client, _) = await makeClient(mock: mock)
            let events = Task { try await collectEvents(from: client) { if case .authenticationFailed = $0 { true } else { false } } }

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await simulateSASL2Handshake(
                mock, features: testFeaturesSASL2,
                replies: ["<continue xmlns='urn:xmpp:sasl:2'><tasks><task>HT-SHA-256</task></tasks></continue>"],
                postAuthFeatures: nil
            )

            await #expect(throws: XMPPClientError.self) { try await connectTask.value }
            #expect(await sentElements(on: mock).contains { $0.name == "abort" && $0.namespace == XMPPNamespaces.sasl2 })
            let failure = try? await events.value.last
            guard case let .authenticationFailed(message) = failure else {
                Issue.record("Expected authenticationFailed, got \(String(describing: failure))")
                return
            }
            #expect(message == SASLAuthError.unsupportedSignInStep.displayText)
        }
    }
}
