import DuckoXMPP
import Foundation

extension ChatService {
    /// Applies the correction or retraction that `message`, sent at `sentTime`, carries in the chat with `peer`. For a
    /// carbon, `peer` is the recipient of a sent one and the sender of a received one; otherwise it is the sender.
    /// `message` is a plaintext carbon, or a decrypted message when `isDecrypted`, and only a decrypted amendment that
    /// applies also goes to `onDecryptedAmendment`. Returns whether `message` carried an amendment, so it is never
    /// stored as a message even when the amendment cannot be applied.
    func applyAmendment(carriedBy message: XMPPMessage, chatWith peer: JID, sentAt sentTime: Date, isDecrypted: Bool, accountID: UUID) async -> Bool {
        guard message.carriesAmendment else { return false }
        let messageType = message.messageType ?? .normal
        guard let conversation = await amendedConversation(chatWith: peer, messageType: messageType, accountID: accountID),
              let amendment = MessageAmendment(message, timestamp: sentTime, in: conversation),
              await apply(amendment, in: conversation, accountID: accountID, isDecrypted: isDecrypted) != nil
        else { return true }
        if isDecrypted {
            onDecryptedAmendment?(amendment.event(messageType: messageType), accountID)
        }
        return true
    }
}
