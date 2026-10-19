import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// An encrypted chat stanza from `from` with message id `id`, as `OMEMOModule` hands it on. `serverID` adds the
/// account archive's stamp.
func makeEncryptedStanza(from: JID, id: String?, serverID: String? = nil) -> XMPPMessage {
    var message = XMPPMessage(type: .chat, id: id)
    message.from = from
    message.element.addChild(DuckoXMPP.XMLElement(name: "encrypted", namespace: XMPPNamespaces.omemo))
    if let serverID {
        message.element.addChild(DuckoXMPP.XMLElement(
            name: "stanza-id", namespace: XMPPNamespaces.stanzaID, attributes: ["id": serverID, "by": testJIDString]
        ))
    }
    return message
}

private let peer = BareJID(localPart: "peer", domainPart: "example.com")!

/// A live encrypted message is stored once, whatever copies of it arrive, and a stored undecryptable copy takes its
/// text.
@MainActor
struct ChatServiceEncryptedIngestTests {
    private let store = MockPersistenceStore()
    private let transcripts = MockTranscriptStore()
    /// Held here, since the services hold it weakly.
    private let accountService: AccountService
    private let chatService: ChatService
    private let service: OMEMOService
    private let accountID: UUID
    private let conversation: Conversation
    private let notified = Counter()

    final class Counter {
        var calls = 0
        var lastMessage: ChatMessage?
    }

    init() async throws {
        let account = try Account(id: UUID(), jid: #require(BareJID.parse(testJIDString)), isEnabled: true, connectOnLaunch: false, createdAt: Date())
        await store.addAccount(account)
        let conversation = Conversation(
            id: UUID(), accountID: account.id, jid: peer, type: .chat,
            isPinned: false, isMuted: false, unreadCount: 0, encryptionEnabled: false, createdAt: Date()
        )
        await store.addConversation(conversation)
        self.accountService = makeAccountService(store: store)
        try await accountService.loadAccounts()
        self.chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
        chatService.setAccountService(accountService)
        self.service = OMEMOService(omemoStore: MockOMEMOStore())
        service.setAccountService(accountService)
        service.setChatService(chatService)
        let notified = notified
        chatService.onIncomingMessage = { message, _ in
            notified.calls += 1
            notified.lastMessage = message
        }
        self.accountID = account.id
        self.conversation = conversation
    }

    private func receive(_ stanza: XMPPMessage, body: String?) async {
        await service.handleEvent(.omemoEncryptedMessageReceived(message: stanza, decryptedBody: body, senderDeviceID: 1), accountID: accountID)
    }

    private func storedConversation() async throws -> Conversation {
        try #require(try await store.fetchConversations(for: accountID).first { $0.id == conversation.id })
    }

    private func undecryptablePlaceholder(stanzaID: String, serverID: String?) -> ChatMessage {
        ChatMessage(
            id: UUID(), conversationID: conversation.id, stanzaID: stanzaID, serverID: serverID, fromJID: peer.description,
            body: "", timestamp: Date(timeIntervalSince1970: 1_772_272_800), isOutgoing: false, isDelivered: false,
            isEdited: false, type: "chat", isEncrypted: true, isUndecryptable: true
        )
    }

    @Test func `A stanza delivered again is stored and announced once`() async throws {
        let stanza = try makeEncryptedStanza(from: .full(#require(FullJID.parse("peer@example.com/phone"))), id: "ducko-1")

        await receive(stanza, body: "hello")
        await receive(stanza, body: "hello")

        #expect(await transcripts.messages.map(\.body) == ["hello"])
        #expect(notified.calls == 1)
        #expect(try await storedConversation().unreadCount == 1)
    }

    @Test func `A copy that fails to decrypt after the message decrypted adds nothing`() async {
        let stanza = makeEncryptedStanza(from: .bare(peer), id: "ducko-1")

        await receive(stanza, body: "hello")
        await receive(stanza, body: nil)

        let messages = await transcripts.messages
        #expect(messages.count == 1)
        #expect(messages.first?.isUndecryptable == false)
        #expect(notified.calls == 1)
    }

    @Test func `The archive's undecryptable copy reads as the message once it decrypts live`() async throws {
        let placeholder = undecryptablePlaceholder(stanzaID: "ducko-2", serverID: "S1")
        await transcripts.addMessage(placeholder)

        await receive(makeEncryptedStanza(from: .bare(peer), id: "ducko-2", serverID: "S1"), body: "hello")

        let messages = try await transcripts.fetchMessages(for: conversation.id, before: nil, limit: 10)
        let message = try #require(messages.first)
        #expect(messages.count == 1)
        #expect(message.id == placeholder.id)
        #expect(message.body == "hello")
        #expect(!message.isUndecryptable)
        #expect(!message.isEdited)
        #expect(notified.calls == 1)
        let stored = try await storedConversation()
        #expect(stored.unreadCount == 1)
        #expect(stored.lastMessagePreview == "hello")
    }

    @Test func `A correction that reached the undecryptable copy first is what the decrypted message announces`() async throws {
        let placeholder = undecryptablePlaceholder(stanzaID: "ducko-2", serverID: "S1")
        await transcripts.addMessage(placeholder)
        try await transcripts.appendAmendment(
            TranscriptAmendment(action: .edit, targetMessageID: placeholder.id, body: "corrected"), conversationID: conversation.id
        )

        await receive(makeEncryptedStanza(from: .bare(peer), id: "ducko-2", serverID: "S1"), body: "hello")

        #expect(notified.lastMessage?.body == "corrected")
        #expect(notified.lastMessage?.isEdited == true)
        #expect(try await storedConversation().lastMessagePreview == "corrected")
    }

    @Test func `A live encrypted reply keeps the message it answers and the file sent with it`() async throws {
        var stanza = makeEncryptedStanza(from: .bare(peer), id: "ducko-6")
        stanza.element.addChild(DuckoXMPP.XMLElement(
            name: "reply", namespace: XMPPNamespaces.messageReply, attributes: ["to": peer.description, "id": "ducko-5"]
        ))
        var oob = DuckoXMPP.XMLElement(name: "x", namespace: XMPPNamespaces.oob)
        var url = DuckoXMPP.XMLElement(name: "url")
        url.addText("https://example.com/photo.jpg")
        oob.addChild(url)
        stanza.element.addChild(oob)

        await receive(stanza, body: "yes")

        let message = try #require(await transcripts.messages.first)
        #expect(message.replyToID == "ducko-5")
        #expect(message.attachments.map(\.url) == ["https://example.com/photo.jpg"])
    }

    @Test func `A room message sent from the user's other device is stored as sent`() async throws {
        let room = try #require(BareJID.parse("room@conference.example.com"))
        await store.addConversation(Conversation(
            id: UUID(), accountID: accountID, jid: room, type: .groupchat, isPinned: false, isMuted: false,
            unreadCount: 0, roomNickname: "me", encryptionEnabled: true, createdAt: Date()
        ))

        for nickname in ["me", "other"] {
            try await receive(makeEncryptedStanza(from: .full(#require(FullJID.parse("\(room)/\(nickname)"))), id: nickname), body: "hi")
        }

        #expect(await transcripts.messages.map(\.isOutgoing) == [true, false])
        // Read where the user wrote it, so only the other occupant's message is unread.
        let stored = try #require(try await store.fetchConversations(for: accountID).first { $0.jid == room })
        #expect(stored.unreadCount == 1)
    }

    @Test func `A new message reusing an older undecryptable one's id is not written onto it`() async throws {
        let older = undecryptablePlaceholder(stanzaID: "ducko-3", serverID: nil)
        await transcripts.addMessage(older)

        await receive(makeEncryptedStanza(from: .bare(peer), id: "ducko-3"), body: "new")

        let messages = try await transcripts.fetchMessages(for: conversation.id, before: nil, limit: 10)
        #expect(messages.map(\.id) == [older.id])
        #expect(messages.first?.isUndecryptable == true)
        #expect(notified.calls == 0)
    }

    @Test func `A message older than the conversation's last one leaves its preview and still counts as unread`() async throws {
        let later = Date().addingTimeInterval(3600)
        try await store.updateConversation(conversation.id) {
            $0.lastMessageDate = later
            $0.lastMessagePreview = "newer"
        }

        await receive(makeEncryptedStanza(from: .bare(peer), id: "ducko-4"), body: "older")

        let stored = try await storedConversation()
        #expect(stored.lastMessageDate == later)
        #expect(stored.lastMessagePreview == "newer")
        #expect(stored.unreadCount == 1)
    }
}
