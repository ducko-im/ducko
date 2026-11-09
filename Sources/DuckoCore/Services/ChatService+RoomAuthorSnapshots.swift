import DuckoXMPP
import Foundation

/// Who sent the copies of room and room private messages that carbons (XEP-0280) and archives (XEP-0313) forward.
extension ChatService {
    /// Who sent `message`, a forwarded copy of a message in a room or in a private chat with one of its occupants, where
    /// `roomSupportsOccupantIDs` tells whether the room's features list occupant ids. A copy shows no presence session.
    /// One sent from the account names the account as its real JID, since the server authenticates that address and the
    /// copy never passed through the room. One the room relayed keeps its occupant id where the room lists them and,
    /// when `isFromRoomArchive`, the real JID the room's archive shows.
    func forwardedRoomAuthor(
        of message: XMPPMessage, roomSupportsOccupantIDs: Bool?, isFromRoomArchive: Bool = false, accountID: UUID
    ) -> RoomAuthorIdentity {
        if let accountJID = resolvedAccountJID(for: accountID), message.from?.bareJID == accountJID {
            return RoomAuthorIdentity(roomSupportsOccupantIDs: roomSupportsOccupantIDs, realJID: accountJID)
        }
        return RoomAuthorIdentity(
            roomSupportsOccupantIDs: roomSupportsOccupantIDs,
            occupantID: roomSupportsOccupantIDs == true ? message.occupantID : nil,
            realJID: isFromRoomArchive ? message.mucUserItemJID : nil
        )
    }

    /// Who sent `message`, which a carbon forwarded in the chat with `peer`, by the room's features known now, when `peer`
    /// is a room's occupant. Nil when `peer` is a bare JID. A contact's full JID gets one too, which its 1:1 chat ignores.
    func carbonRoomAuthor(of message: XMPPMessage, chatWith peer: JID, accountID: UUID) -> RoomAuthorIdentity? {
        guard case .full = peer else { return nil }
        let supportsOccupantIDs = featureSource.knownRoomInfo(peer.bareJID, accountID: accountID)?.supportsOccupantIDs
        return forwardedRoomAuthor(of: message, roomSupportsOccupantIDs: supportsOccupantIDs, accountID: accountID)
    }

    /// Who sent `message`, an entry of the archive read for `conversation`: the room's own archive, or the account's for
    /// a room's private chat. `roomSupportsOccupantIDs` is what the room's features, read for this archive read, tell.
    /// Nil in a 1:1 chat.
    func archivedRoomAuthor(
        of message: XMPPMessage, in conversation: Conversation, roomSupportsOccupantIDs: Bool?, accountID: UUID
    ) -> RoomAuthorIdentity? {
        switch conversation.type {
        case .groupchat:
            forwardedRoomAuthor(of: message, roomSupportsOccupantIDs: roomSupportsOccupantIDs, isFromRoomArchive: true, accountID: accountID)
        case .chat:
            conversation.occupantNickname == nil
                ? nil
                : forwardedRoomAuthor(of: message, roomSupportsOccupantIDs: roomSupportsOccupantIDs, accountID: accountID)
        }
    }
}

private extension XMPPMessage {
    /// The real JID a room's `<x xmlns='http://jabber.org/protocol/muc#user'><item jid/>` names.
    var mucUserItemJID: BareJID? {
        element.child(named: "x", namespace: XMPPNamespaces.mucUser)?.child(named: "item")?.attribute("jid").flatMap { JID.parse($0)?.bareJID }
    }
}
