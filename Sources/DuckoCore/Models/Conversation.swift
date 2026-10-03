import DuckoXMPP
import Foundation

public struct Conversation: Sendable, Identifiable {
    public var id: UUID
    public var accountID: UUID?
    public var importSourceJID: String?
    public var jid: BareJID
    public var type: ConversationType
    public var displayName: String?
    public var isPinned: Bool
    public var isMuted: Bool
    public var lastMessageDate: Date?
    public var lastMessagePreview: String?
    public var unreadCount: Int
    public var roomSubject: String?
    public var roomNickname: String?
    public var encryptionEnabled: Bool
    /// The user switched encryption off in this chat, so a contact's encrypted message does not switch it back on.
    public var encryptionOptedOut: Bool
    public var occupantNickname: String?
    public var lastReadTimestamp: Date?
    public var createdAt: Date

    public enum ConversationType: String, Sendable {
        case chat, groupchat
    }

    public init(
        id: UUID,
        accountID: UUID? = nil,
        importSourceJID: String? = nil,
        jid: BareJID,
        type: ConversationType,
        displayName: String? = nil,
        isPinned: Bool,
        isMuted: Bool,
        lastMessageDate: Date? = nil,
        lastMessagePreview: String? = nil,
        unreadCount: Int,
        roomSubject: String? = nil,
        roomNickname: String? = nil,
        encryptionEnabled: Bool = false,
        encryptionOptedOut: Bool = false,
        occupantNickname: String? = nil,
        lastReadTimestamp: Date? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.accountID = accountID
        self.importSourceJID = importSourceJID
        self.jid = jid
        self.type = type
        self.displayName = displayName
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.lastMessageDate = lastMessageDate
        self.lastMessagePreview = lastMessagePreview
        self.unreadCount = unreadCount
        self.roomSubject = roomSubject
        self.roomNickname = roomNickname
        self.encryptionEnabled = encryptionEnabled
        self.encryptionOptedOut = encryptionOptedOut
        self.occupantNickname = occupantNickname
        self.lastReadTimestamp = lastReadTimestamp
        self.createdAt = createdAt
    }

    /// A chat with one contact: not a room, and not a private chat with a room's occupant.
    public var isDirectChat: Bool {
        type == .chat && occupantNickname == nil
    }

    /// Non-empty title: the set name, else the JID's local part, else the full JID.
    public var displayTitle: String {
        displayName ?? jid.localPart ?? jid.description
    }
}
