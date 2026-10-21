import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let contact = BareJID(localPart: "bob", domainPart: "example.com")!

/// Records whether each body it filters may fetch link previews.
private actor LinkPreviewFetchSpy: MessageFilter {
    nonisolated let priority = 0
    private(set) var allowed: [Bool] = []

    func filter(_ content: MessageContent, direction: FilterDirection, context: FilterContext) async -> MessageContent {
        allowed.append(context.allowLinkPreviewFetches)
        return content
    }
}

/// A decrypted message renders like a plaintext one, but its links are never fetched for a preview.
@MainActor
struct ChatServiceEncryptedFilterTests {
    private let store = MockPersistenceStore()
    private let transcripts = MockTranscriptStore()
    private let spy = LinkPreviewFetchSpy()
    /// Held here, since the chat service holds it weakly.
    private let accountService: AccountService
    private let chatService: ChatService
    private let accountID: UUID
    private let chat: Conversation

    init() async throws {
        let account = try Account(id: UUID(), jid: #require(BareJID.parse(testJIDString)), isEnabled: true, connectOnLaunch: false, createdAt: Date())
        await store.addAccount(account)
        self.chat = Conversation(
            id: UUID(), accountID: account.id, jid: contact, type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
        )
        await store.addConversation(chat)
        self.accountService = makeAccountService(store: store)
        try await accountService.loadAccounts()
        let pipeline = MessageFilterPipeline()
        await pipeline.register(StylingFilter())
        await pipeline.register(spy)
        self.chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: pipeline)
        chatService.setAccountService(accountService)
        self.accountID = account.id
    }

    @Test(arguments: [nil, true, false])
    func `a decrypted message or correction is styled without fetching its links`(correctedOriginalIsEncrypted: Bool?) async throws {
        var elements: [DuckoXMPP.XMLElement] = []
        let isCorrection = correctedOriginalIsEncrypted != nil
        if let correctedOriginalIsEncrypted {
            await transcripts.addMessage(ChatMessage(
                id: UUID(), conversationID: chat.id, stanzaID: "m1", fromJID: contact.description, body: "old", timestamp: Date(),
                isOutgoing: false, isDelivered: false, isEdited: false, type: "chat", isEncrypted: correctedOriginalIsEncrypted
            ))
            elements.append(DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": "m1"]))
        }
        let stanza = try makeEncryptedStanza(from: .full(#require(FullJID.parse("\(contact)/desktop"))), id: "m2")

        await chatService.receiveEncryptedMessage(
            stanza, content: EncryptedContent(encryptedOutcome(of: stanza, body: "*hi* https://example.com", elements: elements)),
            origin: .live, accountID: accountID
        )

        let stored = try #require(try await transcripts.fetchMessages(for: chat.id, before: nil, limit: 10).first)
        #expect(stored.isEdited == isCorrection)
        #expect(stored.htmlBody?.contains("<strong>hi</strong>") == true)
        #expect(await spy.allowed == [false])
    }
}
