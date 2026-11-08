import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

struct IQReplyDispatchTests {
    private func connected(_ transport: MockTransport) async throws -> XMPPClient {
        let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "unused"), transport: transport, requireTLS: false, allowsPLAIN: true)
        let connection = Task { try await client.connect(host: "example.com", port: 5222) }
        await simulateNoTLSConnect(transport)
        try await connection.value
        await transport.clearSentBytes()
        return client
    }

    @Test
    func `a same-ID get is answered service-unavailable and leaves the request pending`() async throws {
        let transport = MockTransport()
        let client = try await connected(transport)
        let operation = Task { try await client.sendIQ(XMPPIQ(type: .get, id: "collide")) }
        await transport.waitForSent(count: 1)

        let bounce = await awaitSentResponse(on: transport, afterReceiving: "<iq type='get' id='collide'><query xmlns='urn:unknown'/></iq>") {
            $0.contains("id=\"collide\"") && $0.contains("service-unavailable")
        }
        #expect(bounce != nil)

        await transport.simulateReceive("<iq type='result' id='collide'><accept/></iq>")
        #expect(try await operation.value?.name == "accept")
        await disconnectFast(client)
    }

    @Test
    func `a wrong-sender result for an addressed request is dispatched without a reply`() async throws {
        let transport = MockTransport()
        let client = try await connected(transport)
        let operation = Task {
            var iq = XMPPIQ(type: .get, id: "addressed")
            iq.to = .full(FullJID.parse("peer@example.com/res")!)
            return try await client.sendIQ(iq)
        }
        await transport.waitForSent(count: 1)
        await transport.clearSentBytes()

        await transport.simulateReceive("""
        <iq type='result' id='addressed' from='peer@example.com'><reject/></iq>
        <iq type='result' id='addressed' from='peer@example.com/res'><accept/></iq>
        """)
        #expect(try await operation.value?.name == "accept")
        #expect(await transport.sentBytes.isEmpty)

        await disconnectFast(client)
        var dispatched: [XMPPIQ] = []
        for await case let .iqReceived(iq) in client.events {
            dispatched.append(iq)
        }
        #expect(dispatched.map { $0.childElement?.name } == ["reject"])
    }

    @Test
    func `a keepalive ping rejects a reply from the own full JID`() async throws {
        let transport = MockTransport()
        let client = try await connected(transport)
        let operation = Task {
            var ping = XMPPIQ(type: .get, id: "keepalive")
            ping.element.addChild(XMLElement(name: "ping", namespace: XMPPNamespaces.ping))
            return try await client.sendIQ(ping)
        }
        await transport.waitForSent(count: 1)
        await transport.simulateReceive("""
        <iq type='result' id='keepalive' from='user@example.com/ducko'><reject/></iq>
        <iq type='result' id='keepalive'><accept/></iq>
        """)
        #expect(try await operation.value?.name == "accept")
        await disconnectFast(client)
    }
}

// MARK: - Terminal Delivery

extension IQReplyDispatchTests {
    private func terminalCounter() -> (count: OSAllocatedUnfairLock<Int>, handler: ModuleContext.IQTerminalHandler) {
        let count = OSAllocatedUnfairLock(initialState: 0)
        return (count, { _ in count.withLock { $0 += 1 } })
    }

    @Test
    func `cancellation ends a request once and ignores a late reply`() async throws {
        let transport = MockTransport()
        let client = try await connected(transport)
        let (count, handler) = terminalCounter()
        let operation = Task { try await client.sendIQ(XMPPIQ(type: .get, id: "cancelled"), onTerminal: handler) }
        await transport.waitForSent(count: 1)
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        await transport.simulateReceive("<iq type='result' id='cancelled'/>")
        await disconnectFast(client)
        #expect(count.withLock { $0 } == 1)
    }

    @Test
    func `disconnect ends a pending request once`() async throws {
        let transport = MockTransport()
        let client = try await connected(transport)
        let (count, handler) = terminalCounter()
        let operation = Task { try await client.sendIQ(XMPPIQ(type: .get, id: "pending"), onTerminal: handler) }
        await transport.waitForSent(count: 1)
        await disconnectFast(client)
        await #expect(throws: XMPPClientError.self) { try await operation.value }
        #expect(count.withLock { $0 } == 1)
    }

    @Test
    func `a request on an unconnected client ends once`() async {
        let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "unused"), transport: MockTransport(), requireTLS: false, allowsPLAIN: true)
        let (count, handler) = terminalCounter()
        await #expect(throws: XMPPClientError.self) { try await client.sendIQ(XMPPIQ(type: .get, id: "offline"), onTerminal: handler) }
        #expect(count.withLock { $0 } == 1)
    }

    @Test
    func `a module request after its client is gone ends once`() async throws {
        let module = ContextCapturingModule()
        weak var weakClient: XMPPClient?
        do {
            let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "unused"), transport: MockTransport(), requireTLS: false, allowsPLAIN: true)
            await client.register(module)
            weakClient = client
        }
        #expect(weakClient == nil)
        let context = try #require(module.context.withLock { $0 })
        let (count, handler) = terminalCounter()
        await #expect(throws: XMPPClientError.self) { try await context.sendIQ(XMPPIQ(type: .get, id: "gone"), onTerminal: handler) }
        #expect(count.withLock { $0 } == 1)
    }

    @Test
    func `a duplicate ID ends the second request once and keeps the first pending`() async throws {
        let transport = MockTransport()
        let client = try await connected(transport)
        let (firstCount, firstHandler) = terminalCounter()
        let (secondCount, secondHandler) = terminalCounter()
        let first = Task { try await client.sendIQ(XMPPIQ(type: .get, id: "duplicate"), onTerminal: firstHandler) }
        await transport.waitForSent(count: 1)
        await #expect(throws: XMPPClientError.self) {
            try await client.sendIQ(XMPPIQ(type: .get, id: "duplicate"), onTerminal: secondHandler)
        }
        #expect(secondCount.withLock { $0 } == 1)
        #expect(firstCount.withLock { $0 } == 0)

        await transport.simulateReceive("<iq type='result' id='duplicate'><accept/></iq>")
        #expect(try await first.value?.name == "accept")
        #expect(firstCount.withLock { $0 } == 1)
        await disconnectFast(client)
    }
}

private final class ContextCapturingModule: XMPPModule {
    let context = OSAllocatedUnfairLock<ModuleContext?>(initialState: nil)

    func setUp(_ context: ModuleContext) {
        self.context.withLock { $0 = context }
    }
}
