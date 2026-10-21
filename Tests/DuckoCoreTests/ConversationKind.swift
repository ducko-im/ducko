import DuckoCore
import DuckoXMPP
import Foundation

/// The three kinds of conversation a message is sent in, for tests that hold for each: the 1:1 chat with
/// `contact@example.com`, the room `room@conference.example.com`, and the private chat with its occupant `bob`.
enum ConversationKind: CaseIterable, Sendable {
    case contact
    case room
    case privateChat

    static let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!
    static let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

    /// The address messages in the conversation are sent to.
    var recipient: String {
        switch self {
        case .contact: Self.contactJID.description
        case .room: Self.roomJID.description
        case .privateChat: "\(Self.roomJID)/bob"
        }
    }

    var messageType: String {
        switch self {
        case .contact, .privateChat: "chat"
        case .room: "groupchat"
        }
    }

    func conversation(accountID: UUID, encryptionEnabled: Bool = false) -> Conversation {
        switch self {
        case .contact:
            Conversation(
                id: UUID(), accountID: accountID, jid: Self.contactJID, type: .chat, isPinned: false, isMuted: false, unreadCount: 0,
                encryptionEnabled: encryptionEnabled, createdAt: Date()
            )
        case .room:
            Conversation(
                id: UUID(), accountID: accountID, jid: Self.roomJID, type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0,
                roomNickname: "me", encryptionEnabled: encryptionEnabled, createdAt: Date()
            )
        case .privateChat:
            Conversation(
                id: UUID(), accountID: accountID, jid: Self.roomJID, type: .chat, displayName: "bob", isPinned: false, isMuted: false,
                unreadCount: 0, encryptionEnabled: encryptionEnabled, occupantNickname: "bob", createdAt: Date()
            )
        }
    }

    /// A message in `conversation`, stored as this kind of conversation stores it, with `stanzaID` and the stanza-id
    /// `serverID`, which in a room is the one the room assigned to it.
    func message(
        in conversation: Conversation, stanzaID: String?, serverID: String? = nil, body: String, isOutgoing: Bool,
        isEncrypted: Bool = false
    ) -> ChatMessage {
        let sender = switch self {
        case .contact: Self.contactJID.description
        case .room: isOutgoing ? Self.roomJID.description : "bob"
        case .privateChat: "bob"
        }
        return ChatMessage(
            id: UUID(), conversationID: conversation.id, stanzaID: stanzaID, serverID: serverID, fromJID: sender, body: body,
            timestamp: Date(), isOutgoing: isOutgoing, isDelivered: false, isEdited: false, type: messageType, isEncrypted: isEncrypted
        )
    }
}
