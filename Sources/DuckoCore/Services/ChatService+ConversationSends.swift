import DuckoXMPP
import Foundation

/// Sending in one of the account's conversations: a message or a reply to one, a correction of one of the user's own
/// messages, a retraction of one, and a moderator's removal of a room's message. The conversation is read as stored
/// now, since the caller's copy can be older, and that decides where it goes (the room, the occupant of a private chat
/// in one, or the contact of a 1:1 chat) and whether it is encrypted.
public extension ChatService {
    /// Sends `body` in `conversation`, as a reply (XEP-0461) to `quoted` when given.
    func sendMessage(_ body: String, in conversation: Conversation, replyingTo quoted: ChatMessage? = nil, accountID: UUID) async throws {
        let conversation = try await storedConversation(conversation, accountID: accountID)
        if let quoted, quoted.conversationID != conversation.id {
            throw ChatServiceError.messageNotInConversation
        }
        if conversation.type == .groupchat {
            try await sendGroupMessage(body, inRoom: conversation, replyingTo: quoted, accountID: accountID)
        } else if conversation.occupantNickname != nil {
            try await sendPrivateMessage(body, inPrivateChat: conversation, replyingTo: quoted, accountID: accountID)
        } else {
            try await sendMessage(body, toContactIn: conversation, replyingTo: quoted, accountID: accountID)
        }
    }

    /// Sends the correction (XEP-0308) of the user's own `original` in `conversation` and stores it as the message's
    /// edit. `original` is never looked up by its stanza id, which is unique only per sender. The correction of an
    /// encrypted message is encrypted too, even once encryption is off in the conversation, and is not sent when it
    /// cannot be.
    func sendCorrection(of original: ChatMessage, newBody: String, in conversation: Conversation, accountID: UUID) async throws {
        var conversation = try await storedConversation(conversation, accountID: accountID)
        let stanzaID = try ownStanzaID(of: original, in: conversation)
        conversation.encryptionEnabled = conversation.encryptionEnabled || original.isEncrypted
        if conversation.type == .groupchat {
            try await sendGroupCorrection(of: original, stanzaID: stanzaID, newBody: newBody, inRoom: conversation, accountID: accountID)
        } else if conversation.occupantNickname != nil {
            try await sendPrivateCorrection(of: original, stanzaID: stanzaID, newBody: newBody, inPrivateChat: conversation, accountID: accountID)
        } else {
            try await sendCorrection(of: original, stanzaID: stanzaID, newBody: newBody, toContactIn: conversation, accountID: accountID)
        }
    }

    /// Retracts the user's own `original` (XEP-0424) in `conversation`. The retraction of an encrypted message is
    /// encrypted too, even once encryption is off in the conversation, and is not sent when it cannot be.
    func retractMessage(_ original: ChatMessage, in conversation: Conversation, accountID: UUID) async throws {
        var conversation = try await storedConversation(conversation, accountID: accountID)
        let stanzaID = try ownStanzaID(of: original, in: conversation)
        conversation.encryptionEnabled = conversation.encryptionEnabled || original.isEncrypted
        if conversation.type == .groupchat {
            try await retractGroupMessage(original, stanzaID: stanzaID, inRoom: conversation, accountID: accountID)
        } else if conversation.occupantNickname != nil {
            try await retractPrivateMessage(original, stanzaID: stanzaID, inPrivateChat: conversation, accountID: accountID)
        } else {
            try await retractMessage(original, stanzaID: stanzaID, toContactIn: conversation, accountID: accountID)
        }
    }

    /// Removes the message the room `conversation` assigned the stanza-id `serverID` to, as one of its moderators
    /// (XEP-0425), and stores it as retracted.
    func moderateMessage(serverID: String, in conversation: Conversation, reason: String?, accountID: UUID) async throws {
        let conversation = try await storedConversation(conversation, accountID: accountID)
        guard conversation.type == .groupchat else { throw ChatServiceError.notRoom }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }

        try await mucModule.moderateMessage(room: conversation.jid, stanzaID: serverID, reason: reason)
        try await recordModeration(of: serverID, in: conversation.id)
    }
}

extension ChatService {
    /// `conversation` as stored now, when it is one of the account's.
    private func storedConversation(_ conversation: Conversation, accountID: UUID) async throws -> Conversation {
        guard let stored = try await store.fetchConversations(for: accountID).first(where: { $0.id == conversation.id }) else {
            throw ChatServiceError.conversationNotInAccount
        }
        return stored
    }

    /// The id the user's own `message` in `conversation` was sent with, which a correction or a retraction names.
    private func ownStanzaID(of message: ChatMessage, in conversation: Conversation) throws -> String {
        guard message.isOutgoing, let stanzaID = message.stanzaID else { throw ChatServiceError.notOutgoingMessage }
        guard message.conversationID == conversation.id else { throw ChatServiceError.messageNotInConversation }
        return stanzaID
    }
}
