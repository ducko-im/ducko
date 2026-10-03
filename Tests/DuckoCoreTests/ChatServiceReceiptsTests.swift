import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

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

/// Stores a chat with the contact holding `rows`.
@MainActor
private func seedChat(_ rows: [ChatMessage], in conversationID: UUID, store: MockPersistenceStore, transcripts: MockTranscriptStore) async {
    await store.addConversation(Conversation(
        id: conversationID, accountID: testAccountID, jid: contactJID,
        type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
    ))
    for row in rows {
        await transcripts.addMessage(row)
    }
}

/// A message in the chat with the contact, `offset` seconds into it.
private func row(
    _ stanzaID: String?, in conversationID: UUID, at offset: Double, isOutgoing: Bool = true,
    errorText: String? = nil, attachments: [DuckoCore.Attachment] = []
) -> ChatMessage {
    ChatMessage(
        id: UUID(), conversationID: conversationID, stanzaID: stanzaID,
        fromJID: contactJID.description, body: stanzaID ?? "",
        timestamp: Date(timeIntervalSince1970: 1_700_000_000 + offset), isOutgoing: isOutgoing,
        isDelivered: false, isEdited: false, type: "chat", errorText: errorText, attachments: attachments
    )
}

@MainActor
private func deliverMarker(_ stanzaID: String, to service: ChatService) async throws {
    let from = try #require(JID.parse("contact@example.com/res"))
    await service.handleEvent(.chatMarkerReceived(messageID: stanzaID, type: .displayed, from: from), accountID: testAccountID)
}

@MainActor
private func deliverReceipt(_ stanzaID: String, to service: ChatService) async throws {
    let from = try #require(JID.parse("contact@example.com/res"))
    await service.handleEvent(.deliveryReceiptReceived(messageID: stanzaID, from: from), accountID: testAccountID)
}

/// What another of the user's devices sent the contact, as this device gets to see it.
private func sentCarbon(of child: String, namespace: String, naming stanzaID: String) -> XMPPEvent {
    var message = XMPPMessage(type: .chat, to: .bare(contactJID), id: "carbon-1")
    var element = DuckoXMPP.XMLElement(name: child, namespace: namespace)
    element.setAttribute("id", value: stanzaID)
    message.element.addChild(element)
    return .messageCarbonSent(ForwardedMessage(message: message, timestamp: nil))
}

/// What the contact sent another of the user's devices, as this device gets to see it.
private func receivedCarbon(of child: String, namespace: String, naming stanzaID: String) throws -> XMPPEvent {
    var message = XMPPMessage(type: .chat, to: .bare(contactJID), id: "carbon-2")
    message.from = try .full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
    var element = DuckoXMPP.XMLElement(name: child, namespace: namespace)
    element.setAttribute("id", value: stanzaID)
    message.element.addChild(element)
    return .messageCarbonReceived(ForwardedMessage(message: message, timestamp: nil))
}

// MARK: - Tests

enum ChatServiceReceiptsTests {
    struct DeliveryReceipt {
        @Test
        @MainActor
        func `Delivery receipt updates isDelivered`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "outgoing-1",
                fromJID: contactJID.description, body: "Hello",
                timestamp: Date(), isOutgoing: true,
                isDelivered: false, isEdited: false, type: "chat"
            )
            await transcripts.addMessage(message)

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .deliveryReceiptReceived(messageID: "outgoing-1", from: from),
                accountID: testAccountID
            )

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].isDelivered == true)
        }

        @Test
        @MainActor
        func `Delivery receipt marks the sent message, not a received one with the same id`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = UUID()
            let sent = row("ducko-7", in: conversationID, at: 0)
            let received = row("ducko-7", in: conversationID, at: 1, isOutgoing: false)
            await seedChat([sent, received], in: conversationID, store: store, transcripts: transcripts)

            try await deliverReceipt("ducko-7", to: service)

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages.first { $0.id == sent.id }?.isDelivered == true)
            #expect(messages.first { $0.id == received.id }?.isDelivered == false)
        }

        @Test
        @MainActor
        func `Delivery receipt naming only a received message records nothing`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = UUID()
            let received = row("ducko-7", in: conversationID, at: 0, isOutgoing: false)
            await seedChat([received], in: conversationID, store: store, transcripts: transcripts)

            try await deliverReceipt("ducko-7", to: service)

            #expect(await transcripts.amendments.isEmpty)
        }

        @Test
        @MainActor
        func `A receipt another of the user's devices sent says nothing about the user's own messages`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = UUID()
            // The contact's message and one of the user's own carry the same stanza id.
            let sent = row("ducko-7", in: conversationID, at: 0)
            let received = row("ducko-7", in: conversationID, at: 1, isOutgoing: false)
            await seedChat([sent, received], in: conversationID, store: store, transcripts: transcripts)

            await service.handleEvent(
                sentCarbon(of: "received", namespace: XMPPNamespaces.receipts, naming: "ducko-7"), accountID: testAccountID
            )
            #expect(await transcripts.amendments.isEmpty)

            // Control: the same receipt, sent by the contact to another of the user's devices, does mark the sent message.
            try await service.handleEvent(
                receivedCarbon(of: "received", namespace: XMPPNamespaces.receipts, naming: "ducko-7"), accountID: testAccountID
            )
            #expect(await transcripts.amendments.count == 1)
            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages.first { $0.id == sent.id }?.isDelivered == true)
        }

        @Test
        @MainActor
        func `A receipt for a sent message beyond the newest ones finds it behind a received one with the same id`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = UUID()
            let received = row("ducko-7", in: conversationID, at: 0, isOutgoing: false)
            let sent = row("ducko-7", in: conversationID, at: 1)
            let newer = (0 ..< 200).map { row("newer-\($0)", in: conversationID, at: Double(2 + $0), isOutgoing: false) }
            await seedChat([received, sent] + newer, in: conversationID, store: store, transcripts: transcripts)

            try await deliverReceipt("ducko-7", to: service)

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 500)
            #expect(messages.first { $0.id == sent.id }?.isDelivered == true)
            #expect(messages.first { $0.id == received.id }?.isDelivered == false)
        }

        @Test
        @MainActor
        func `A receipt beyond the newest messages lands on the newest sent message with that id`() async throws {
            try await withTemporaryDirectory { directory in
                let store = makeStore()
                // The file store keeps a day per file and lists the newest day first, which the mock does not model.
                let transcripts = FileTranscriptStore(baseDirectory: directory)
                let service = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
                let conversationID = UUID()
                await store.addConversation(Conversation(
                    id: conversationID, accountID: testAccountID, jid: contactJID,
                    type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
                ))
                let day: TimeInterval = 24 * 60 * 60
                // The contact's client restarted between the two days and reused the id.
                let earlier = row("ducko-7", in: conversationID, at: 0)
                let later = row("ducko-7", in: conversationID, at: day)
                try await transcripts.appendMessage(earlier)
                try await transcripts.appendMessage(later)
                for index in 0 ..< 200 {
                    try await transcripts.appendMessage(
                        row("received-\(index)", in: conversationID, at: 2 * day + Double(index), isOutgoing: false)
                    )
                }

                try await deliverReceipt("ducko-7", to: service)

                let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 500)
                #expect(messages.first { $0.id == later.id }?.isDelivered == true)
                #expect(messages.first { $0.id == earlier.id }?.isDelivered == false)
            }
        }

        @Test
        @MainActor
        func `A receipt from a room's occupant speaks only for the private chat with that occupant`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let roomJID = try #require(BareJID(localPart: "room", domainPart: "conference.example.com"))
            let privateChatID = UUID()
            await store.addConversation(Conversation(
                id: UUID(), accountID: testAccountID, jid: roomJID,
                type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            await store.addConversation(Conversation(
                id: privateChatID, accountID: testAccountID, jid: roomJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, occupantNickname: "carol", createdAt: Date()
            ))
            let sent = row("ducko-5", in: privateChatID, at: 0)
            await transcripts.addMessage(sent)
            try await service.loadConversations(for: testAccountID)

            // Another occupant names the id of the message the user wrote to carol.
            let other = try #require(JID.parse("room@conference.example.com/bob"))
            await service.handleEvent(.deliveryReceiptReceived(messageID: "ducko-5", from: other), accountID: testAccountID)
            #expect(await transcripts.amendments.isEmpty)

            // Control: carol's own receipt marks it.
            let carol = try #require(JID.parse("room@conference.example.com/carol"))
            await service.handleEvent(.deliveryReceiptReceived(messageID: "ducko-5", from: carol), accountID: testAccountID)
            let messages = try await transcripts.fetchMessages(for: privateChatID, before: nil, limit: 50)
            #expect(messages.first?.isDelivered == true)
        }
    }

    struct ChatMarker {
        @Test
        @MainActor
        func `Displayed chat marker marks the message read`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "outgoing-2",
                fromJID: contactJID.description, body: "Hi",
                timestamp: Date(), isOutgoing: true,
                isDelivered: false, isEdited: false, type: "chat"
            )
            await transcripts.addMessage(message)

            let from = try #require(JID.parse("contact@example.com/res"))
            await service.handleEvent(
                .chatMarkerReceived(messageID: "outgoing-2", type: .displayed, from: from),
                accountID: testAccountID
            )

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].isDelivered == true)
            #expect(messages[0].isDisplayed == true)
        }

        @Test
        @MainActor
        func `Displayed chat marker covers the messages sent before it`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = UUID()
            // Oldest first: two sent, one received, one sent and named by the marker, one sent after it.
            let rows = [
                row("sent-1", in: conversationID, at: 0), row("sent-2", in: conversationID, at: 1),
                row("received-1", in: conversationID, at: 2, isOutgoing: false),
                row("sent-3", in: conversationID, at: 3), row("sent-4", in: conversationID, at: 4)
            ]
            await seedChat(rows, in: conversationID, store: store, transcripts: transcripts)

            try await deliverMarker("sent-3", to: service)

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            let displayed = Set(messages.filter(\.isDisplayed).compactMap(\.stanzaID))
            #expect(displayed == ["sent-1", "sent-2", "sent-3"])
        }

        @Test
        @MainActor
        func `Displayed chat marker leaves a failed message and a directly sent file as they are`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = UUID()
            let file = DuckoCore.Attachment.locallySaved(
                id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/notes.txt"), mimeType: "text/plain", fileSize: 3
            )
            let failed = row("failed-1", in: conversationID, at: 0, errorText: "Could not be delivered")
            let sentFile = row(nil, in: conversationID, at: 1, attachments: [file])
            let read = row("sent-1", in: conversationID, at: 2)
            await seedChat([failed, sentFile, read], in: conversationID, store: store, transcripts: transcripts)

            try await deliverMarker("sent-1", to: service)

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            // Armed: the marker was applied, so the rows below were within its reach.
            #expect(messages.first { $0.id == read.id }?.isDisplayed == true)
            for untouched in [failed, sentFile] {
                let message = try #require(messages.first { $0.id == untouched.id })
                #expect(!message.isDisplayed)
                #expect(!message.isDelivered)
            }
        }

        @Test
        @MainActor
        func `Displayed chat marker marks the sent message, not a received one with the same id`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = UUID()
            let sent = row("ducko-7", in: conversationID, at: 0)
            let received = row("ducko-7", in: conversationID, at: 1, isOutgoing: false)
            await seedChat([sent, received], in: conversationID, store: store, transcripts: transcripts)

            try await deliverMarker("ducko-7", to: service)

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages.first { $0.id == sent.id }?.isDisplayed == true)
            #expect(messages.first { $0.id == received.id }?.isDisplayed == false)
        }

        @Test
        @MainActor
        func `A repeated displayed marker records nothing more, and a later one adds only what is not read yet`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = UUID()
            let rows = (1 ... 4).map { row("sent-\($0)", in: conversationID, at: Double($0)) }
            await seedChat(rows, in: conversationID, store: store, transcripts: transcripts)

            try await deliverMarker("sent-3", to: service)
            #expect(await transcripts.amendments.count == 3)

            let revision = service.messagesRevisions[conversationID]
            try await deliverMarker("sent-3", to: service)
            #expect(await transcripts.amendments.count == 3)
            // Nothing was written, so nothing is reloaded either.
            #expect(service.messagesRevisions[conversationID] == revision)

            try await deliverMarker("sent-4", to: service)
            #expect(await transcripts.amendments.count == 4)
        }

        @Test
        @MainActor
        func `A displayed marker reaches a sent message that turned up behind one already read`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = UUID()
            await seedChat([row("sent-2", in: conversationID, at: 2)], in: conversationID, store: store, transcripts: transcripts)
            try await deliverMarker("sent-2", to: service)
            // What another of the user's devices sent earlier arrives from the archive only now.
            let archived = row("sent-1", in: conversationID, at: 1)
            await transcripts.addMessage(archived)
            await transcripts.addMessage(row("sent-3", in: conversationID, at: 3))

            try await deliverMarker("sent-3", to: service)

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages.first { $0.id == archived.id }?.isDisplayed == true)
            #expect(await transcripts.amendments.count == 3)
        }

        @Test
        @MainActor
        func `A displayed marker naming a message older than the lookback marks that message alone`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = UUID()
            let before = row("old-1", in: conversationID, at: 0)
            let named = row("old-2", in: conversationID, at: 1)
            let newer = (0 ..< 200).map { row("received-\($0)", in: conversationID, at: Double(2 + $0), isOutgoing: false) }
            await seedChat([before, named] + newer, in: conversationID, store: store, transcripts: transcripts)

            try await deliverMarker("old-2", to: service)

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 500)
            #expect(messages.first { $0.id == named.id }?.isDisplayed == true)
            #expect(messages.first { $0.id == before.id }?.isDisplayed == false)

            try await deliverMarker("old-2", to: service)
            #expect(await transcripts.amendments.count == 1)
        }

        @Test
        @MainActor
        func `A displayed marker another of the user's devices sent says nothing about the user's own messages`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = UUID()
            // The contact's message and one of the user's own carry the same stanza id.
            let sent = row("ducko-7", in: conversationID, at: 0)
            let received = row("ducko-7", in: conversationID, at: 1, isOutgoing: false)
            await seedChat([sent, received], in: conversationID, store: store, transcripts: transcripts)

            await service.handleEvent(
                sentCarbon(of: "displayed", namespace: XMPPNamespaces.chatMarkers, naming: "ducko-7"), accountID: testAccountID
            )
            #expect(await transcripts.amendments.isEmpty)

            // Control: the same marker, sent by the contact to another of the user's devices, does mark the sent message.
            try await service.handleEvent(
                receivedCarbon(of: "displayed", namespace: XMPPNamespaces.chatMarkers, naming: "ducko-7"), accountID: testAccountID
            )
            #expect(await transcripts.amendments.count == 1)
            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages.first { $0.id == sent.id }?.isDisplayed == true)
        }

        @Test
        @MainActor
        func `Displayed chat marker in a room counts as a delivery`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let roomJID = try #require(BareJID(localPart: "room", domainPart: "conference.example.com"))
            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: roomJID,
                type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            await transcripts.addMessage(ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "room-1",
                fromJID: roomJID.description, body: "Hi all",
                timestamp: Date(), isOutgoing: true,
                isDelivered: false, isEdited: false, type: "groupchat"
            ))

            let from = try #require(JID.parse("room@conference.example.com/occupant"))
            await service.handleEvent(
                .chatMarkerReceived(messageID: "room-1", type: .displayed, from: from),
                accountID: testAccountID
            )

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].isDelivered == true)
            #expect(messages[0].isDisplayed == false)
        }
    }

    struct Selection {
        @Test
        @MainActor
        func `A selection taken over while it loads marks nothing read`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: testAccountID, jid: contactJID,
                type: .chat, isPinned: false, isMuted: false, unreadCount: 2, createdAt: Date()
            ))
            await transcripts.addMessage(row("received-1", in: conversationID, at: 0, isOutgoing: false))
            let entered = AsyncSemaphore()
            let release = AsyncSemaphore()
            await transcripts.installFetchMessagesGate(entered: entered, release: release)

            let selecting = Task { @MainActor in
                await service.selectConversation(conversationID, accountID: testAccountID)
            }
            await entered.wait()
            // Armed: the selection is under way, held in its load.
            #expect(service.activeConversationID == conversationID)
            await service.selectConversation(nil)
            await release.signal()
            await selecting.value

            #expect(service.activeConversationID == nil)
            #expect(service.messages.isEmpty)
            #expect(try await store.fetchConversations(for: testAccountID).first?.unreadCount == 2)
        }
    }

    struct DeliveryReceiptDrop {
        @Test
        @MainActor
        func `Delivery receipt from unknown JID is dropped`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let from = try #require(JID.parse("unknown@example.com/res"))
            await service.handleEvent(
                .deliveryReceiptReceived(messageID: "msg-1", from: from),
                accountID: testAccountID
            )

            let amendments = await transcripts.amendments
            #expect(amendments.isEmpty)
            #expect(service.openConversations.isEmpty)
        }
    }

    struct ChatMarkerDrop {
        @Test
        @MainActor
        func `Chat marker from unknown JID is dropped`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let from = try #require(JID.parse("unknown@example.com/res"))
            await service.handleEvent(
                .chatMarkerReceived(messageID: "msg-1", type: .displayed, from: from),
                accountID: testAccountID
            )

            let amendments = await transcripts.amendments
            #expect(amendments.isEmpty)
            #expect(service.openConversations.isEmpty)
        }
    }
}
