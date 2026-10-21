import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let testAccountID = UUID()
private let testAccountJID = BareJID(localPart: "user", domainPart: "example.com")!
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!
private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

@MainActor
private func makeChatService(store: MockPersistenceStore, transcripts: MockTranscriptStore) -> ChatService {
    ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
}

// MARK: - Tests

enum ChatServiceReplyTests {
    struct IncomingReply {
        @Test
        @MainActor
        func `Incoming message with reply element sets replyToID`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = makeChatService(store: store, transcripts: transcripts)

            var xmppMessage = XMPPMessage(type: .chat, to: .bare(testAccountJID), id: "reply-msg-1")
            xmppMessage.from = try .full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            xmppMessage.body = "This is a reply"
            let replyElement = XMLElement(
                name: "reply",
                namespace: XMPPNamespaces.messageReply,
                attributes: ["to": "contact@example.com", "id": "original-msg-1"]
            )
            xmppMessage.element.addChild(replyElement)

            await service.handleEvent(.messageReceived(xmppMessage), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            let messages = try await transcripts.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages[0].replyToID == "original-msg-1")
            #expect(messages[0].body == "This is a reply")
        }

        @Test
        @MainActor
        func `Incoming message without reply element has nil replyToID`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = makeChatService(store: store, transcripts: transcripts)

            var xmppMessage = XMPPMessage(type: .chat, to: .bare(testAccountJID), id: "plain-msg-1")
            xmppMessage.from = try .full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            xmppMessage.body = "Just a normal message"

            await service.handleEvent(.messageReceived(xmppMessage), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            let messages = try await transcripts.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages[0].replyToID == nil)
        }
    }
}

extension ChatServiceReplyTests {
    struct OutgoingReply {
        @Test(arguments: [false, true])
        @MainActor
        func `A reply starts with an unfiltered quote of the message and names its author`(quotesOwnMessage: Bool) async throws {
            let harness = try await makeFilterHarness(modules: [ChatModule()], filters: [EmojiFilter()])
            let conversation = try await seedPlaintextChat(harness)
            let quoted = ChatMessage(
                id: UUID(), conversationID: conversation.id, stanzaID: "c1", fromJID: contactJID.description, body: "Hi :)",
                timestamp: Date(), isOutgoing: quotesOwnMessage, isDelivered: false, isEdited: false, type: "chat"
            )

            try await harness.chatService.sendMessage("ok :)", in: conversation, replyingTo: quoted, accountID: harness.accountID)

            let author = quotesOwnMessage ? testJIDString : contactJID.description
            let sent = try #require(await harness.transport.waitForSent { $0.contains("<reply") })
            #expect(sent.contains("<reply xmlns=\"urn:xmpp:reply:0\" id=\"c1\" to=\"\(author)\"/>"))
            #expect(sent.contains("<body>&gt; Hi :)\nok \u{1F60A}</body>"))
            #expect(sent.contains("<fallback xmlns=\"urn:xmpp:fallback:0\" for=\"urn:xmpp:reply:0\"><body end=\"8\" start=\"0\"/></fallback>"))
            // A reply requests a receipt and is markable like any message, and its correction re-sends both (XEP-0308).
            #expect(sent.contains("<request xmlns=\"urn:xmpp:receipts\"/>"))
            #expect(sent.contains("<markable xmlns=\"urn:xmpp:chat-markers:0\"/>"))
            let stored = try #require(await harness.transcripts.messages.last)
            #expect(stored.body == "> Hi :)\nok \u{1F60A}")
            #expect(stored.replyFallbackRange == 0 ..< 8)
            #expect(stored.replyToID == "c1")
            #expect(stored.replyToJID == author)

            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `A room reply names the message by the room's stanza-id and its author by their address in the room`() async throws {
            let harness = try await makeFilterHarness(modules: [MUCModule()], filters: [])
            let room = try await seedPlaintextRoom(harness)
            let quoted = ChatMessage(
                id: UUID(), conversationID: room.id, stanzaID: "bob-1", serverID: "t1", fromJID: "bob", body: "Hi",
                timestamp: Date(), isOutgoing: false, isDelivered: false, isEdited: false, type: "groupchat"
            )

            try await harness.chatService.sendMessage("ok", in: room, replyingTo: quoted, accountID: harness.accountID)

            let sent = try #require(await harness.transport.waitForSent { $0.contains("<reply") })
            #expect(sent.contains("type=\"groupchat\""))
            #expect(sent.contains("<reply xmlns=\"urn:xmpp:reply:0\" id=\"t1\" to=\"\(roomJID)/bob\"/>"))
            let stored = try #require(await harness.transcripts.messages.last)
            #expect(stored.body == "> Hi\nok")
            #expect(stored.replyToID == "t1")

            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        /// The quote would carry the encrypted message's text in the clear. XEP-0461 leaves the quote out as an option.
        @Test(arguments: ConversationKind.allCases)
        @MainActor
        func `A reply sent in the clear to an encrypted message carries no quote of it`(kind: ConversationKind) async throws {
            let harness = try await makeFilterHarness(modules: [ChatModule(), MUCModule()], filters: [])
            let conversation = kind.conversation(accountID: harness.accountID)
            try await harness.store.upsertConversation(conversation)
            let quoted = kind.message(in: conversation, stanzaID: "q1", serverID: "t1", body: "secret", isOutgoing: false, isEncrypted: true)

            try await harness.chatService.sendMessage("ok", in: conversation, replyingTo: quoted, accountID: harness.accountID)

            let sent = try #require(await harness.transport.waitForSent { $0.contains("<reply") })
            #expect(sent.contains("to=\"\(kind.recipient)\""))
            #expect(sent.contains("<body>ok</body>"))
            #expect(!sent.contains("secret"))
            #expect(!sent.contains(XMPPNamespaces.fallbackIndication))
            let stored = try #require(await harness.transcripts.messages.last)
            #expect(stored.body == "ok")
            #expect(stored.replyToID == quoted.replyReference)

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }
}

extension ChatServiceReplyTests {
    struct ReplyCorrection {
        @Test
        @MainActor
        func `Correcting a reply drawn without its quote re-sends the reply with one quote`() async throws {
            let harness = try await makeFilterHarness(modules: [ChatModule()], filters: [])
            let conversation = try await seedPlaintextChat(harness)
            let quoted = ChatMessage(
                id: UUID(), conversationID: conversation.id, stanzaID: "c1", fromJID: contactJID.description, body: "Hi",
                timestamp: Date(), isOutgoing: false, isDelivered: false, isEdited: false, type: "chat"
            )
            try await harness.chatService.sendMessage("ok", in: conversation, replyingTo: quoted, accountID: harness.accountID)
            let reply = try #require(await harness.transcripts.messages.last)

            try await harness.chatService.sendCorrection(
                of: reply.hidingReplyFallback(), newBody: "fine", in: conversation, accountID: harness.accountID
            )

            let sent = try #require(await harness.transport.waitForSent { $0.contains("<replace") })
            #expect(sent.contains("<reply xmlns=\"urn:xmpp:reply:0\" id=\"c1\" to=\"\(contactJID)\"/>"))
            #expect(sent.contains("<body>&gt; Hi\nfine</body>"))
            #expect(sent.contains("<fallback xmlns=\"urn:xmpp:fallback:0\" for=\"urn:xmpp:reply:0\"><body end=\"5\" start=\"0\"/></fallback>"))
            #expect(sent.contains("<request xmlns=\"urn:xmpp:receipts\"/>"))
            #expect(sent.contains("<markable xmlns=\"urn:xmpp:chat-markers:0\"/>"))
            let stored = try #require(await harness.transcripts.fetchMessages(for: conversation.id, before: nil, limit: 50).first { $0.id == reply.id })
            #expect(stored.body == "> Hi\nfine")
            #expect(stored.replyFallbackRange == 0 ..< 5)

            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test(arguments: [("> Hello\nfine", 0 ..< 8), ("fine", nil)] as [(String, Range<Int>?)])
        @MainActor
        func `An incoming correction of a reply is stored with its own quote`(newBody: String, replyFallbackRange: Range<Int>?) async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            await transcripts.addMessage(ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "r1", fromJID: contactJID.description, body: "> Hi\nok",
                timestamp: Date(), isOutgoing: false, isDelivered: false, isEdited: false, type: "chat",
                replyToID: "u1", replyToJID: testAccountJID.description, replyFallbackRange: 0 ..< 5
            ))

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .messageCorrected(originalID: "r1", newBody: newBody, replyFallbackRange: replyFallbackRange, from: from, messageType: .chat),
                accountID: testAccountID
            )

            let stored = try #require(await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50).first)
            #expect(stored.body == newBody)
            #expect(stored.replyFallbackRange == replyFallbackRange)
            #expect(stored.hidingReplyFallback().body == "fine")
        }
    }
}

@MainActor
extension ChatServiceReplyTests {
    @Test(arguments: [false, true])
    static func `live stanza metadata survives transcript reopening`(hasReply: Bool) async throws {
        try await verifyPersistedInboundMetadata(origin: .live, hasReply: hasReply)
    }
}
