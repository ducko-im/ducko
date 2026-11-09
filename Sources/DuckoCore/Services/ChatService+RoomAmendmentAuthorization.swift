import DuckoXMPP
import Foundation

/// Who may correct or retract a message in a room or a room's private chat (XEP-0308, XEP-0424): its author, told
/// apart by identity rather than by a nickname someone else can take.
extension ChatService {
    /// Whether the correction, or the retraction when `isRetraction`, that `sender` sent may change `original` in
    /// `conversation`, a room or a private chat with one of its occupants.
    func isAuthorizedRoomAmendment(
        of original: ChatMessage, by sender: AmendmentSender, isRetraction: Bool, in conversation: Conversation, accountID: UUID
    ) async -> Bool {
        original.isOutgoing
            ? await isOwnRoomAmendment(by: sender, isRetraction: isRetraction, in: conversation, accountID: accountID)
            : isOccupantAmendment(of: original, by: sender, isRetraction: isRetraction, room: conversation.jid, accountID: accountID)
    }

    /// Whether another occupant's amendment comes from who sent `original`: under its nickname, and by identity as
    /// `isSameRoomAuthor` compares it.
    private func isOccupantAmendment(of original: ChatMessage, by sender: AmendmentSender, isRetraction: Bool, room: BareJID, accountID: UUID) -> Bool {
        guard case let .full(occupant) = sender.from, occupant.bareJID == room, original.fromJID == occupant.resourcePart else { return false }
        return isSameRoomAuthor(sender.roomAuthor, as: original.roomSender, isRetraction: isRetraction, room: room, accountID: accountID)
    }

    /// Whether the user's own amendment comes from the user. A private chat's copy sent from the account is, since the
    /// server authenticates that address. Otherwise its author must be the user as `isSameRoomAuthor` compares it,
    /// against the user's occupant id, the account's real JID, and the user's current presence session in the room.
    private func isOwnRoomAmendment(by sender: AmendmentSender, isRetraction: Bool, in conversation: Conversation, accountID: UUID) async -> Bool {
        let accountJID = resolvedAccountJID(for: accountID)
        if conversation.type == .chat, sender.from.bareJID == accountJID { return true }
        guard let supportsOccupantIDs = sender.roomAuthor?.roomSupportsOccupantIDs else { return false }
        let room = conversation.jid
        let user = await RoomSenderIdentity(
            occupantID: supportsOccupantIDs ? ownOccupantID(inRoom: room, accountID: accountID) : nil,
            realJID: accountJID?.description,
            presenceSession: accountService?.roomModule(for: accountID)?.ownPresenceSession(in: room)
        )
        return isSameRoomAuthor(sender.roomAuthor, as: user, isRetraction: isRetraction, room: room, accountID: accountID)
    }

    /// Whether `author`, who sent an amendment in `room` or its private chat, is `expected`. Where the room advertises
    /// occupant ids, only the occupant id counts. Without them, a matching real JID counts, though a retraction trusts
    /// it only in a non-anonymous room. A correction also counts an unbroken presence in the room. Unknown support
    /// refuses.
    private func isSameRoomAuthor(
        _ author: RoomAuthorIdentity?, as expected: RoomSenderIdentity?, isRetraction: Bool, room: BareJID, accountID: UUID
    ) -> Bool {
        guard let author, let supportsOccupantIDs = author.roomSupportsOccupantIDs else { return false }
        if supportsOccupantIDs {
            return author.occupantID != nil && author.occupantID == expected?.occupantID
        }
        if let realJID = author.realJID, realJID.description == expected?.realJID,
           !isRetraction || roomAdvertises(XMPPNamespaces.mucNonAnonymous, room: room, accountID: accountID) {
            return true
        }
        return !isRetraction && author.presenceSession != nil && author.presenceSession == expected?.presenceSession
    }
}
