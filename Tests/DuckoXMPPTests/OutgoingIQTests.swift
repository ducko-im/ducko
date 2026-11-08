import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

struct OutgoingIQTests {
    private static let namespace = "urn:ducko:test"

    private func request(_ id: String, type: XMPPIQ.IQType = .get, namespace: String = Self.namespace) -> String {
        var iq = XMPPIQ(type: type, id: id)
        iq.element.addChild(XMLElement(name: "query", namespace: namespace))
        return iq.element.xmlString
    }

    @Test func `already emitted and sequential requests keep their own IDs`() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "example.com", port: 5222)
        try await mock.send(Array(request("first").utf8))
        let first = try await awaitOutgoingIQ(on: mock, type: .get, namespace: Self.namespace) { $0.contains("id=\"first\"") }
        #expect(first.id == "first")
        try await mock.send(Array(request("second").utf8))
        let second = try await awaitOutgoingIQ(on: mock, type: .get, namespace: Self.namespace) { $0.contains("id=\"second\"") }
        #expect(second.id == "second")
        #expect(await mock.sentBytes.count == 2)
        await mock.disconnect()
    }

    @Test func `delayed intended request ignores other types namespaces and scenarios`() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "example.com", port: 5222)
        try await mock.send(Array(request("wanted", type: .result).utf8))
        try await mock.send(Array(request("wanted", namespace: "urn:other").utf8))
        try await mock.send(Array(request("other").utf8))
        let intended = request("wanted")
        let sender = Task {
            try await Task.sleep(for: .milliseconds(20))
            try await mock.send(Array(intended.utf8))
        }
        defer { sender.cancel() }
        let result = try await awaitOutgoingIQ(on: mock, type: .get, namespace: Self.namespace) { $0.contains("id=\"wanted\"") }
        try await sender.value
        #expect(result.xml == intended)
        #expect(result.id == "wanted")
        await mock.disconnect()
    }

    @Test func `no matching request times out`() async throws {
        let mock = MockTransport()
        let error = await #expect(throws: XMPPClientError.self) {
            try await awaitOutgoingIQ(on: mock, type: .get, namespace: Self.namespace, timeout: .milliseconds(20)) { _ in true }
        }
        guard case .timeout = error else {
            Issue.record("Expected request timeout")
            return
        }
    }

    @Test func `cancelled wait finishes without an emitted request`() async throws {
        let mock = MockTransport()
        let task = Task {
            try await awaitOutgoingIQ(on: mock, type: .get, namespace: Self.namespace) { _ in true }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func `nested ID cannot stand in for missing request ID`() async throws {
        let mock = MockTransport()
        try await mock.connect(host: "example.com", port: 5222)
        try await mock.send(Array("<iq type=\"get\"><query xmlns=\"urn:ducko:test\" id=\"nested\"/></iq>".utf8))
        let error = await #expect(throws: XMPPClientError.self) {
            try await awaitOutgoingIQ(on: mock, type: .get, namespace: Self.namespace) { _ in true }
        }
        guard case .unexpectedStreamState = error else {
            Issue.record("Expected missing request ID failure")
            return
        }
        await mock.disconnect()
    }

    @Test func `responder failure disconnects and drains the pending operation`() async throws {
        let mock = MockTransport()
        let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "pass"), transport: mock, requireTLS: false, allowsPLAIN: true)
        let connect = Task { try await client.connect(host: "example.com", port: 5222) }
        await simulateNoTLSConnect(mock)
        try await connect.value
        let finished = OSAllocatedUnfairLock(initialState: false)
        await #expect(throws: XMPPClientError.self) {
            try await withIQOperation(client: client, operation: {
                defer { finished.withLock { $0 = true } }
                var iq = XMPPIQ(type: .get, id: "pending")
                iq.element.addChild(XMLElement(name: "query", namespace: Self.namespace))
                return try await client.sendIQ(iq)
            }, respond: {
                _ = try await awaitOutgoingIQ(on: mock, type: .get, namespace: Self.namespace) { $0.contains("id=\"pending\"") }
                throw XMPPClientError.timeout
            })
        }
        #expect(finished.withLock { $0 })
        #expect(await mock.isConnected == false)
    }
}
