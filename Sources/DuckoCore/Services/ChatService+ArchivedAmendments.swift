import DuckoXMPP
import Foundation

/// A correction or retraction a message carries, found in an archive or in a carbon or decrypted message. It is applied
/// to the message it names, with the rules a live one follows, and never stored as a message of its own.
struct MessageAmendment {
    enum Change {
        case correction(newBody: String, replyFallbackRange: Range<Int>?)
        case retraction
        /// A room's moderation, which names the message by the stanza-id the room assigned to it (XEP-0425).
        case moderation
    }

    let originalID: String
    let change: Change
    let from: JID
    /// When it was made, which orders it among the corrections of one message: when the archive received it, or when
    /// a carried one was sent.
    let timestamp: Date

    /// Whether an archived `message` carries a correction or retraction, so it is not stored as a message even when it
    /// cannot be applied. An encrypted message carries them inside its encryption.
    static func isCarried(by message: XMPPMessage) -> Bool {
        !message.isEncrypted && message.carriesAmendment
    }

    /// The amendment `message`, made at `timestamp`, makes in `conversation`. Nil when it names no message, and for a
    /// moderation that does not come from the room itself.
    init?(_ message: XMPPMessage, timestamp: Date, in conversation: Conversation) {
        guard let from = message.from else { return nil }
        if let retract = message.element.child(named: "retract", namespace: XMPPNamespaces.messageRetract) {
            guard let originalID = retract.attribute("id") else { return nil }
            if retract.child(named: "moderated", namespace: XMPPNamespaces.messageModerate) != nil {
                guard conversation.type == .groupchat, from == .bare(conversation.jid) else { return nil }
                self.change = .moderation
            } else {
                self.change = .retraction
            }
            self.originalID = originalID
        } else if let replace = message.element.child(named: "replace", namespace: XMPPNamespaces.messageCorrect),
                  let originalID = replace.attribute("id"), let newBody = message.body {
            self.change = .correction(newBody: newBody, replyFallbackRange: message.replyFallbackRange(in: newBody))
            self.originalID = originalID
        } else {
            return nil
        }
        self.from = from
        self.timestamp = timestamp
    }

    /// The event a live amendment of `messageType` comes in, for consumers that show those.
    func event(messageType: XMPPMessage.MessageType) -> XMPPEvent {
        switch change {
        case let .correction(newBody, replyFallbackRange):
            .messageCorrected(originalID: originalID, newBody: newBody, replyFallbackRange: replyFallbackRange, from: from, messageType: messageType)
        case .retraction:
            .messageRetracted(originalID: originalID, from: from, messageType: messageType)
        case .moderation:
            .messageModerated(originalID: originalID, moderator: from.description, room: from.bareJID, reason: nil)
        }
    }
}

extension ChatService {
    /// Applies `amendments` in `conversation` oldest first, so the newest correction of a message is the text it keeps.
    /// Returns the ones not applied, such as those whose message is not stored yet, and the ids of the messages the
    /// others changed.
    @discardableResult
    func applyArchivedAmendments(
        _ amendments: [MessageAmendment], in conversation: Conversation, accountID: UUID
    ) async -> (unapplied: [MessageAmendment], amendedIDs: Set<UUID>) {
        var unapplied: [MessageAmendment] = []
        var amendedIDs: Set<UUID> = []
        for amendment in amendments.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let amendedID = await apply(amendment, in: conversation, accountID: accountID, isDecrypted: false) {
                amendedIDs.insert(amendedID)
            } else {
                unapplied.append(amendment)
            }
        }
        return (unapplied, amendedIDs)
    }

    /// Applies `amendment` in `conversation`, and returns the id of the message it changed. `isDecrypted` tells that it
    /// came inside an encrypted message.
    func apply(_ amendment: MessageAmendment, in conversation: Conversation, accountID: UUID, isDecrypted: Bool) async -> UUID? {
        switch amendment.change {
        case let .correction(newBody, replyFallbackRange):
            await applyCorrection(
                originalID: amendment.originalID, newBody: newBody, replyFallbackRange: replyFallbackRange, from: amendment.from,
                in: conversation, accountID: accountID, timestamp: amendment.timestamp, isDecrypted: isDecrypted
            )
        case .retraction:
            await applyRetraction(
                originalID: amendment.originalID, from: amendment.from, in: conversation, accountID: accountID,
                timestamp: amendment.timestamp, isDecrypted: isDecrypted
            )
        case .moderation:
            await applyModeration(amendment, in: conversation)
        }
    }

    private func applyModeration(_ amendment: MessageAmendment, in conversation: Conversation) async -> UUID? {
        guard let original = try? await transcripts.findMessage(serverID: amendment.originalID, conversationID: conversation.id) else {
            return nil
        }
        try? await transcripts.appendAmendment(
            TranscriptAmendment(action: .retract, targetMessageID: original.id, targetServerID: amendment.originalID, timestamp: amendment.timestamp),
            conversationID: conversation.id
        )
        await messagesChanged(in: conversation.id)
        return original.id
    }
}
