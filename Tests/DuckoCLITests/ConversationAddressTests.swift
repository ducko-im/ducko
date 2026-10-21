import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

/// The conversation an address typed in the REPL names, which `/edit`, `/retract` and `/reply` act in.
struct ConversationAddressTests {
    private let accountID = UUID()
    private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!
    private let contactJID = BareJID(localPart: "alice", domainPart: "example.com")!

    private func makeConversation(_ jid: BareJID, type: Conversation.ConversationType, occupantNickname: String? = nil, accountID: UUID? = nil) -> Conversation {
        Conversation(
            id: UUID(), accountID: accountID ?? self.accountID, jid: jid, type: type, isPinned: false, isMuted: false, unreadCount: 0,
            occupantNickname: occupantNickname, createdAt: Date()
        )
    }

    @Test func `an occupant's address names the private chat with them, a room's bare address the room`() throws {
        let room = makeConversation(roomJID, type: .groupchat)
        let withBob = makeConversation(roomJID, type: .chat, occupantNickname: "bob")
        let withCarol = makeConversation(roomJID, type: .chat, occupantNickname: "carol")
        let conversations = [room, withBob, withCarol]

        #expect(try conversation(with: #require(JID.parse("\(roomJID)/carol")), among: conversations, accountID: accountID)?.id == withCarol.id)
        #expect(try conversation(with: #require(JID.parse("\(roomJID)")), among: conversations, accountID: accountID)?.id == room.id)
    }

    /// A contact's full address names no private chat, so `/edit alice@example.com/laptop` acts nowhere.
    @Test func `a contact's full address names no conversation`() throws {
        let chat = makeConversation(contactJID, type: .chat)

        #expect(try conversation(with: #require(JID.parse("\(contactJID)/laptop")), among: [chat], accountID: accountID) == nil)
        #expect(try conversation(with: #require(JID.parse("\(contactJID)")), among: [chat], accountID: accountID)?.id == chat.id)
    }

    @Test func `another account's conversation with the address is not named`() throws {
        let chat = makeConversation(contactJID, type: .chat, accountID: UUID())

        #expect(try conversation(with: #require(JID.parse("\(contactJID)")), among: [chat], accountID: accountID) == nil)
    }
}
