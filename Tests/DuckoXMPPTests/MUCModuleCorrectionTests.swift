import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(MUCModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

private let testRoomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

// MARK: - Tests

enum MUCModuleCorrectionTests {
    struct IncomingCorrection {
        @Test
        func `Groupchat correction emits messageCorrected`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageCorrected = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message type='groupchat' from='room@conference.example.com/alice' id='msg-2'>\
            <body>Hello (corrected)</body>\
            <replace xmlns='urn:xmpp:message-correct:0' id='msg-1'/>\
            <fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='6'/></fallback>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .messageCorrected(originalID, newBody, replyFallbackRange, from, messageType) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageCorrected")
            }
            #expect(originalID == "msg-1")
            #expect(newBody == "Hello (corrected)")
            #expect(replyFallbackRange == 0 ..< 6)
            #expect(messageType == .groupchat)
            #expect(from.bareJID == testRoomJID)

            await disconnectFast(client)
        }

        @Test
        func `Correction without body is ignored`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client, timeout: .seconds(1)) { event in
                    if case .messageCorrected = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message type='groupchat' from='room@conference.example.com/alice' id='msg-2'>\
            <replace xmlns='urn:xmpp:message-correct:0' id='msg-1'/>\
            </message>
            """)

            do {
                _ = try await eventsTask.value
                throw XMPPClientError.unexpectedStreamState("Should not emit event")
            } catch is XMPPClientError {
                // Expected — timeout because no messageCorrected event was emitted
            }

            await disconnectFast(client)
        }
    }

    struct PrivateChatAmendments {
        /// The private message after the amendment marks the end of what the amendment produced.
        @Test(arguments: [
            "<retract xmlns='urn:xmpp:message-retract:1' id='pm-1'/><fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:message-retract:1'/>"
                + "<body>This person attempted to retract a previous message, but it's unsupported by your client.</body>",
            "<replace xmlns='urn:xmpp:message-correct:0' id='pm-1'/><body>Fixed</body>"
        ])
        func `An occupant's private correction or retraction is not a private message`(amendment: String) async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com", credentials: .init(username: "user", password: "pass"), transport: mock, requireTLS: false
            )
            await client.register(ChatModule())
            await client.register(MUCModule())
            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value
            let module = try #require(await client.module(ofType: MUCModule.self))
            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .mucPrivateMessageReceived = event { return true }
                    return false
                }
            }
            await mock.simulateReceive("<message type='chat' from='room@conference.example.com/alice' id='pm-2'>\(amendment)</message>")
            await mock.simulateReceive("<message type='chat' from='room@conference.example.com/alice' id='pm-3'><body>Next</body></message>")

            let events = try await eventsTask.value
            let privateMessageIDs = events.compactMap { event -> String? in
                guard case let .mucPrivateMessageReceived(message) = event else { return nil }
                return message.id
            }
            #expect(privateMessageIDs == ["pm-3"])
            let amendmentTypes = events.compactMap { event -> XMPPMessage.MessageType? in
                if case let .messageCorrected(_, _, _, _, messageType) = event { return messageType }
                if case let .messageRetracted(_, _, messageType) = event { return messageType }
                return nil
            }
            #expect(amendmentTypes == [.chat])

            await disconnectFast(client)
        }
    }
}
