import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!
private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!
private let smiley = "\u{1F60A}"

/// A connected `ChatService` whose filter pipeline holds `filters`, so what its sends put on `transport` and in the
/// transcript can be read back.
@MainActor
struct FilterHarness {
    let store: MockPersistenceStore
    let transcripts: MockTranscriptStore
    let transport: MockTransport
    let accountService: AccountService
    let chatService: ChatService
    let accountID: UUID
}

@MainActor
func makeFilterHarness(
    modules: [any XMPPModule], filters: [any MessageFilter]
) async throws -> FilterHarness {
    let store = MockPersistenceStore()
    let transcripts = MockTranscriptStore()
    let transport = MockTransport()
    let factory = MockXMPPClientFactory(transport: transport, modules: modules)
    let accountService = makeAccountService(store: store, clientFactory: factory)
    let pipeline = MessageFilterPipeline()
    for filter in filters {
        await pipeline.register(filter)
    }
    let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: pipeline)
    chatService.setAccountService(accountService)

    let connectTask = Task { @MainActor in
        try await accountService.createAndConnect(
            jidString: testJIDString, password: "secret", host: "example.com", port: 5222
        )
    }
    await simulateNoTLSConnect(transport)
    let accountID = try await connectTask.value

    return FilterHarness(
        store: store, transcripts: transcripts, transport: transport,
        accountService: accountService, chatService: chatService, accountID: accountID
    )
}

@MainActor
func seedPlaintextRoom(_ harness: FilterHarness) async throws -> Conversation {
    let conversation = Conversation(
        id: UUID(), accountID: harness.accountID, jid: roomJID, type: .groupchat,
        isPinned: false, isMuted: false, unreadCount: 0,
        roomNickname: "alice", encryptionEnabled: false, createdAt: Date()
    )
    try await harness.store.upsertConversation(conversation)
    return conversation
}

@MainActor
func seedPlaintextChat(_ harness: FilterHarness) async throws -> Conversation {
    let conversation = Conversation(
        id: UUID(), accountID: harness.accountID, jid: contactJID, type: .chat,
        isPinned: false, isMuted: false, unreadCount: 0,
        encryptionEnabled: false, createdAt: Date()
    )
    try await harness.store.upsertConversation(conversation)
    return conversation
}

// MARK: - Tests

enum ChatServiceFilterTests {
    struct GroupSend {
        @Test
        @MainActor
        func `sendGroupMessage runs the body through the pipeline: persists and sends the transformed body`() async throws {
            let harness = try await makeFilterHarness(modules: [MUCModule()], filters: [EmojiFilter()])
            let conversation = try await seedPlaintextRoom(harness)
            await harness.chatService.selectConversation(conversation.id, accountID: harness.accountID)

            try await harness.chatService.sendGroupMessage(to: roomJID, body: "hi :)", accountID: harness.accountID)

            let persisted = try #require(await harness.transcripts.messages.first)
            #expect(persisted.body == "hi \(smiley)")

            let sentStrings = await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(sentStrings.contains { $0.contains("<body>hi \(smiley)</body>") })
            #expect(!sentStrings.contains { $0.contains(":)") })

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct GroupCorrection {
        @Test
        @MainActor
        func `sendGroupCorrection runs the edited body through the pipeline, writing transformed body and htmlBody`() async throws {
            let harness = try await makeFilterHarness(modules: [MUCModule()], filters: [StylingFilter(), EmojiFilter()])
            let conversation = try await seedPlaintextRoom(harness)
            let original = ChatMessage(
                id: UUID(), conversationID: conversation.id, stanzaID: "orig-1",
                fromJID: roomJID.description, body: "old", timestamp: Date(),
                isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat"
            )
            await harness.transcripts.addMessage(original)

            try await harness.chatService.sendCorrection(of: original, newBody: "*hi* :)", in: conversation, accountID: harness.accountID)

            let amendment = try #require(await harness.transcripts.amendments.last)
            #expect(amendment.amendment.action == .edit)
            #expect(amendment.amendment.body == "*hi* \(smiley)")
            let html = try #require(amendment.amendment.htmlBody)
            #expect(html.contains("<strong>hi</strong>"))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct OneToOneCorrection {
        @Test
        @MainActor
        func `sendCorrection runs the edited body through the pipeline, writing transformed body and htmlBody`() async throws {
            let harness = try await makeFilterHarness(modules: [ChatModule()], filters: [StylingFilter(), EmojiFilter()])
            let conversation = try await seedPlaintextChat(harness)
            let original = ChatMessage(
                id: UUID(), conversationID: conversation.id, stanzaID: "orig-1",
                fromJID: contactJID.description, body: "old", timestamp: Date(),
                isOutgoing: true, isDelivered: false, isEdited: false, type: "chat"
            )
            await harness.transcripts.addMessage(original)

            try await harness.chatService.sendCorrection(of: original, newBody: "*hi* :)", in: conversation, accountID: harness.accountID)

            let amendment = try #require(await harness.transcripts.amendments.last)
            #expect(amendment.amendment.action == .edit)
            #expect(amendment.amendment.body == "*hi* \(smiley)")
            let html = try #require(amendment.amendment.htmlBody)
            #expect(html.contains("<strong>hi</strong>"))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct OwnMUCEcho {
        @Test
        @MainActor
        func `the room's echo of our own correction is filtered, so its amendment keeps htmlBody`() async throws {
            let harness = try await makeFilterHarness(modules: [MUCModule()], filters: [StylingFilter(), EmojiFilter()])
            // The room's stored nickname "alice" tells `isOwnMessage` the echo is our own.
            let conversation = try await seedPlaintextRoom(harness)

            let original = ChatMessage(
                id: UUID(), conversationID: conversation.id, stanzaID: "orig-1",
                fromJID: roomJID.description, body: "old", timestamp: Date(),
                isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat"
            )
            await harness.transcripts.addMessage(original)

            try await harness.chatService.sendCorrection(of: original, newBody: "*hi* :)", in: conversation, accountID: harness.accountID)
            // The room echoes back the body we sent (already emoji-transformed on the wire).
            let echoFrom = try #require(JID.parse("\(roomJID.description)/alice"))
            await harness.chatService.handleEvent(
                .messageCorrected(originalID: "orig-1", newBody: "*hi* \(smiley)", replyFallbackRange: nil, from: echoFrom, messageType: .groupchat),
                accountID: harness.accountID
            )

            let amendments = await harness.transcripts.amendments.filter { $0.amendment.targetStanzaID == "orig-1" }
            #expect(amendments.count == 2)
            let echoAmendment = try #require(amendments.last)
            #expect(echoAmendment.amendment.body == "*hi* \(smiley)")
            let html = try #require(echoAmendment.amendment.htmlBody)
            #expect(html.contains("<strong>hi</strong>"))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct IncomingPeerCorrection {
        @Test
        @MainActor
        func `a peer's correction is filtered, so its amendment carries htmlBody`() async throws {
            let harness = try await makeFilterHarness(modules: [], filters: [StylingFilter()])
            let conversation = try await seedPlaintextRoom(harness)
            let original = ChatMessage(
                id: UUID(), conversationID: conversation.id, stanzaID: "peer-1",
                fromJID: "bob", body: "old", timestamp: Date(),
                isOutgoing: false, isDelivered: false, isEdited: false, type: "groupchat"
            )
            await harness.transcripts.addMessage(original)

            let peerFrom = try #require(JID.parse("\(roomJID.description)/bob"))
            await harness.chatService.handleEvent(
                .messageCorrected(originalID: "peer-1", newBody: "*hi*", replyFallbackRange: nil, from: peerFrom, messageType: .groupchat),
                accountID: harness.accountID
            )

            let amendment = try #require(await harness.transcripts.amendments.last)
            #expect(amendment.amendment.action == .edit)
            #expect(amendment.amendment.body == "*hi*")
            let html = try #require(amendment.amendment.htmlBody)
            #expect(html.contains("<strong>hi</strong>"))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct SentReplyCarbon {
        @Test
        @MainActor
        func `a sent carbon of a reply keeps the emoticon in its quote, so the quote's range still fits its body`() async throws {
            let harness = try await makeFilterHarness(modules: [], filters: [StylingFilter(), EmojiFilter()])
            _ = try await seedPlaintextChat(harness)
            let reply = MessageReply(to: "c1", by: .bare(contactJID), quoting: ":) earlier")
            var stanza = XMPPMessage(type: .chat, to: .bare(contactJID), id: "sent-1")
            stanza.from = JID.parse("\(testJIDString)/phone")
            stanza.body = reply.body(replying: "ok :)")
            for element in reply.elements {
                stanza.element.addChild(element)
            }

            await harness.chatService.handleEvent(
                .messageCarbonSent(ForwardedMessage(message: stanza, timestamp: nil)), accountID: harness.accountID
            )

            let stored = try #require(await harness.transcripts.messages.first)
            #expect(stored.body == "> :) earlier\nok :)")
            #expect(stored.replyFallbackRange == 0 ..< 13)
            // The display-only HTML covers only the reply's own text, which has no styling.
            #expect(stored.htmlBody == nil)
            #expect(stored.hidingReplyFallback().body == "ok :)")

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }
}
