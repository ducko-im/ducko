import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// Live messages are stored at the time a trusted delay names, and a room's join history arrives quietly at the time the
/// room stamped on it.
@MainActor
struct ChatServiceDelayTests {
    enum Origin: CaseIterable {
        case live, privateRoom, room, encrypted
    }

    private static let room = BareJID(localPart: "room", domainPart: "conference.example.com")!
    private static let sentTime = Date(timeIntervalSince1970: 1_772_359_200)
    private static let stamp = "2026-03-01T10:00:00Z"

    private let store = MockPersistenceStore()
    private let transcripts = MockTranscriptStore()
    /// Held here, since the chat service holds it weakly.
    private let accountService: AccountService
    private let chatService: ChatService
    private let accountID: UUID
    private let notified = Counter()

    final class Counter {
        var calls = 0
    }

    init() async throws {
        let account = try Account(id: UUID(), jid: #require(BareJID.parse(testJIDString)), isEnabled: true, connectOnLaunch: false, createdAt: Date())
        await store.addAccount(account)
        self.accountService = makeAccountService(store: store)
        try await accountService.loadAccounts()
        self.chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
        chatService.setAccountService(accountService)
        let notified = notified
        chatService.onIncomingMessage = { _, _ in notified.calls += 1 }
        self.accountID = account.id
    }

    private static func message(type: XMPPMessage.MessageType, from: JID, body: String, stampedBy stamper: String?) throws -> XMPPMessage {
        var message = try XMPPMessage(type: type, to: .bare(#require(BareJID.parse(testJIDString))), id: UUID().uuidString)
        message.from = from
        message.body = body
        if let stamper {
            message.element.addChild(DuckoXMPP.XMLElement(name: "delay", namespace: XMPPNamespaces.delay, attributes: ["from": stamper, "stamp": stamp]))
        }
        return message
    }

    private static func roomMessage(_ body: String, stampedBy stamper: String?) throws -> XMPPMessage {
        try message(type: .groupchat, from: .full(#require(FullJID(bareJID: room, resourcePart: "bob"))), body: body, stampedBy: stamper)
    }

    private func roomConversation() async throws -> Conversation {
        try #require(try await store.fetchConversations(for: accountID).first { $0.jid == Self.room && $0.type == .groupchat })
    }

    @Test(arguments: Origin.allCases)
    func `a delay stamped by the account's server is the message's time`(origin: Origin) async throws {
        let occupant = try #require(FullJID(bareJID: Self.room, resourcePart: "bob"))
        let contact = try #require(FullJID.parse("bob@example.org/phone"))

        switch origin {
        case .live:
            try await chatService.handleEvent(.messageReceived(Self.message(type: .chat, from: .full(contact), body: "offline", stampedBy: "example.com")), accountID: accountID)
        case .privateRoom:
            try await chatService.handleEvent(.mucPrivateMessageReceived(Self.message(type: .chat, from: .full(occupant), body: "offline", stampedBy: "example.com")), accountID: accountID)
        case .room:
            try await chatService.handleEvent(.roomMessageReceived(Self.roomMessage("offline", stampedBy: "example.com")), accountID: accountID)
        case .encrypted:
            var stanza = try Self.message(type: .chat, from: .full(contact), body: "", stampedBy: "example.com")
            stanza.body = nil
            await chatService.receiveEncryptedMessage(
                stanza, content: EncryptedContent(encryptedOutcome(of: stanza, body: "offline")), origin: .live, accountID: accountID
            )
        }

        let stored = try #require(await transcripts.messages.first)
        #expect(stored.timestamp == Self.sentTime)
        let conversation = try #require(try await store.fetchConversations(for: accountID).first)
        #expect(conversation.unreadCount == 1)
    }

    /// A room stamps only the history it replays, so another message stamped by it could claim any time.
    @Test(arguments: [false, true])
    func `a room's delay outside its join history neither dates the message nor keeps it quiet`(isEncrypted: Bool) async throws {
        try await store.upsertConversation(Conversation(
            id: UUID(), accountID: accountID, jid: Self.room, type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0,
            roomNickname: "me", createdAt: Date()
        ))
        let receivedAfter = Date()
        var stanza = try Self.roomMessage("late", stampedBy: Self.room.description)

        if isEncrypted {
            stanza.body = nil
            await chatService.receiveEncryptedMessage(
                stanza, content: EncryptedContent(encryptedOutcome(of: stanza, body: "late")), origin: .live, accountID: accountID
            )
        } else {
            await chatService.handleEvent(.roomMessageReceived(stanza), accountID: accountID)
        }

        let stored = try #require(await transcripts.messages.first)
        #expect(stored.timestamp >= receivedAfter)
        #expect(try await roomConversation().unreadCount == 1)
        #expect(notified.calls == 1)
    }

    @Test func `join history is stored at its sent time without counting as unread or drawing attention, until the subject`() async throws {
        let occupancy = RoomOccupancy(nickname: "me", occupants: [], subject: nil)
        await chatService.handleEvent(.roomJoined(room: Self.room, occupancy: occupancy, isNewlyCreated: false), accountID: accountID)

        try await chatService.handleEvent(.roomMessageReceived(Self.roomMessage("history", stampedBy: Self.room.description)), accountID: accountID)

        let history = try #require(await transcripts.messages.first)
        #expect(history.timestamp == Self.sentTime)
        #expect(try await roomConversation().unreadCount == 0)
        #expect(notified.calls == 0)

        // The subject ends the history, so a message the room stamps after it is new to the user.
        await chatService.handleEvent(.roomSubjectChanged(room: Self.room, subject: "topic", setter: nil), accountID: accountID)
        try await chatService.handleEvent(.roomMessageReceived(Self.roomMessage("late", stampedBy: Self.room.description)), accountID: accountID)

        #expect(try await roomConversation().unreadCount == 1)
        #expect(notified.calls == 1)
    }
}
