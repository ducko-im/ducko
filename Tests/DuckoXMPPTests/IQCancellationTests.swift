import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

struct IQCancellationTests {
    @Test
    func `expired IQ requests do not leave counted unsent stanzas`() async throws {
        let transport = MockTransport()
        let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "unused"), transport: transport, requireTLS: false, allowsPLAIN: true)
        let connect = Task { try await client.connect(host: "example.com", port: 5222) }
        await simulateNoTLSConnect(transport)
        try await connect.value
        await transport.clearSentBytes()
        let interceptor = CancellingIQInterceptor(cancel: false)
        await client.addInterceptor(interceptor)
        for index in 0 ..< 100 {
            _ = try? await client.sendIQ(XMPPIQ(type: .get, id: "expired-\(index)"), timeout: .zero)
        }
        try await client.send(XMPPPresence())
        let sent = await transport.sentBytes.filter { String(decoding: $0, as: UTF8.self).contains("expired-") }
        #expect(interceptor.count == sent.count)
        await disconnectFast(client)
    }

    @Test
    func `cancellation after interception cannot drop a counted IQ before sending`() async throws {
        let transport = MockTransport()
        let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "unused"), transport: transport, requireTLS: false, allowsPLAIN: true)
        let connect = Task { try await client.connect(host: "example.com", port: 5222) }
        await simulateNoTLSConnect(transport)
        try await connect.value
        await transport.clearSentBytes()
        let interceptor = CancellingIQInterceptor()
        await client.addInterceptor(interceptor)
        let request = Task { try await client.sendIQ(XMPPIQ(type: .get, id: "counted"), timeout: .milliseconds(50)) }
        _ = await request.result
        try await client.send(XMPPPresence())
        let sent = await transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        #expect(interceptor.count == 1)
        #expect(sent.contains { $0.contains("id=\"counted\"") })
        await disconnectFast(client)
    }
}

private final class CancellingIQInterceptor: StanzaInterceptor {
    private let counter = OSAllocatedUnfairLock(initialState: 0)
    private let cancel: Bool
    init(cancel: Bool = true) {
        self.cancel = cancel
    }

    var count: Int {
        counter.withLock { $0 }
    }

    func processIncoming(_: XMLElement) -> Bool {
        false
    }

    func processOutgoing(_ element: XMLElement) {
        guard element.name == "iq" else { return }
        counter.withLock { $0 += 1 }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
    }
}
