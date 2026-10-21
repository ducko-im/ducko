import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let testAccountID = UUID()
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!
private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

private func makeTranscripts() -> MockTranscriptStore {
    MockTranscriptStore()
}

@MainActor
private func makeChatService(store: MockPersistenceStore, transcripts: MockTranscriptStore) -> ChatService {
    ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
}

// MARK: - Tests

enum ChatServiceRetractionTests {
    struct IncomingRetraction {
        @Test
        @MainActor
        func `message retraction marks retracted and clears body`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "msg-to-retract",
                fromJID: contactJID.description, body: "Secret message",
                timestamp: Date(), isOutgoing: false,
                isDelivered: false, isEdited: false, type: "chat"
            )
            await transcripts.addMessage(message)

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .messageRetracted(originalID: "msg-to-retract", from: from, messageType: .chat),
                accountID: testAccountID
            )

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].isRetracted == true)
            #expect(messages[0].retractedAt != nil)
            let bodyIsEmpty = messages[0].body.isEmpty
            #expect(bodyIsEmpty)
        }
    }

    struct OutgoingModeration {
        @MainActor
        private struct Connected {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let transport = MockTransport()
            let accountService: AccountService
            let chatService: ChatService
            let accountID: UUID

            init() async throws {
                self.accountService = makeAccountService(store: store, clientFactory: MockXMPPClientFactory(transport: transport, modules: [MUCModule()]))
                self.chatService = makeChatService(store: store, transcripts: transcripts)
                chatService.setAccountService(accountService)
                let connectTask = Task { @MainActor [accountService] in
                    try await accountService.createAndConnect(jidString: testJIDString, password: "secret", host: "example.com", port: 5222)
                }
                await simulateNoTLSConnect(transport)
                self.accountID = try await connectTask.value
            }
        }

        @Test
        @MainActor
        func `moderateMessage removes the message in the room and stores it as retracted`() async throws {
            let connected = try await Connected()
            let room = ConversationKind.room.conversation(accountID: connected.accountID)
            await connected.store.addConversation(room)
            await connected.transcripts.addMessage(ConversationKind.room.message(in: room, stanzaID: "m1", serverID: "srv-1", body: "Spam", isOutgoing: false))

            let moderateTask = Task { @MainActor in
                try await connected.chatService.moderateMessage(serverID: "srv-1", in: room, reason: nil, accountID: connected.accountID)
            }
            let raw = try #require(await connected.transport.waitForSent { $0.contains(XMPPNamespaces.messageModerate) })
            #expect(raw.contains("to=\"\(roomJID)\""))
            let iqID = try #require(extractIQID(from: raw))
            await connected.transport.simulateReceive("<iq type=\"result\" id=\"\(iqID)\" from=\"\(roomJID)\"/>")
            try await moderateTask.value

            let messages = try await connected.transcripts.fetchMessages(for: room.id, before: nil, limit: 50)
            #expect(messages.map(\.isRetracted) == [true])
            await connected.accountService.disconnect(accountID: connected.accountID)
        }

        @Test(arguments: [ConversationKind.contact, .privateChat])
        @MainActor
        func `moderateMessage removes nothing outside a room`(kind: ConversationKind) async throws {
            let connected = try await Connected()
            let conversation = kind.conversation(accountID: connected.accountID)
            await connected.store.addConversation(conversation)
            let sentBefore = await connected.transport.sentBytes.count

            let error = await #expect(throws: ChatService.ChatServiceError.self) {
                try await connected.chatService.moderateMessage(serverID: "srv-1", in: conversation, reason: nil, accountID: connected.accountID)
            }
            let isNotRoom = if case .notRoom? = error { true } else { false }
            #expect(isNotRoom)

            #expect(await connected.transport.sentBytes.count == sentBefore)
            #expect(await connected.transcripts.amendments.isEmpty)
            await connected.accountService.disconnect(accountID: connected.accountID)
        }
    }

    struct IncomingModeration {
        @Test
        @MainActor
        func `message moderation marks retracted by server ID`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: roomJID,
                type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "local-id",
                serverID: "server-stanza-id",
                fromJID: "alice", body: "Bad message",
                timestamp: Date(), isOutgoing: false,
                isDelivered: false, isEdited: false, type: "groupchat"
            )
            await transcripts.addMessage(message)

            await service.handleEvent(
                .messageModerated(
                    originalID: "server-stanza-id",
                    moderator: "admin",
                    room: roomJID,
                    reason: "Spam"
                ),
                accountID: testAccountID
            )

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].isRetracted == true)
            #expect(messages[0].retractedAt != nil)
            let bodyIsEmpty = messages[0].body.isEmpty
            #expect(bodyIsEmpty)
        }

        /// A private chat with an occupant shares the room's address, and is looked up before the room by address.
        @Test
        @MainActor
        func `a moderation is applied in the room, not in a private chat with one of its occupants`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let room = ConversationKind.room.conversation(accountID: testAccountID)
            let privateChat = ConversationKind.privateChat.conversation(accountID: testAccountID)
            await store.addConversation(room)
            await store.addConversation(privateChat)
            await transcripts.addMessage(ConversationKind.room.message(in: room, stanzaID: "m1", serverID: "srv-1", body: "Spam", isOutgoing: false))

            await service.handleEvent(.messageModerated(originalID: "srv-1", moderator: "admin", room: roomJID, reason: nil), accountID: testAccountID)

            let messages = try await transcripts.fetchMessages(for: room.id, before: nil, limit: 50)
            #expect(messages.map(\.isRetracted) == [true])
            #expect(await transcripts.amendments.allSatisfy { $0.conversationID == room.id })
        }
    }

    struct OutgoingGuard {
        @Test(arguments: ConversationKind.allCases)
        @MainActor
        func `retractMessage rejects message that is not outgoing`(kind: ConversationKind) async {
            let store = makeStore()
            let service = makeChatService(store: store, transcripts: makeTranscripts())
            let conversation = kind.conversation(accountID: testAccountID)
            await store.addConversation(conversation)
            let incoming = kind.message(in: conversation, stanzaID: "msg-from-peer", serverID: "srv-1", body: "from peer", isOutgoing: false)

            await expectNotOutgoingMessage {
                try await service.retractMessage(incoming, in: conversation, accountID: testAccountID)
            }
        }

        @Test(arguments: ConversationKind.allCases)
        @MainActor
        func `retractMessage rejects outgoing message without stanzaID`(kind: ConversationKind) async {
            let store = makeStore()
            let service = makeChatService(store: store, transcripts: makeTranscripts())
            let conversation = kind.conversation(accountID: testAccountID)
            await store.addConversation(conversation)
            let outgoingNoStanza = kind.message(in: conversation, stanzaID: nil, serverID: "srv-1", body: "never sent", isOutgoing: true)

            await expectNotOutgoingMessage {
                try await service.retractMessage(outgoingNoStanza, in: conversation, accountID: testAccountID)
            }
        }

        /// Otherwise the retraction would go to this conversation's peer while its amendment is written in another one.
        @Test(arguments: ConversationKind.allCases)
        @MainActor
        func `retractMessage rejects message from a different conversation`(kind: ConversationKind) async throws {
            let store = makeStore()
            let service = makeChatService(store: store, transcripts: makeTranscripts())
            let conversation = kind.conversation(accountID: testAccountID)
            await store.addConversation(conversation)
            let foreignOutgoing = kind.message(
                in: kind.conversation(accountID: testAccountID), stanzaID: "ducko-99", serverID: "srv-1", body: "wrong conversation", isOutgoing: true
            )

            let error = await #expect(throws: ChatService.ChatServiceError.self) {
                try await service.retractMessage(foreignOutgoing, in: conversation, accountID: testAccountID)
            }
            let isNotInConversation = if case .messageNotInConversation? = error { true } else { false }
            #expect(isNotInConversation)
        }
    }
}
