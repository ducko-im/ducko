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
            roomOccupantID: roomOccupantID,
            rejoinsOnConnect: rejoinsOnConnect,
            encryptionEnabled: encryptionEnabled,
            encryptionOptedOut: encryptionOptedOut,
            plaintextRequest: plaintextRequester.map {
                PlaintextRequest(requester: $0, reason: plaintextRequestReason, isConfirmed: plaintextRequestConfirmed)
            },
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
        roomOccupantID = conversation.roomOccupantID
        rejoinsOnConnect = conversation.rejoinsOnConnect
        encryptionEnabled = conversation.encryptionEnabled
        encryptionOptedOut = conversation.encryptionOptedOut
        plaintextRequester = conversation.plaintextRequest?.requester
        plaintextRequestReason = conversation.plaintextRequest?.reason
        plaintextRequestConfirmed = conversation.plaintextRequest?.isConfirmed ?? false
        occupantNickname = conversation.occupantNickname
        lastReadTimestamp = conversation.lastReadTimestamp
    }
}
