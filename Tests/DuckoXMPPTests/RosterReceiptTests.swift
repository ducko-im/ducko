import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

struct RosterReceiptTests {
    private func connected(_ transport: MockTransport) async throws -> XMPPClient {
        let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "unused"), transport: transport, requireTLS: false)
        let connection = Task { try await client.connect(host: "example.com", port: 5222) }
        await simulateNoTLSConnect(transport)
        try await connection.value
        await transport.clearSentBytes()
        return client
    }

    @Test
    func `real dispatch emits snapshot before push while the query caller is suspended`() async throws {
        let transport = MockTransport()
        let client = try await connected(transport)
        let module = RosterModule()
        await client.register(module)
        let gate = AsyncSemaphore()
        let (events, continuation) = AsyncStream.makeStream(of: RosterUpdate.self)
        module.setUp(ModuleContext(
            sendStanza: { try await client.send($0, onAccepted: $1) },
            sendIQ: { iq, terminal in
                let result = try await client.sendIQ(iq, onTerminal: terminal)
                await gate.wait()
                return result
            },
            emitEvent: { if case let .rosterUpdated(update) = $0 { continuation.yield(update) } },
            generateID: { "initial" }, connectedJID: { FullJID.parse("user@example.com/ducko") }, domain: "example.com"
        ))
        let query = Task { try await module.handleConnect() }
        await transport.waitForSent(count: 1)
        await transport.simulateReceive("<iq type='result' id='initial'><query xmlns='jabber:iq:roster' ver='one'><item jid='bob@example.com' name='Before'/></query></iq><iq type='set' id='push'><query xmlns='jabber:iq:roster' ver='two'><item jid='bob@example.com' name='After'/></query></iq>")
        var iterator = events.makeAsyncIterator()
        let first = try #require(await iterator.next())
        let second = try #require(await iterator.next())
        #expect(first.origin == .initial)
        #expect(second.origin == .push)
        #expect(first.receipt < second.receipt)
        #expect(first.version == "one")
        #expect(second.version == "two")
        await gate.signal()
        try await query.value
        await disconnectFast(client)
    }

    @Test(arguments: [XMPPIQ.IQType.get, .set])
    func `wrong sender and request stanzas cannot consume a roster result waiter`(type: XMPPIQ.IQType) async throws {
        let transport = MockTransport()
        let client = try await connected(transport)
        await client.register(RosterModule())
        let replies = OSAllocatedUnfairLock<[XMPPIQ]>(initialState: [])
        var iq = XMPPIQ(type: type, id: "strict")
        iq.element.addChild(XMLElement(name: "query", namespace: XMPPNamespaces.roster))
        let request = iq
        let operation = Task { try await client.sendIQ(request) { result in
            if case let .success(reply) = result { replies.withLock { $0.append(reply) } }
        } }
        await transport.waitForSent(count: 1)
        await transport.simulateReceive("""
        <iq type='result' id='strict' from='other@example.com' marker='wrong'/>
        <iq type='result' id='strict' from='user@example.com/resource' marker='full'/>
        <iq type='result' id='strict' from='bad@@example.com' marker='malformed'/>
        <iq type='result' id='strict' from='example.com' marker='domain'/>
        <iq type='get' id='strict' marker='get'/>
        <iq type='set' id='strict'><query xmlns='jabber:iq:roster'><item jid='bob@example.com'/></query></iq>
        <iq type='result' id='strict' from='user@example.com' marker='valid'><query xmlns='jabber:iq:roster'/></iq>
        """)
        _ = try await operation.value
        let received = replies.withLock { $0 }
        #expect(received.count == 1)
        #expect(received.first?.element.attribute("marker") == "valid")
        await disconnectFast(client)
    }

    @Test(arguments: ["", " from='user@example.com'"])
    func `absent or account sender acknowledges roster requests`(sender: String) async throws {
        let transport = MockTransport()
        let client = try await connected(transport)
        let count = OSAllocatedUnfairLock(initialState: 0)
        let operation = Task { try await client.sendIQ(XMPPIQ(type: .set, id: "valid")) { _ in count.withLock { $0 += 1 } } }
        await transport.waitForSent(count: 1)
        await transport.simulateReceive("<iq type='result' id='valid'\(sender)/>")
        _ = try await operation.value
        #expect(count.withLock { $0 } == 1)
        await disconnectFast(client)
    }

    @Test
    func `server domain error terminates a roster request once`() async throws {
        let transport = MockTransport()
        let client = try await connected(transport)
        let count = OSAllocatedUnfairLock(initialState: 0)
        let operation = Task { try await client.sendIQ(XMPPIQ(type: .get, id: "error")) { _ in count.withLock { $0 += 1 } } }
        await transport.waitForSent(count: 1)
        await transport.simulateReceive("<iq type='error' id='error' from='example.com'><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
        await #expect(throws: XMPPStanzaError.self) { _ = try await operation.value }
        #expect(count.withLock { $0 } == 1)
        await disconnectFast(client)
    }

    @Test(arguments: [
        "", "<query xmlns='wrong'/>",
        "<query xmlns='jabber:iq:roster'><item jid='bob@example.com/resource'/></query>",
        "<query xmlns='jabber:iq:roster'><item jid='bob@example.com' subscription='remove'/></query>",
        "<query xmlns='jabber:iq:roster'><item jid='bob@example.com'/><item jid='bob@example.com'/></query>"
    ])
    func `full readback rejects missing and malformed queries`(payload: String) async throws {
        let transport = MockTransport()
        let client = try await connected(transport)
        let module = RosterModule()
        await client.register(module)
        let request = Task { try await module.requestFullRoster(id: "full") }
        await transport.waitForSent(count: 1)
        await transport.simulateReceive("<iq type='result' id='full'>\(payload)</iq>")
        await #expect(throws: XMPPClientError.self) { _ = try await request.value }
        await disconnectFast(client)
    }
}

extension RosterReceiptTests {
    @Test(arguments: ["rejected", "invalid", "timeout", "send-failure"])
    func `initial query failures emit a terminal baseline outcome`(failure: String) async throws {
        let transport = MockTransport()
        let client = try await connected(transport)
        let module = RosterModule()
        await client.register(module)
        let events = OSAllocatedUnfairLock<[RosterUpdate]>(initialState: [])
        module.setUp(ModuleContext(
            sendStanza: { try await client.send($0, onAccepted: $1) },
            sendIQ: { iq, terminal in
                try await client.sendIQ(iq, timeout: failure == "timeout" ? .zero : .seconds(2), onTerminal: terminal)
            },
            emitEvent: { if case let .rosterUpdated(update) = $0 { events.withLock { $0.append(update) } } },
            generateID: { "initial-failure" }, connectedJID: { FullJID.parse("user@example.com/ducko") }, domain: "example.com"
        ))
        if failure == "send-failure" { await transport.simulateSendFailure(XMPPClientError.notConnected) }
        let query = Task { try await module.handleConnect() }
        if failure == "rejected" || failure == "invalid" {
            await transport.waitForSent(count: 1)
            let reply = failure == "rejected"
                ? "<iq type='error' id='initial-failure'><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
                : "<iq type='result' id='initial-failure'><query xmlns='invalid-roster'/></iq>"
            await transport.simulateReceive(reply)
        }
        let result = await query.result
        if failure == "timeout" || failure == "send-failure" {
            if case .success = result { Issue.record("Connection-level failure must propagate") }
        } else {
            try result.get()
        }
        let updates = events.withLock { $0 }
        #expect(updates.count == 1)
        #expect(updates.first?.origin == .initial)
        if case .initialQueryFailed = updates.first?.contents {} else { Issue.record("Initial baseline did not settle") }
        #expect(updates.first?.isInitialResponse == false)
        await transport.simulateSendFailure(nil)
        await disconnectFast(client)
    }
}
