import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Helpers

private let testAccountID = UUID()
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!

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

/// Seeds a 1:1 conversation with `contactJID` plus one incoming message
/// stanza-id `msg-original`. Returns the conversation id so the test can
/// assert revision bumps without re-deriving it.
@MainActor
private func seedContactConversation(
    store: MockPersistenceStore, transcripts: MockTranscriptStore
) async -> UUID {
    let conversationID = UUID()
    await store.addConversation(Conversation(
        id: conversationID, accountID: testAccountID, jid: contactJID,
        type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
    ))
    await transcripts.addMessage(ChatMessage(
        id: UUID(), conversationID: conversationID, stanzaID: "msg-original",
        fromJID: contactJID.description, body: "Original text",
        timestamp: Date(), isOutgoing: false,
        isDelivered: false, isEdited: false, type: "chat"
    ))
    return conversationID
}

// MARK: - Tests

enum ChatServiceCorrectionTests {
    struct IncomingCorrection {
        @Test
        @MainActor
        func `Message correction updates body and marks edited`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = await seedContactConversation(store: store, transcripts: transcripts)

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .messageCorrected(originalID: "msg-original", newBody: "Corrected text", replyFallbackRange: nil, from: from, messageType: .chat),
                accountID: testAccountID
            )

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].body == "Corrected text")
            #expect(messages[0].isEdited == true)
            #expect(messages[0].editedAt != nil)
        }

        @Test
        @MainActor
        func `Correction bumps messagesRevisions for the affected conversation`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = await seedContactConversation(store: store, transcripts: transcripts)

            // Conversation is NOT the active one — verifies the revision is
            // bumped for the *amended* conversation, not just the active one.
            // This is the load-bearing contract for `ChatWindow`s on
            // background conversations to refresh on incoming amendments.
            #expect(service.activeConversationID != conversationID)
            let beforeRevision = service.messagesRevisions[conversationID] ?? 0

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .messageCorrected(originalID: "msg-original", newBody: "Corrected text", replyFallbackRange: nil, from: from, messageType: .chat),
                accountID: testAccountID
            )

            let afterRevision = service.messagesRevisions[conversationID] ?? 0
            #expect(afterRevision > beforeRevision)
        }

        @Test
        @MainActor
        func `Retraction bumps messagesRevisions for the affected conversation`() async throws {
            // Parallel coverage to the correction case: the same `messagesChanged(in:)`
            // bridge is used by `handleMessageRetracted`, so a regression there
            // would silently break background-window refresh for retract events
            // unless this assertion is locked in independently.
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = await seedContactConversation(store: store, transcripts: transcripts)

            #expect(service.activeConversationID != conversationID)
            let beforeRevision = service.messagesRevisions[conversationID] ?? 0

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .messageRetracted(originalID: "msg-original", from: from, messageType: .chat),
                accountID: testAccountID
            )

            let afterRevision = service.messagesRevisions[conversationID] ?? 0
            #expect(afterRevision > beforeRevision)
        }
    }

    struct SenderVerification {
        @Test
        @MainActor
        func `Correction rejected when sender does not match`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "msg-original",
                fromJID: contactJID.description, body: "Original text",
                timestamp: Date(), isOutgoing: false,
                isDelivered: false, isEdited: false, type: "chat"
            )
            await transcripts.addMessage(message)

            let attacker = try #require(JID.parse("attacker@evil.com/res"))
            await service.handleEvent(
                .messageCorrected(originalID: "msg-original", newBody: "Hacked text", replyFallbackRange: nil, from: attacker, messageType: .chat),
                accountID: testAccountID
            )

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].body == "Original text")
            #expect(messages[0].isEdited == false)
            #expect(messages[0].editedAt == nil)
        }

        /// Stanza IDs are unique only per sender, so the contact's ID can match one the user gave their own message.
        @Test
        @MainActor
        func `Correction edits the contact's message when the user's own message shares its ID`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let own = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "shared-id",
                fromJID: contactJID.description, body: "Own text",
                timestamp: Date(), isOutgoing: true,
                isDelivered: false, isEdited: false, type: "chat"
            )
            let contacts = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "shared-id",
                fromJID: contactJID.description, body: "Contact text",
                timestamp: Date(), isOutgoing: false,
                isDelivered: false, isEdited: false, type: "chat"
            )
            await transcripts.addMessage(own)
            await transcripts.addMessage(contacts)

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .messageCorrected(originalID: "shared-id", newBody: "Corrected text", replyFallbackRange: nil, from: from, messageType: .chat),
                accountID: testAccountID
            )

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            let ownAfter = try #require(messages.first { $0.id == own.id })
            let contactsAfter = try #require(messages.first { $0.id == contacts.id })
            #expect(ownAfter.body == "Own text")
            #expect(contactsAfter.body == "Corrected text")
        }
    }

    struct OutgoingCorrection {
        /// A correction re-sends everything the message carried (XEP-0308 §4).
        @Test(arguments: ConversationKind.allCases)
        @MainActor
        func `Correcting a message re-sends its reply and its attachment`(kind: ConversationKind) async throws {
            let harness = try await makeFilterHarness(modules: [ChatModule(), MUCModule()], filters: [])
            let conversation = kind.conversation(accountID: harness.accountID)
            try await harness.store.upsertConversation(conversation)
            let link = "https://upload.example.com/photo.png"
            var original = kind.message(in: conversation, stanzaID: "own-1", body: "> Hi\nLook", isOutgoing: true)
            original.replyToID = "q1"
            original.replyToJID = kind.recipient
            original.replyFallbackRange = 0 ..< 5
            original.attachments = [Attachment(id: UUID(), url: link, fileName: "photo.png")]
            await harness.transcripts.addMessage(original)

            try await harness.chatService.sendCorrection(of: original, newBody: "Look at this", in: conversation, accountID: harness.accountID)

            let sent = try #require(await harness.transport.waitForSent { $0.contains("<replace") })
            #expect(sent.contains("to=\"\(kind.recipient)\"") && sent.contains("type=\"\(kind.messageType)\""))
            #expect(sent.contains("<replace xmlns=\"urn:xmpp:message-correct:0\" id=\"own-1\"/>"))
            #expect(sent.contains("<body>&gt; Hi\nLook at this</body>"))
            #expect(sent.contains("<reply xmlns=\"urn:xmpp:reply:0\" id=\"q1\" to=\"\(kind.recipient)\"/>"))
            #expect(sent.contains("<fallback xmlns=\"urn:xmpp:fallback:0\" for=\"urn:xmpp:reply:0\"><body end=\"5\" start=\"0\"/></fallback>"))
            #expect(sent.contains("<x xmlns=\"jabber:x:oob\"><url>\(link)</url></x>"))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct OutgoingGuard {
        @Test(arguments: ConversationKind.allCases)
        @MainActor
        func `sendCorrection rejects message that is not outgoing`(kind: ConversationKind) async {
            let store = makeStore()
            let service = makeChatService(store: store, transcripts: makeTranscripts())
            let conversation = kind.conversation(accountID: testAccountID)
            await store.addConversation(conversation)
            let incoming = kind.message(in: conversation, stanzaID: "msg-original", body: "Original text", isOutgoing: false)

            await expectNotOutgoingMessage {
                try await service.sendCorrection(of: incoming, newBody: "edited", in: conversation, accountID: testAccountID)
            }
        }

        @Test(arguments: ConversationKind.allCases)
        @MainActor
        func `sendCorrection rejects outgoing message without stanzaID`(kind: ConversationKind) async {
            let store = makeStore()
            let service = makeChatService(store: store, transcripts: makeTranscripts())
            let conversation = kind.conversation(accountID: testAccountID)
            await store.addConversation(conversation)
            let outgoingNoStanza = kind.message(in: conversation, stanzaID: nil, body: "Never sent", isOutgoing: true)

            await expectNotOutgoingMessage {
                try await service.sendCorrection(of: outgoingNoStanza, newBody: "edited", in: conversation, accountID: testAccountID)
            }
        }

        /// Otherwise the correction would go to this conversation's peer while its amendment is written in another one.
        @Test(arguments: ConversationKind.allCases)
        @MainActor
        func `sendCorrection rejects message from a different conversation`(kind: ConversationKind) async throws {
            let store = makeStore()
            let service = makeChatService(store: store, transcripts: makeTranscripts())
            let conversation = kind.conversation(accountID: testAccountID)
            await store.addConversation(conversation)
            let foreignOutgoing = kind.message(in: kind.conversation(accountID: testAccountID), stanzaID: "ducko-99", body: "Elsewhere", isOutgoing: true)

            let error = await #expect(throws: ChatService.ChatServiceError.self) {
                try await service.sendCorrection(of: foreignOutgoing, newBody: "edited", in: conversation, accountID: testAccountID)
            }
            let isNotInConversation = if case .messageNotInConversation? = error { true } else { false }
            #expect(isNotInConversation)
        }
    }
}
