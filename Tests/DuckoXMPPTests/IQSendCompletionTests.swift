import DuckoTestSupport
import Testing
@testable import DuckoXMPP

struct IQSendCompletionTests {
    @Test(arguments: [false, true])
    func `a reply does not cancel an accepted write whose completion is pending`(errorReply: Bool) async throws {
        let transport = DelayedWriteCompletionTransport()
        let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "unused"), transport: transport, requireTLS: false, allowsPLAIN: true)
        let connect = Task { try await client.connect(host: "example.com", port: 5222) }
        await simulateNoTLSConnect(transport.mock)
        try await connect.value
        let request = Task { try await client.sendIQ(XMPPIQ(type: .get, id: "delayed-write")) }
        await transport.entered.wait()
        let response = errorReply
            ? "<iq type='error' id='delayed-write'><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
            : "<iq type='result' id='delayed-write'/>"
        await transport.mock.simulateReceive(response)
        let outcome = await request.result
        await transport.release.signal()
        await transport.finished.wait()
        #expect(await transport.wasCancelled == false)
        switch outcome {
        case .success: #expect(!errorReply)
        case let .failure(error): #expect(errorReply && error is XMPPStanzaError)
        }
        try await client.send(XMPPPresence())
        await disconnectFast(client)
    }
}

private actor DelayedWriteCompletionTransport: XMPPTransport {
    nonisolated let mock = MockTransport()
    nonisolated var receivedData: AsyncStream<[UInt8]> {
        mock.receivedData
    }

    let entered = AsyncSemaphore()
    let release = AsyncSemaphore()
    let finished = AsyncSemaphore()
    private(set) var wasCancelled = false

    func connect(host: String, port: UInt16) async throws {
        try await mock.connect(host: host, port: port)
    }

    func connectWithTLS(host: String, port: UInt16, serverName: String) async throws {
        try await mock.connectWithTLS(host: host, port: port, serverName: serverName)
    }

    func stopReceiving() async {
        await mock.stopReceiving()
    }

    func upgradeTLS(serverName: String) async throws -> AsyncStream<[UInt8]> {
        try await mock.upgradeTLS(serverName: serverName)
    }

    func disconnect() async {
        await mock.disconnect()
    }

    func send(_ bytes: [UInt8]) async throws {
        try await mock.send(bytes)
        if String(decoding: bytes, as: UTF8.self).contains("delayed-write") {
            await entered.signal()
            await release.wait()
            wasCancelled = Task.isCancelled
            await finished.signal()
        }
    }
}
