import DuckoCore
import DuckoXMPP
import Foundation

extension ConversationRecord {
    func toDomain() -> Conversation? {
        guard let bareJID = BareJID.parse(jid) else { return nil }
        return Conversation(
            id: id,
            accountID: account?.id,
            importSourceJID: importSourceJID,
            jid: bareJID,
            type: Conversation.ConversationType(rawValue: type) ?? .chat,
            displayName: displayName,
            isPinned: isPinned,
            isMuted: isMuted,
            lastMessageDate: lastMessageDate,
            lastMessagePreview: lastMessagePreview,
            unreadCount: unreadCount,
            roomSubject: roomSubject,
            roomNickname: roomNickname,
            rejoinsOnConnect: rejoinsOnConnect,
            encryptionEnabled: encryptionEnabled,
            encryptionOptedOut: encryptionOptedOut,
            occupantNickname: occupantNickname,
            lastReadTimestamp: lastReadTimestamp,
            createdAt: createdAt
        )
    }

    func update(from conversation: Conversation) {
        jid = conversation.jid.description
        type = conversation.type.rawValue
        importSourceJID = conversation.importSourceJID
        displayName = conversation.displayName
        isPinned = conversation.isPinned
        isMuted = conversation.isMuted
        lastMessageDate = conversation.lastMessageDate
        lastMessagePreview = conversation.lastMessagePreview
        unreadCount = conversation.unreadCount
        roomSubject = conversation.roomSubject
        roomNickname = conversation.roomNickname
        rejoinsOnConnect = conversation.rejoinsOnConnect
        encryptionEnabled = conversation.encryptionEnabled
        encryptionOptedOut = conversation.encryptionOptedOut
        occupantNickname = conversation.occupantNickname
        lastReadTimestamp = conversation.lastReadTimestamp
    }
}
