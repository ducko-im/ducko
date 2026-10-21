import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!
private let occupantJID = JID.full(FullJID(bareJID: roomJID, resourcePart: "bob")!)

/// A room and the private chat with its occupant `bob`, both holding a message whose id is `t1`: in the room the
/// stanza-id the room assigned to bob's message, in the private chat the id of bob's private message.
@MainActor
private struct RoomWithPrivateChat {
    let store = MockPersistenceStore()
    let transcripts = MockTranscriptStore()
    let room: Conversation
    let privateChat: Conversation
    let roomMessage: ChatMessage
    let privateMessage: ChatMessage

    init(accountID: UUID) async {
        self.room = Conversation(
            id: UUID(), accountID: accountID, jid: roomJID, type: .groupchat,
            isPinned: false, isMuted: false, unreadCount: 0, roomNickname: "me", createdAt: Date()
        )
        self.privateChat = Conversation(
            id: UUID(), accountID: accountID, jid: roomJID, type: .chat, displayName: "bob",
            isPinned: false, isMuted: false, unreadCount: 0, occupantNickname: "bob", createdAt: Date()
        )
        self.roomMessage = ChatMessage(
            id: UUID(), conversationID: room.id, stanzaID: "bob-1", serverID: "t1", fromJID: "bob", body: "In the room",
            timestamp: Date(), isOutgoing: false, isDelivered: false, isEdited: false, type: "groupchat"
        )
        self.privateMessage = ChatMessage(
            id: UUID(), conversationID: privateChat.id, stanzaID: "t1", fromJID: "bob", body: "In private",
            timestamp: Date(), isOutgoing: false, isDelivered: false, isEdited: false, type: "chat"
        )
        await store.addConversation(room)
        await store.addConversation(privateChat)
        await transcripts.addMessage(roomMessage)
        await transcripts.addMessage(privateMessage)
    }

    func makeChatService() -> ChatService {
        ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
    }

    func message(_ id: UUID, in conversation: Conversation) async throws -> ChatMessage? {
        try await transcripts.findMessage(id: id, conversationID: conversation.id)
    }
}

/// A chat service connected through a mock transport, so what it sends can be read back.
@MainActor
private struct ConnectedHarness {
    let transport: MockTransport
    let accountService: AccountService
    let accountID: UUID

    static func connect(store: MockPersistenceStore, chatService: ChatService) async throws -> ConnectedHarness {
        let transport = MockTransport()
        let accountService = makeAccountService(store: store, clientFactory: MockXMPPClientFactory(transport: transport, modules: [MUCModule()]))
        chatService.setAccountService(accountService)
        let connectTask = Task { @MainActor in
            try await accountService.createAndConnect(jidString: testJIDString, password: "secret", host: "example.com", port: 5222)
        }
        await simulateNoTLSConnect(transport)
        return try await ConnectedHarness(transport: transport, accountService: accountService, accountID: connectTask.value)
    }

    func sent(containing fragment: String) async -> String? {
        await transport.waitForSent { $0.contains(fragment) }
    }
}

enum ChatServiceRoomAmendmentTests {
    struct RoomRetraction {
        @Test
        @MainActor
        func `Retracting the user's own room message references the room's stanza-id`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
            let harness = try await ConnectedHarness.connect(store: store, chatService: service)
            let room = Conversation(
                id: UUID(), accountID: harness.accountID, jid: roomJID, type: .groupchat,
                isPinned: false, isMuted: false, unreadCount: 0, roomNickname: "me", createdAt: Date()
            )
            await store.addConversation(room)
            let own = ChatMessage(
                id: UUID(), conversationID: room.id, stanzaID: "m1", serverID: "srv-1", fromJID: "me", body: "Mine",
                timestamp: Date(), isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat"
            )
            await transcripts.addMessage(own)

            try await service.retractMessage(own, in: room, accountID: harness.accountID)

            let retraction = try #require(await harness.sent(containing: "<retract"))
            #expect(retraction.contains("id=\"srv-1\""))
            #expect(!retraction.contains("id=\"m1\""))
            #expect(try await transcripts.findMessage(id: own.id, conversationID: room.id)?.isRetracted == true)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        /// The device that sent an encrypted room message cannot read the room's echo of it, which still confirms it with
        /// the stanza-id a retraction names.
        @Test
        @MainActor
        func `The user's own encrypted room message takes the stanza-id the room's unreadable echo carried`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
            let harness = try await ConnectedHarness.connect(store: store, chatService: service)
            let room = Conversation(
                id: UUID(), accountID: harness.accountID, jid: roomJID, type: .groupchat,
                isPinned: false, isMuted: false, unreadCount: 0, roomNickname: "me", createdAt: Date()
            )
            await store.addConversation(room)
            let own = ChatMessage(
                id: UUID(), conversationID: room.id, stanzaID: "m1", fromJID: roomJID.description, body: "Mine",
                timestamp: Date(), isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat", isEncrypted: true
            )
            await transcripts.addMessage(own)
            var echo = try XMPPMessage(type: .groupchat, to: .bare(#require(BareJID.parse(testJIDString))), originID: "m1")
            echo.from = try .full(#require(FullJID(bareJID: roomJID, resourcePart: "me")))
            echo.element.addChild(DuckoXMPP.XMLElement(name: "encrypted", namespace: XMPPNamespaces.omemo))
            echo.element.addChild(DuckoXMPP.XMLElement(name: "stanza-id", namespace: XMPPNamespaces.stanzaID, attributes: ["id": "srv-9", "by": roomJID.description]))

            await service.receiveEncryptedMessage(echo, content: .undecryptable(.notForThisDevice), origin: .live, accountID: harness.accountID)

            #expect(try await transcripts.findMessage(id: own.id, conversationID: room.id)?.serverID == "srv-9")
            #expect(await transcripts.messages.count == 1)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `A room message the room has not echoed is not retracted`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
            let harness = try await ConnectedHarness.connect(store: store, chatService: service)
            let room = Conversation(
                id: UUID(), accountID: harness.accountID, jid: roomJID, type: .groupchat,
                isPinned: false, isMuted: false, unreadCount: 0, roomNickname: "me", createdAt: Date()
            )
            await store.addConversation(room)
            let own = ChatMessage(
                id: UUID(), conversationID: room.id, stanzaID: "m1", fromJID: "me", body: "Mine",
                timestamp: Date(), isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat"
            )
            await transcripts.addMessage(own)

            let error = await #expect(throws: ChatService.ChatServiceError.self) {
                try await service.retractMessage(own, in: room, accountID: harness.accountID)
            }
            let isUnconfirmed = if case .unconfirmedRoomMessage? = error { true } else { false }
            #expect(isUnconfirmed)
            #expect(await transcripts.amendments.isEmpty)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `A room retraction finds its message by the room's stanza-id`() async throws {
            let accountID = UUID()
            let fixture = await RoomWithPrivateChat(accountID: accountID)
            let service = fixture.makeChatService()

            // Retracting by the message's own id finds nothing: in a room only the stanza-id names it.
            await service.handleEvent(.messageRetracted(originalID: "bob-1", from: occupantJID, messageType: .groupchat), accountID: accountID)
            #expect(try await fixture.message(fixture.roomMessage.id, in: fixture.room)?.isRetracted == false)

            await service.handleEvent(.messageRetracted(originalID: "t1", from: occupantJID, messageType: .groupchat), accountID: accountID)

            #expect(try await fixture.message(fixture.roomMessage.id, in: fixture.room)?.isRetracted == true)
            #expect(try await fixture.message(fixture.privateMessage.id, in: fixture.privateChat)?.isRetracted == false)
        }
    }

    struct PrivateChatAmendments {
        @Test
        @MainActor
        func `An occupant's correction and retraction apply in the private chat with them only`() async throws {
            let accountID = UUID()
            let fixture = await RoomWithPrivateChat(accountID: accountID)
            let service = fixture.makeChatService()

            await service.handleEvent(
                .messageCorrected(originalID: "t1", newBody: "Corrected in private", replyFallbackRange: nil, from: occupantJID, messageType: .chat), accountID: accountID
            )
            #expect(try await fixture.message(fixture.privateMessage.id, in: fixture.privateChat)?.body == "Corrected in private")
            #expect(try await fixture.message(fixture.roomMessage.id, in: fixture.room)?.body == "In the room")

            await service.handleEvent(.messageRetracted(originalID: "t1", from: occupantJID, messageType: .chat), accountID: accountID)
            #expect(try await fixture.message(fixture.privateMessage.id, in: fixture.privateChat)?.isRetracted == true)
            #expect(try await fixture.message(fixture.roomMessage.id, in: fixture.room)?.isRetracted == false)
        }

        @Test
        @MainActor
        func `Another occupant's amendment changes the private chat with them, never the one with bob`() async throws {
            let accountID = UUID()
            let fixture = await RoomWithPrivateChat(accountID: accountID)
            let carolsChat = Conversation(
                id: UUID(), accountID: accountID, jid: roomJID, type: .chat, displayName: "carol",
                isPinned: false, isMuted: false, unreadCount: 0, occupantNickname: "carol", createdAt: Date()
            )
            let carolsMessage = ChatMessage(
                id: UUID(), conversationID: carolsChat.id, stanzaID: "t1", fromJID: "carol", body: "From carol",
                timestamp: Date(), isOutgoing: false, isDelivered: false, isEdited: false, type: "chat"
            )
            await fixture.store.addConversation(carolsChat)
            await fixture.transcripts.addMessage(carolsMessage)
            let service = fixture.makeChatService()
            let carol = try JID.full(#require(FullJID(bareJID: roomJID, resourcePart: "carol")))

            await service.handleEvent(.messageRetracted(originalID: "t1", from: carol, messageType: .chat), accountID: accountID)

            #expect(try await fixture.message(carolsMessage.id, in: carolsChat)?.isRetracted == true)
            #expect(try await fixture.message(fixture.privateMessage.id, in: fixture.privateChat)?.isRetracted == false)
            #expect(try await fixture.message(fixture.roomMessage.id, in: fixture.room)?.isRetracted == false)
        }

        @Test
        @MainActor
        func `Correcting, retracting and replying in a private chat go to the occupant and change its rows`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
            let harness = try await ConnectedHarness.connect(store: store, chatService: service)
            let privateChat = try await service.openMUCPMConversation(roomJIDString: roomJID.description, nickname: "bob", accountID: harness.accountID)
            let own = ChatMessage(
                id: UUID(), conversationID: privateChat.id, stanzaID: "m1", fromJID: "bob", body: "Mine",
                timestamp: Date(), isOutgoing: true, isDelivered: false, isEdited: false, type: "chat"
            )
            await transcripts.addMessage(own)
            let occupant = "to=\"\(roomJID)/bob\""

            try await service.sendCorrection(of: own, newBody: "Fixed", in: privateChat, accountID: harness.accountID)
            let correction = try #require(await harness.sent(containing: "<replace"))
            #expect(correction.contains(occupant) && correction.contains("type=\"chat\"") && correction.contains("id=\"m1\""))
            #expect(try await transcripts.findMessage(id: own.id, conversationID: privateChat.id)?.body == "Fixed")

            let bobsMessage = ChatMessage(
                id: UUID(), conversationID: privateChat.id, stanzaID: "bob-1", fromJID: "bob", body: "Question",
                timestamp: Date(), isOutgoing: false, isDelivered: false, isEdited: false, type: "chat"
            )
            try await service.sendMessage("Answer", in: privateChat, replyingTo: bobsMessage, accountID: harness.accountID)
            let reply = try #require(await harness.sent(containing: "<reply"))
            #expect(reply.contains(occupant) && reply.contains("<reply xmlns=\"urn:xmpp:reply:0\" id=\"bob-1\" to=\"\(roomJID)/bob\"/>"))
            let replyRow = try #require(await transcripts.messages.last)
            #expect(replyRow.conversationID == privateChat.id)
            #expect(replyRow.replyToID == "bob-1")
            #expect(replyRow.body == "> Question\nAnswer")

            try await service.retractMessage(own, in: privateChat, accountID: harness.accountID)
            let retraction = try #require(await harness.sent(containing: "<retract"))
            #expect(retraction.contains(occupant) && retraction.contains("id=\"m1\""))
            #expect(try await transcripts.findMessage(id: own.id, conversationID: privateChat.id)?.isRetracted == true)

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }
}
