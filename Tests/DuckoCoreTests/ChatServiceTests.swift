import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let testAccountID = UUID()
private let testAccountJID = BareJID(localPart: "user", domainPart: "example.com")!
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

private func makeIncomingMessage(
    from jid: BareJID,
    body: String,
    id: String? = nil
) -> XMPPMessage {
    var message = XMPPMessage(
        type: .chat,
        to: .bare(testAccountJID),
        id: id
    )
    message.from = .full(FullJID(bareJID: jid, resourcePart: "res")!)
    message.body = body
    return message
}

/// An incoming message carrying an XEP-0066 out-of-band `<url>`, which is how a contact shares a file by link. It
/// carries a body as well, because a message with neither body nor attachment is not persisted at all — which would
/// leave these tests asserting against a conversation that was never created.
private func makeIncomingOOBMessage(from jid: BareJID, url: String, body: String = "Shared a file") -> XMPPMessage {
    var message = makeIncomingMessage(from: jid, body: body)
    var oob = DuckoXMPP.XMLElement(name: "x", namespace: "jabber:x:oob")
    oob.setChildText(named: "url", to: url)
    message.element.addChild(oob)
    return message
}

// MARK: - Tests

enum ChatServiceTests {
    struct OOBAttachments {
        @Test
        @MainActor
        func `A shared image link carries the type that makes it render as an image`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let message = makeIncomingOOBMessage(from: contactJID, url: "https://example.com/photo.png")
            await service.handleEvent(.messageReceived(message), accountID: testAccountID)

            let conversation = try #require(try await store.fetchConversations(for: testAccountID).first)
            let messages = try await transcripts.fetchMessages(for: conversation.id, before: nil, limit: 50)
            let attachment = try #require(messages.first?.attachments.first)
            // The peer's link names no type, so without deriving one from the extension this renders as a file card.
            #expect(attachment.mimeType == "image/png")
            #expect(attachment.isImage)
        }

        @Test
        @MainActor
        func `A peer's file URL is not taken as an attachment`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let message = makeIncomingOOBMessage(from: contactJID, url: "file:///Users/victim/Pictures/private.png")
            await service.handleEvent(.messageReceived(message), accountID: testAccountID)

            let conversation = try #require(try await store.fetchConversations(for: testAccountID).first)
            let messages = try await transcripts.fetchMessages(for: conversation.id, before: nil, limit: 50)
            // A peer cannot legitimately name a path on this machine, so the link is not kept.
            #expect(messages.first?.body == "Shared a file")
            #expect(messages.first?.attachments.isEmpty == true)
        }
    }

    /// A file shared by link arrives with that link as its body. Fetching a preview for it would request the file the
    /// moment the message arrives, which is the attachment's decision to make.
    struct SharedFileLinkPreview {
        @MainActor
        private func receive(body: String) async throws -> (message: ChatMessage, fetcher: CountingLinkPreviewFetcher) {
            let fetcher = CountingLinkPreviewFetcher()
            let pipeline = MessageFilterPipeline()
            await pipeline.register(LinkDetectionFilter())
            await pipeline.register(LinkPreviewFilter(previewService: LinkPreviewService(fetcher: fetcher, store: MockPersistenceStore())))
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = ChatService(store: store, transcripts: transcripts, filterPipeline: pipeline)

            let message = makeIncomingOOBMessage(from: contactJID, url: "https://example.com/photo.png", body: body)
            await service.handleEvent(.messageReceived(message), accountID: testAccountID)

            let conversation = try #require(try await store.fetchConversations(for: testAccountID).first)
            let persisted = try #require(try await transcripts.fetchMessages(for: conversation.id, before: nil, limit: 50).first)
            return (persisted, fetcher)
        }

        @Test
        @MainActor
        func `A body that only repeats its attachment's link fetches no preview`() async throws {
            let (message, fetcher) = try await receive(body: "https://example.com/photo.png")

            #expect(message.bodyIsAttachmentLink)
            // The fetch is never started, so there is nothing to await. The yields give one that was started the
            // chance to be counted.
            for _ in 0 ..< 5 {
                await Task.yield()
            }
            #expect(await fetcher.invocationCount == 0)
        }

        @Test
        @MainActor
        func `A body with text of its own still previews its link`() async throws {
            let (message, fetcher) = try await receive(body: "look at https://example.com/photo.png")

            #expect(!message.bodyIsAttachmentLink)
            #expect(await pollUntil({ await fetcher.invocationCount == 1 }, timeout: .seconds(5)))
        }
    }

    struct ReceivedFilePreview {
        @Test
        @MainActor
        func `A message that is only a file previews as the file's name`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let attachment = Attachment(
                id: UUID(), url: "file:///tmp/report.pdf", mimeType: "application/pdf",
                fileName: "report.pdf", fileSize: 12
            )

            try await service.recordReceivedFile(attachment, from: contactJID, accountID: testAccountID)

            let conversation = try #require(try await store.fetchConversations(for: testAccountID).first)
            // A received file has no text of its own, so the preview reads as empty unless the name stands in.
            #expect(conversation.lastMessagePreview == "report.pdf")
        }
    }

    struct IncomingMessages {
        @Test
        @MainActor
        func `Incoming message creates conversation and persists message`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let xmppMessage = makeIncomingMessage(from: contactJID, body: "Hello!")
            await service.handleEvent(.messageReceived(xmppMessage), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.count == 1)
            #expect(conversations[0].jid == contactJID)
            #expect(conversations[0].type == .chat)

            let messages = try await transcripts.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages.count == 1)
            #expect(messages[0].body == "Hello!")
            #expect(messages[0].isOutgoing == false)
        }

        @Test
        @MainActor
        func `Incoming message upserts existing conversation`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            // First message creates conversation
            let msg1 = makeIncomingMessage(from: contactJID, body: "First")
            await service.handleEvent(.messageReceived(msg1), accountID: testAccountID)

            // Second message should use same conversation
            let msg2 = makeIncomingMessage(from: contactJID, body: "Second")
            await service.handleEvent(.messageReceived(msg2), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.count == 1)

            let messages = try await transcripts.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages.count == 2)
        }

        @Test
        @MainActor
        func `Duplicate stanza ID is ignored`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let msg1 = makeIncomingMessage(from: contactJID, body: "Hello!", id: "msg-1")
            await service.handleEvent(.messageReceived(msg1), accountID: testAccountID)

            // Load conversations so openConversations is populated for duplicate check
            try await service.loadConversations(for: testAccountID)

            // Same stanza ID should be ignored
            let msg2 = makeIncomingMessage(from: contactJID, body: "Hello!", id: "msg-1")
            await service.handleEvent(.messageReceived(msg2), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            let messages = try await transcripts.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages.count == 1)
        }

        @Test
        @MainActor
        func `Messages without body are ignored`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            // Message with no body
            var xmppMessage = XMPPMessage(type: .chat, to: .bare(testAccountJID))
            xmppMessage.from = try .full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            await service.handleEvent(.messageReceived(xmppMessage), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.isEmpty)
        }

        @Test
        @MainActor
        func `Non-chat messages are ignored`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            var xmppMessage = XMPPMessage(type: .headline, to: .bare(testAccountJID))
            xmppMessage.from = try .full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            xmppMessage.body = "Headline"
            await service.handleEvent(.messageReceived(xmppMessage), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.isEmpty)
        }
    }

    struct IsDuplicateStoreFallback {
        @Test
        @MainActor
        func `Duplicate stanza ID with empty openConversations falls back to store`() async {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            // Pre-seed a conversation in the persistence store and a message in
            // the transcript store, but do NOT call loadConversations — leaves
            // openConversations empty so conversationID(for:) falls through to
            // the store-fetch branch.
            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let seeded = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "msg-1",
                fromJID: contactJID.description, body: "Hello!",
                timestamp: Date(), isOutgoing: false,
                isDelivered: false, isEdited: false, type: "chat"
            )
            await transcripts.addMessage(seeded)

            #expect(service.openConversations.isEmpty)

            // Re-deliver the same stanza ID.
            let duplicate = makeIncomingMessage(from: contactJID, body: "Hello!", id: "msg-1")
            await service.handleEvent(.messageReceived(duplicate), accountID: testAccountID)

            let messageCount = await transcripts.messages.count
            #expect(messageCount == 1)
        }
    }

    struct ConversationMetadata {
        @Test
        @MainActor
        func `Conversation metadata is updated on incoming message`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let msg = makeIncomingMessage(from: contactJID, body: "Test message")
            await service.handleEvent(.messageReceived(msg), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations[0].lastMessagePreview == "Test message")
            #expect(conversations[0].lastMessageDate != nil)
            #expect(conversations[0].unreadCount == 1)
        }

        @Test
        @MainActor
        func `Unread count increments with each message`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let msg1 = makeIncomingMessage(from: contactJID, body: "First")
            await service.handleEvent(.messageReceived(msg1), accountID: testAccountID)

            let msg2 = makeIncomingMessage(from: contactJID, body: "Second")
            await service.handleEvent(.messageReceived(msg2), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations[0].unreadCount == 2)
        }
    }

    struct NonMessageEvents {
        @Test
        @MainActor
        func `Non-message events are ignored`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let presence = XMPPPresence(type: nil)
            await service.handleEvent(.presenceReceived(presence), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.isEmpty)
        }
    }

    struct OpenConversation {
        @Test
        @MainActor
        func `openConversation creates and returns conversation`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let conversation = try await service.openConversation(for: contactJID, accountID: testAccountID)

            #expect(conversation.jid == contactJID)
            #expect(conversation.accountID == testAccountID)
            #expect(service.openConversations.count == 1)
        }

        @Test
        @MainActor
        func `openConversation returns existing conversation`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let first = try await service.openConversation(for: contactJID, accountID: testAccountID)
            let second = try await service.openConversation(for: contactJID, accountID: testAccountID)

            #expect(first.id == second.id)
            #expect(service.openConversations.count == 1)
        }
    }

    struct LoadMessages {
        @Test
        @MainActor
        func `loadMessages returns messages in chronological order`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            // Create messages via incoming events
            let msg1 = makeIncomingMessage(from: contactJID, body: "First")
            await service.handleEvent(.messageReceived(msg1), accountID: testAccountID)
            let msg2 = makeIncomingMessage(from: contactJID, body: "Second")
            await service.handleEvent(.messageReceived(msg2), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            let messages = await service.loadMessages(for: conversations[0].id)

            #expect(messages.count == 2)
            #expect(messages[0].body == "First")
            #expect(messages[1].body == "Second")
        }
    }

    struct FilterPipelineTests {
        @Test
        @MainActor
        func `Message content passes through filter pipeline`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let pipeline = MessageFilterPipeline()
            await pipeline.register(UppercaseFilter())
            let service = ChatService(store: store, transcripts: transcripts, filterPipeline: pipeline)

            let msg = makeIncomingMessage(from: contactJID, body: "hello")
            await service.handleEvent(.messageReceived(msg), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            let messages = try await transcripts.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages[0].body == "HELLO")
        }
    }
}

// MARK: - Test Filter

private struct UppercaseFilter: MessageFilter {
    let priority = 0

    func filter(_ content: MessageContent, direction: FilterDirection, context: FilterContext) async -> MessageContent {
        MessageContent(body: content.body.uppercased(), htmlBody: content.htmlBody)
    }
}
