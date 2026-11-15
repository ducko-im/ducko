import DuckoTestSupport
import Testing
@testable import DuckoXMPP

struct IQSendCompletionTests {
    @Test(arguments: [false, true])
    func `a reply does not cancel an accepted write whose completion is pending`(errorReply: Bool) async throws {
        let mock = MockTransport()
        let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "unused"), transport: mock, requireTLS: false, allowsPLAIN: true)
        let connect = Task { try await client.connect(host: "example.com", port: 5222) }
        await simulateNoTLSConnect(mock)
        try await connect.value
        await mock.blockSends { $0.contains("delayed-write") }
        let request = Task { try await client.sendIQ(XMPPIQ(type: .get, id: "delayed-write")) }
        await mock.waitForBlockedSend()
        let response = errorReply
            ? "<iq type='error' id='delayed-write'><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
            : "<iq type='result' id='delayed-write'/>"
        await mock.simulateReceive(response)
        let outcome = await request.result
        await mock.releaseBlockedSends()
        _ = await mock.waitForSent { $0.contains("delayed-write") }
        #expect(await mock.lastBlockedSendWasCancelled == false)
        switch outcome {
        case .success: #expect(!errorReply)
        case let .failure(error): #expect(errorReply && error is XMPPStanzaError)
        }
        try await client.send(XMPPPresence())
        await disconnectFast(client)
    }
}
