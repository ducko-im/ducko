import DuckoXMPP
import Foundation

/// Replies (XEP-0461). A reply's body starts with a quote of the message it answers, which is stored with the reply
/// and marked by its fallback range, so the quote can be hidden wherever the quoted message is shown instead.
extension ChatService {
    /// The reference to `quoted`, written by `author`, with the quote of it a reply's body starts with. A quote of a
    /// reply leaves out the quote that reply carries. A reply sent `inPlaintext` does not quote an encrypted message,
    /// whose text the quote would put in the clear; the quote is optional (§5).
    func messageReply(quoting quoted: ChatMessage, by author: JID, inPlaintext: Bool) throws -> MessageReply {
        guard let reference = quoted.replyReference else {
            throw quoted.type == "groupchat" ? ChatServiceError.unconfirmedRoomMessage : ChatServiceError.unidentifiedMessage
        }
        let reply = MessageReply(to: reference, by: author, quoting: quoted.hidingReplyFallback().previewText)
        return inPlaintext && quoted.isEncrypted ? reply.withoutQuote : reply
    }

    /// The author of `quoted`, a message in the 1:1 chat with `contact`.
    func contactAuthor(of quoted: ChatMessage, with contact: BareJID, accountID: UUID) throws -> JID {
        guard quoted.isOutgoing else { return .bare(contact) }
        guard let accountJID = resolvedAccountJID(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        return .bare(accountJID)
    }

    /// The author of `quoted`, a message in `room` or in a private chat in it, by their address in the room.
    func roomAuthor(of quoted: ChatMessage, in room: BareJID, accountID: UUID) async -> JID {
        // An outgoing room message stores the room, and one in a private chat the occupant written to.
        let nickname = if quoted.isOutgoing {
            await ownNickname(inRoom: room, accountID: accountID)
        } else {
            quoted.fromJID
        }
        return nickname.flatMap { FullJID(bareJID: room, resourcePart: $0) }.map(JID.full) ?? .bare(room)
    }
}
