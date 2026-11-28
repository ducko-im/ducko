import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let contact = BareJID(localPart: "bob", domainPart: "example.com")!
private let secret = String(repeating: "0123456789abcdef", count: 5) + "01234567"
private let link = "aesgcm://upload.example.com/files/photo.png#\(secret)"
/// `link` as it is stored wherever it stays text.
private let hiddenLink = "aesgcm://upload.example.com/files/photo.png#…"

/// A file shared in an encrypted message as an `aesgcm://` link (XEP-0454) becomes the message's attachment, and the
/// key of a link that stays text is never stored or reported.
@MainActor
struct ChatServiceEncryptedFileTests {
    private let store = MockPersistenceStore()
    private let transcripts = MockTranscriptStore()
    /// Held here, since the services hold it weakly.
    private let accountService: AccountService
    private let chatService: ChatService
    private let omemoService: OMEMOService
    private let accountID: UUID
    private let chat: Conversation

    init() async throws {
        let account = try Account(id: UUID(), jid: #require(BareJID.parse(testJIDString)), isEnabled: true, connectOnLaunch: false, createdAt: Date())
        await store.addAccount(account)
        self.chat = Conversation(
            id: UUID(), accountID: account.id, jid: contact, type: .chat, isPinned: false, isMuted: false, unreadCount: 0,
            encryptionEnabled: true, createdAt: Date()
        )
        await store.addConversation(chat)
        self.accountService = makeAccountService(store: store)
        try await accountService.loadAccounts()
        self.chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
        chatService.setAccountService(accountService)
        self.omemoService = OMEMOService(omemoStore: MockOMEMOStore())
        omemoService.setAccountService(accountService)
        omemoService.setChatService(chatService)
        chatService.setOMEMOService(omemoService)
        self.accountID = account.id
    }

    /// Files a live message from the contact that decrypted to `body` and `elements`, and returns what was stored.
    private func receive(_ body: String, elements: [DuckoXMPP.XMLElement] = []) async throws -> ChatMessage {
        let stanza = try makeEncryptedStanza(from: #require(JID.parse("\(contact)/phone")), id: "m-\(UUID().uuidString)")
        await chatService.receiveEncryptedMessage(
            stanza, content: EncryptedContent(encryptedOutcome(of: stanza, body: body, elements: elements)), origin: .live, accountID: accountID
        )
        return try #require(try await transcripts.fetchMessages(for: chat.id, before: nil, limit: 50).first)
    }

    @Test(arguments: [link, "\(link)\ndata:image/jpeg,/9j/4AAQSkZJRg"])
    func `a body sharing an encrypted file is stored as the file, with no text`(body: String) async throws {
        let message = try await receive(body)

        let attachment = try #require(message.attachments.first)
        #expect(message.attachments.count == 1)
        #expect(attachment.url == link)
        #expect(attachment.mimeType == "image/png")
        #expect(message.body.isEmpty)
        #expect(message.htmlBody == nil)
        #expect(message.replyFallbackRange == nil)
        #expect(message.previewText == "photo.png")
        #expect(message.matchesSearch("photo"))
        #expect(!message.matchesSearch(secret))
    }

    /// A sender may also attach the shared file's link out of band. That copy is the same file, so it adds no second
    /// attachment, while an attachment of another link stays.
    @Test func `an out-of-band copy of the shared file's link adds no second attachment`() async throws {
        let other = "https://example.com/notes.txt"
        let attachments = [link, other].map { url in
            var oob = DuckoXMPP.XMLElement(name: "x", namespace: XMPPNamespaces.oob)
            oob.setChildText(named: "url", to: url)
            return oob
        }

        let message = try await receive(link, elements: attachments)

        #expect(message.attachments.map(\.url) == [link, other])
        #expect(message.body.isEmpty)
    }

    @Test func `a link that is not a shared file stays text without its key`() async throws {
        let message = try await receive("Have a look: \(link)")

        #expect(message.body == "Have a look: \(hiddenLink)")
        #expect(message.attachments.isEmpty)
        #expect(!message.previewText.contains(secret))
    }

    @Test func `a reply quoting a key-bearing link shows only the reply's own text`() async throws {
        let quote = "> \(link)\n"
        let reply = DuckoXMPP.XMLElement(name: "reply", namespace: XMPPNamespaces.messageReply, attributes: ["to": "\(contact)/phone", "id": "q1"])
        var fallback = DuckoXMPP.XMLElement(name: "fallback", namespace: XMPPNamespaces.fallbackIndication, attributes: ["for": XMPPNamespaces.messageReply])
        fallback.addChild(DuckoXMPP.XMLElement(name: "body", attributes: ["start": "0", "end": "\(quote.unicodeScalars.count)"]))

        let message = try await receive(quote + "Nice photo!", elements: [reply, fallback])

        #expect(message.body == "> \(hiddenLink)\nNice photo!")
        #expect(message.hidingReplyFallback().body == "Nice photo!")
    }

    @Test func `a decrypted correction is stored and reported without the key of a link it carries`() async throws {
        await transcripts.addMessage(ChatMessage(
            id: UUID(), conversationID: chat.id, stanzaID: "m1", fromJID: contact.description, body: "helo", timestamp: Date(),
            isOutgoing: false, isDelivered: false, isEdited: false, type: "chat", isEncrypted: true
        ))
        var reported: [XMPPEvent] = []
        chatService.onDecryptedAmendment = { event, _ in reported.append(event) }
        let replace = DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": "m1"])

        let corrected = try await receive(link, elements: [replace])

        #expect(corrected.body == hiddenLink)
        #expect(corrected.attachments.isEmpty)
        guard case let .messageCorrected(_, newBody, _, _, _, _)? = reported.first else {
            Issue.record("Reported \(reported)")
            return
        }
        #expect(newBody == hiddenLink)
    }
}
