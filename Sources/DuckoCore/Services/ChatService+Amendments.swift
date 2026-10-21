import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.chat")

extension ChatService {
    /// Applies a correction from `from`, received live, in the chat with them.
    func handleMessageCorrected(
        originalID: String, newBody: String, replyFallbackRange: Range<Int>? = nil, from: JID, messageType: XMPPMessage.MessageType,
        accountID: UUID
    ) async {
        guard let conversation = await amendedConversation(chatWith: from, messageType: messageType, accountID: accountID) else { return }
        await applyCorrection(
            originalID: originalID, newBody: newBody, replyFallbackRange: replyFallbackRange, from: from, in: conversation, accountID: accountID
        )
    }

    /// Applies a retraction from `from`, received live, in the chat with them.
    func handleMessageRetracted(originalID: String, from: JID, messageType: XMPPMessage.MessageType, accountID: UUID) async {
        guard let conversation = await amendedConversation(chatWith: from, messageType: messageType, accountID: accountID) else { return }
        await applyRetraction(originalID: originalID, from: from, in: conversation, accountID: accountID)
    }

    /// Applies a correction from `from`, made at `timestamp`, in `conversation`, and returns the id of the message it
    /// corrected. A correction names the message by its own id, in rooms too (XEP-0308). The corrected body is stored
    /// with its own reply quote, `replyFallbackRange`, which can differ from the original's or be gone. An encrypted
    /// message takes only a correction that `isDecrypted`, so text the server could read never shows as encrypted.
    @discardableResult
    func applyCorrection(
        originalID: String, newBody: String, replyFallbackRange: Range<Int>? = nil, from: JID, in conversation: Conversation,
        accountID: UUID, timestamp: Date = Date(), isDecrypted: Bool = false
    ) async -> UUID? {
        let candidates = await (try? transcripts.findMessages(stanzaID: originalID, conversationID: conversation.id)) ?? []
        guard let original = await amendmentTarget(among: candidates, from: from, in: conversation, action: "correction", accountID: accountID) else {
            return nil
        }
        guard !original.isEncrypted || isDecrypted else {
            log.warning("Rejected an unencrypted correction of an encrypted message")
            return nil
        }

        let filterDirection: FilterDirection = original.isOutgoing ? .outgoing : .incoming
        let filtered = await filterBody(
            newBody, direction: filterDirection, accountID: accountID, fallback: from.bareJID, isEncrypted: original.isEncrypted || isDecrypted,
            replyFallbackRange: replyFallbackRange
        )

        try? await transcripts.appendAmendment(
            TranscriptAmendment(
                action: .edit, targetMessageID: original.id, targetStanzaID: originalID, timestamp: timestamp,
                body: filtered.body, htmlBody: filtered.htmlBody, replyFallbackRange: replyFallbackRange
            ),
            conversationID: conversation.id
        )
        await messagesChanged(in: conversation.id)
        return original.id
    }

    /// Applies a retraction from `from`, made at `timestamp`, in `conversation`, and returns the id of the message it
    /// retracted. A room's retraction names the message by the stanza-id the room assigned to it (XEP-0424 §5.1). An
    /// encrypted message takes only a retraction that `isDecrypted`, so one sent in the clear never removes it.
    @discardableResult
    func applyRetraction(
        originalID: String, from: JID, in conversation: Conversation, accountID: UUID, timestamp: Date = Date(), isDecrypted: Bool = false
    ) async -> UUID? {
        let candidates: [ChatMessage] = if conversation.type == .groupchat {
            await [try? transcripts.findMessage(serverID: originalID, conversationID: conversation.id)].compactMap(\.self)
        } else {
            await (try? transcripts.findMessages(stanzaID: originalID, conversationID: conversation.id)) ?? []
        }
        guard let original = await amendmentTarget(among: candidates, from: from, in: conversation, action: "retraction", accountID: accountID) else {
            return nil
        }
        guard !original.isEncrypted || isDecrypted else {
            log.warning("Rejected an unencrypted retraction of an encrypted message")
            return nil
        }

        try? await transcripts.appendAmendment(
            TranscriptAmendment(action: .retract, targetMessageID: original.id, targetStanzaID: original.stanzaID, timestamp: timestamp),
            conversationID: conversation.id
        )
        await messagesChanged(in: conversation.id)
        return original.id
    }

    /// The conversation a correction or retraction of `messageType` in the chat with `peer` amends. A `groupchat` one
    /// amends the room. Any other amends the private chat with the occupant when `peer` is in a room, else the 1:1
    /// chat, so a room occupant's private amendment never lands in the room or in the private chat with another
    /// occupant.
    func amendedConversation(chatWith peer: JID, messageType: XMPPMessage.MessageType, accountID: UUID) async -> Conversation? {
        let candidates = await ((try? store.fetchConversations(for: accountID)) ?? []).filter { $0.jid == peer.bareJID }
        if messageType == .groupchat {
            return candidates.first { $0.type == .groupchat }
        }
        guard Self.isRoom(peer.bareJID, among: candidates) else { return candidates.first { $0.occupantNickname == nil } }
        guard case let .full(occupant) = peer else { return nil }
        return candidates.first { $0.occupantNickname == occupant.resourcePart }
    }

    /// The chat with `peer`: the private chat with a room's occupant, else the 1:1 chat. Nil for a room's own address,
    /// and in place of the 1:1 chat when `opensDirectChat` is false.
    func chat(with peer: JID, accountID: UUID, opensDirectChat: Bool = true) async -> (conversation: Conversation, occupant: FullJID?)? {
        let conversations = await (try? store.fetchConversations(for: accountID)) ?? []
        guard Self.isRoom(peer.bareJID, among: conversations) else {
            guard opensDirectChat else { return nil }
            return await (try? findOrCreateConversation(for: peer.bareJID, accountID: accountID)).map { ($0, nil) }
        }
        guard case let .full(occupant) = peer else { return nil }
        return await (try? findOrCreateMUCPMConversation(for: occupant.bareJID, nickname: occupant.resourcePart, accountID: accountID))
            .map { ($0, occupant) }
    }

    /// Whether `jid` is a room's address among the account's `conversations`: the user has the room, or a private chat
    /// with one of its occupants, which outlives the room.
    static func isRoom(_ jid: BareJID, among conversations: [Conversation]) -> Bool {
        conversations.contains { $0.jid == jid && !$0.isDirectChat }
    }

    /// The message among `candidates` that a correction or retraction from `from` targets: the newest one `from` sent.
    /// Message ids are unique only per sender, so another sender's message with the same id never matches. The
    /// account's own amendments match its outgoing messages, since an outgoing 1:1 message stores the recipient as its
    /// sender. Anyone else's amendments match their incoming messages stored under them.
    private func amendmentTarget(
        among candidates: [ChatMessage], from: JID, in conversation: Conversation, action: String, accountID: UUID
    ) async -> ChatMessage? {
        let isOwn = await isOwnMessage(from: from, in: conversation, accountID: accountID)
        let sender = storedSender(of: from, in: conversation)
        let target = candidates
            .filter { isOwn ? $0.isOutgoing : !$0.isOutgoing && $0.fromJID == sender }
            .max { $0.timestamp < $1.timestamp }
        if target == nil, !candidates.isEmpty {
            log.warning("Rejected \(action) from a sender other than the original one")
            log.debug("The rejected \(action) came from \(from)")
        }
        return target
    }

    /// The sender an incoming message from `from` is stored under: the occupant's nickname in a room or a room's private
    /// chat, else the bare JID. Nil for a room sender without a nickname.
    private func storedSender(of from: JID, in conversation: Conversation) -> String? {
        guard conversation.type == .groupchat || conversation.occupantNickname != nil else { return from.bareJID.description }
        guard case let .full(occupant) = from else { return nil }
        return occupant.resourcePart
    }
}
