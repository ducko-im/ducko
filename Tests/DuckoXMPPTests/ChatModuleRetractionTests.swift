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
    await client.register(ChatModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

private func makeConnectedClientWithMUC(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(ChatModule())
    await client.register(MUCModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum ChatModuleRetractionTests {
    struct IncomingRetraction {
        @Test
        func `emits message retracted for incoming retraction`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageRetracted = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='chat' id='retract-1'>\
            <retract xmlns='urn:xmpp:message-retract:1' id='orig-msg-1'/>\
            <fallback for='urn:xmpp:message-retract:1' xmlns='urn:xmpp:fallback:0'/>\
            <body>This person attempted to retract a previous message, but it's unsupported by your client.</body>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .messageRetracted(originalID, from, messageType) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageRetracted")
            }
            #expect(originalID == "orig-msg-1")
            #expect(from.bareJID.description == "contact@example.com")
            #expect(messageType == .chat)

            await disconnectFast(client)
        }
    }

    struct SendRetraction {
        @Test
        func `sends retraction XML with retract element`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: ChatModule.self))

            await mock.clearSentBytes()

            let recipient = try #require(JID.parse("contact@example.com"))
            try await module.sendRetraction(to: recipient, originalID: "orig-msg-1")

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let retractionMsg = sentStrings.first {
                $0.contains("<retract") && $0.contains("urn:xmpp:message-retract:1") && $0.contains("id=\"orig-msg-1\"")
            }
            #expect(retractionMsg != nil)
            if let msg = retractionMsg {
                #expect(msg.contains("<fallback"))
                #expect(msg.contains("urn:xmpp:fallback:0"))
                #expect(msg.contains("<store"))
                #expect(msg.contains("urn:xmpp:hints"))
            }

            await disconnectFast(client)
        }
    }

    struct MUCRetraction {
        @Test
        func `emits message retracted for groupchat retraction`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClientWithMUC(mock: mock)
            let mucModule = try #require(await client.module(ofType: MUCModule.self))

            // Join room first
            await mock.clearSentBytes()
            try await mucModule.joinRoom(
                #require(BareJID.parse("room@conference.example.com")),
                nickname: "user"
            )
            await mock.waitForSent(count: 1)

            // Simulate self-presence (join confirmation)
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/user' to='user@example.com/ducko'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            <status code='110'/>\
            </x>\
            </presence>
            """)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageRetracted = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='room@conference.example.com/alice' to='user@example.com/ducko' type='groupchat' id='retract-gc-1'>\
            <retract xmlns='urn:xmpp:message-retract:1' id='orig-gc-1'/>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .messageRetracted(originalID, from, messageType) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageRetracted")
            }
            #expect(originalID == "orig-gc-1")
            #expect(from.bareJID.description == "room@conference.example.com")
            #expect(messageType == .groupchat)

            await disconnectFast(client)
        }
    }

    struct MUCModeration {
        @Test
        func `emits message moderated for moderation retraction`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClientWithMUC(mock: mock)
            let mucModule = try #require(await client.module(ofType: MUCModule.self))

            // Join room first
            await mock.clearSentBytes()
            try await mucModule.joinRoom(
                #require(BareJID.parse("room@conference.example.com")),
                nickname: "user"
            )
            await mock.waitForSent(count: 1)

            // Simulate self-presence (join confirmation)
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/user' to='user@example.com/ducko'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            <status code='110'/>\
            </x>\
            </presence>
            """)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageModerated = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='room@conference.example.com' to='user@example.com/ducko' type='groupchat' id='mod-1'>\
            <retract xmlns='urn:xmpp:message-retract:1' id='stanza-id-1'>\
            <moderated xmlns='urn:xmpp:message-moderate:1' by='admin'/>\
            <reason>Spam</reason>\
            </retract>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .messageModerated(originalID, moderator, room, reason) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageModerated")
            }
            #expect(originalID == "stanza-id-1")
            #expect(moderator == "admin")
            #expect(room.description == "room@conference.example.com")
            #expect(reason == "Spam")

            await disconnectFast(client)
        }
    }

    struct ModerationBareJIDValidation {
        @Test
        func `rejects moderation from full JID with resource part`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClientWithMUC(mock: mock)
            let mucModule = try #require(await client.module(ofType: MUCModule.self))

            // Join room first
            await mock.clearSentBytes()
            try await mucModule.joinRoom(
                #require(BareJID.parse("room@conference.example.com")),
                nickname: "user"
            )
            await mock.waitForSent(count: 1)

            // Simulate self-presence (join confirmation)
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/user' to='user@example.com/ducko'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            <status code='110'/>\
            </x>\
            </presence>
            """)

            let eventsTask = Task {
                try await collectEvents(from: client, timeout: .seconds(1)) { event in
                    if case .messageModerated = event { return true }
                    return false
                }
            }

            // Moderation from a full JID (occupant) — should be rejected
            await mock.simulateReceive("""
            <message from='room@conference.example.com/attacker' to='user@example.com/ducko' type='groupchat' id='mod-bad'>\
            <retract xmlns='urn:xmpp:message-retract:1' id='stanza-id-2'>\
            <moderated xmlns='urn:xmpp:message-moderate:1' by='attacker'/>\
            <reason>Spoofed</reason>\
            </retract>\
            </message>
            """)

            let events = await (try? eventsTask.value) ?? []
            let hasModeration = events.contains {
                if case .messageModerated = $0 { return true }
                return false
            }
            #expect(!hasModeration)

            await disconnectFast(client)
        }
    }

    struct RetractionFeature {
        @Test
        func `chat module declares retraction feature`() {
            let module = ChatModule()
            #expect(module.features.contains("urn:xmpp:message-retract:1"))
        }
    }
}
