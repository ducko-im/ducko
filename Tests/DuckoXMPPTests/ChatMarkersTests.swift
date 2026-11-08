import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeClient(mock: MockTransport, module: some XMPPModule) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false, allowsPLAIN: true
    )
    await client.register(module)

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum ChatMarkersTests {
    struct Markable {
        @Test
        func `Sends markable element when markable is true`() async throws {
            let mock = MockTransport()
            let client = try await makeClient(mock: mock, module: ChatModule())
            let module = try #require(await client.module(ofType: ChatModule.self))

            await mock.clearSentBytes()

            let recipient = try #require(JID.parse("contact@example.com"))
            try await module.sendMessage(to: recipient, body: "Hello", markable: true)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let msg = sentStrings.first { $0.contains("<markable") && $0.contains("urn:xmpp:chat-markers:0") }
            #expect(msg != nil)

            await disconnectFast(client)
        }

        @Test
        func `Does not send markable element when markable is false`() async throws {
            let mock = MockTransport()
            let client = try await makeClient(mock: mock, module: ChatModule())
            let module = try #require(await client.module(ofType: ChatModule.self))

            await mock.clearSentBytes()

            let recipient = try #require(JID.parse("contact@example.com"))
            try await module.sendMessage(to: recipient, body: "Hello", markable: false)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let msg = sentStrings.first { $0.contains("<markable") }
            #expect(msg == nil)

            await disconnectFast(client)
        }
    }

    struct MUCMarkable {
        @Test
        func `Sends markable element in groupchat message`() async throws {
            let mock = MockTransport()
            let client = try await makeClient(mock: mock, module: MUCModule())
            let module = try #require(await client.module(ofType: MUCModule.self))

            await mock.clearSentBytes()

            let room = try #require(BareJID.parse("room@conference.example.com"))
            try await module.sendMessage(to: room, body: "Hello room", markable: true)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let msg = sentStrings.first {
                $0.contains("type=\"groupchat\"") && $0.contains("<markable") && $0.contains("urn:xmpp:chat-markers:0")
            }
            #expect(msg != nil)

            await disconnectFast(client)
        }
    }

    struct DisplayedMarker {
        @Test
        func `Sends displayed marker with chat type by default`() async throws {
            let mock = MockTransport()
            let client = try await makeClient(mock: mock, module: ReceiptsModule())
            let module = try #require(await client.module(ofType: ReceiptsModule.self))

            await mock.clearSentBytes()

            let recipient = try #require(JID.parse("contact@example.com"))
            try await module.sendDisplayedMarker(to: recipient, messageID: "msg-1")

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let msg = try #require(sentStrings.first { $0.contains("<displayed") && $0.contains("urn:xmpp:chat-markers:0") })
            #expect(msg.contains("id=\"msg-1\""))
            #expect(msg.contains("type=\"chat\""))
            #expect(msg.contains("<private"))

            await disconnectFast(client)
        }

        @Test
        func `Sends displayed marker with groupchat type without private`() async throws {
            let mock = MockTransport()
            let client = try await makeClient(mock: mock, module: ReceiptsModule())
            let module = try #require(await client.module(ofType: ReceiptsModule.self))

            await mock.clearSentBytes()

            let recipient = try #require(JID.parse("room@conference.example.com"))
            try await module.sendDisplayedMarker(to: recipient, messageID: "srv-42", messageType: .groupchat)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let msg = try #require(sentStrings.first { $0.contains("<displayed") && $0.contains("urn:xmpp:chat-markers:0") })
            #expect(msg.contains("id=\"srv-42\""))
            #expect(msg.contains("type=\"groupchat\""))
            #expect(!msg.contains("<private"))

            await disconnectFast(client)
        }
    }
}
