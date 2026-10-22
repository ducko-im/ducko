import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

/// A client with stream management and a roster, whose setup sends the roster request after the session connects.
private func makeSetupClient(mock: MockTransport, signInTimeout: Duration = .seconds(60)) async -> (XMPPClient, StreamManagementModule) {
    let client = XMPPClient(
        domain: "example.com", credentials: .init(username: "user", password: "pass"), transport: mock, requireTLS: false,
        signInTimeout: signInTimeout
    )
    let sm = StreamManagementModule()
    await client.register(sm)
    await client.addInterceptor(sm)
    await client.register(RosterModule())
    return (client, sm)
}

/// Signs in with stream management and answers its enable, so the session connects and a resume would be possible.
private func simulateConnectWithSM(_ mock: MockTransport) async {
    await simulateNoTLSConnect(mock, postAuthFeatures: testFeaturesBindWithSM)
    await mock.waitForSent(count: 5) // SM <enable>
    await mock.simulateReceive("<enabled xmlns='urn:xmpp:sm:3' resume='true' id='setup-session'/>")
}

private func isRosterRequest(_ stanza: String) -> Bool {
    stanza.contains(XMPPNamespaces.roster)
}

/// A request that goes out at once and is never answered.
private func pendingRequest(on client: XMPPClient) -> Task<XMLElement?, any Error> {
    var probe = XMPPIQ(type: .get, id: "probe")
    probe.element.addChild(XMLElement(name: "query", namespace: XMPPNamespaces.discoInfo))
    let request = probe
    return Task { try await client.sendIQ(request) }
}

// MARK: - Tests

struct XMPPClientSessionSetupTests {
    @Test
    func `A setup step that fails after connecting ends the session the normal way, never to be resumed`() async throws {
        let mock = MockTransport()
        let (client, sm) = await makeSetupClient(mock: mock)
        await mock.blockSends(where: isRosterRequest)
        let events = Task { try await collectEvents(from: client) { _ in false } }

        let connect = Task { try await client.connect(host: "example.com", port: 5222) }
        await simulateConnectWithSM(mock)
        await mock.waitForBlockedSend()
        let request = pendingRequest(on: client)
        _ = await mock.waitForSent { $0.contains("probe") }
        await mock.failBlockedSends(with: XMPPClientError.sendFailed("Broken pipe"))

        let error = await #expect(throws: XMPPClientError.self) { try await connect.value }
        guard case .sessionSetupFailed(XMPPClientError.sendFailed) = error else {
            Issue.record("Expected sessionSetupFailed, got \(String(describing: error))")
            return
        }
        await #expect(throws: XMPPClientError.self) { try await request.value }
        let disconnects = try await events.value.compactMap { if case let .disconnected(reason) = $0 { reason } else { nil } }
        #expect(disconnects.count == 1)
        guard case .setupFailed(XMPPClientError.sendFailed)? = disconnects.first else {
            Issue.record("Expected one setupFailed disconnect, got \(disconnects)")
            return
        }
        #expect(sm.resumeState == nil)
    }

    @Test
    func `A setup cancelled by its caller ends as requested`() async throws {
        let mock = MockTransport()
        let (client, _) = await makeSetupClient(mock: mock)
        await mock.blockSends(where: isRosterRequest)
        let events = Task { try await collectEvents(from: client) { _ in false } }

        let connect = Task { try await client.connect(host: "example.com", port: 5222) }
        await simulateConnectWithSM(mock)
        await mock.waitForBlockedSend()
        connect.cancel()

        await #expect(throws: CancellationError.self) { try await connect.value }
        let disconnects = try await events.value.compactMap { if case let .disconnected(reason) = $0 { reason } else { nil } }
        guard disconnects.count == 1, case .requested? = disconnects.first else {
            Issue.record("Expected one requested disconnect, got \(disconnects)")
            return
        }
        await mock.releaseBlockedSends()
    }

    @Test
    func `A message sent during setup goes out once setup completes, while a request goes out at once`() async throws {
        let mock = MockTransport()
        let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "pass"), transport: mock, requireTLS: false)
        let release = AsyncSemaphore()
        await client.register(SetupHold(release: release))
        let connected = Task { try await collectEvents(from: client) { if case .connected = $0 { true } else { false } } }

        let connect = Task { try await client.connect(host: "example.com", port: 5222) }
        await simulateNoTLSConnect(mock)
        _ = try await connected.value
        let contact = try #require(BareJID.parse("contact@example.com"))
        let message = Task { try await client.send(XMPPMessage(type: .chat, to: .bare(contact), id: "held")) }
        let request = pendingRequest(on: client)
        _ = await mock.waitForSent { $0.contains("probe") }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await !mock.sentBytes.contains { String(decoding: $0, as: UTF8.self).contains("held") })

        await release.signal()
        try await connect.value
        try await message.value
        #expect(await mock.sentBytes.contains { String(decoding: $0, as: UTF8.self).contains("held") })
        request.cancel()
        await disconnectFast(client)
    }

    @Test
    func `A message held for setup fails when setup fails`() async throws {
        let mock = MockTransport()
        let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "pass"), transport: mock, requireTLS: false)
        let release = AsyncSemaphore()
        await client.register(SetupHold(release: release, failure: XMPPClientError.timeout))
        let connected = Task { try await collectEvents(from: client) { if case .connected = $0 { true } else { false } } }

        let connect = Task { try await client.connect(host: "example.com", port: 5222) }
        await simulateNoTLSConnect(mock)
        _ = try await connected.value
        let ready = Task { try await client.awaitSessionReady() }
        let contact = try #require(BareJID.parse("contact@example.com"))
        let message = Task { try await client.send(XMPPMessage(type: .chat, to: .bare(contact), id: "held")) }
        await release.signal()

        await #expect(throws: XMPPClientError.self) { try await connect.value }
        await #expect(throws: XMPPClientError.self) { try await ready.value }
        await #expect(throws: XMPPClientError.self) { try await message.value }
        #expect(await !mock.sentBytes.contains { String(decoding: $0, as: UTF8.self).contains("held") })
    }

    @Test
    func `A sign-in the server stops answering fails with a timeout at the deadline`() async throws {
        let mock = MockTransport()
        let (client, _) = await makeSetupClient(mock: mock, signInTimeout: .milliseconds(300))

        let connect = Task { try await client.connect(host: "example.com", port: 5222) }
        await mock.waitForSent(count: 1) // stream opening
        await mock.simulateReceive(testServerStreamOpen)

        let error = try await boundedFailure(of: connect)
        guard case .timeout? = error as? XMPPClientError else {
            Issue.record("Expected a timeout, got \(String(describing: error))")
            return
        }
        #expect(await !(client.acceptsStanzas))
    }

    @Test
    func `A session whose setup completes outlives the deadline`() async throws {
        let mock = MockTransport()
        let client = XMPPClient(
            domain: "example.com", credentials: .init(username: "user", password: "pass"), transport: mock, requireTLS: false,
            signInTimeout: .milliseconds(300)
        )

        let connect = Task { try await client.connect(host: "example.com", port: 5222) }
        await simulateNoTLSConnect(mock)
        try await connect.value
        try await Task.sleep(for: .milliseconds(600))

        #expect(await client.acceptsStanzas)
        await disconnectFast(client)
    }

    @Test
    func `A setup the server stops answering ends the session at the deadline`() async throws {
        let mock = MockTransport()
        let (client, _) = await makeSetupClient(mock: mock, signInTimeout: .milliseconds(300))
        let events = Task { try await collectEvents(from: client) { _ in false } }

        let connect = Task { try await client.connect(host: "example.com", port: 5222) }
        await simulateNoTLSConnect(mock, postAuthFeatures: testFeaturesBindWithSM)
        await mock.waitForSent(count: 5) // SM <enable>, never answered

        #expect(try await boundedFailure(of: connect) != nil)
        let disconnects = try await events.value.compactMap { if case let .disconnected(reason) = $0 { reason } else { nil } }
        guard disconnects.count == 1, case .connectionLost? = disconnects.first else {
            Issue.record("Expected one connectionLost disconnect, got \(disconnects)")
            return
        }
    }
}
