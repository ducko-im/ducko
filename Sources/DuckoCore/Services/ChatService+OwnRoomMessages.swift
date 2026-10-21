import DuckoXMPP
import Foundation

extension ChatService {
    /// Records `serverID`, the stanza-id `room` stamped on its echo of the user's own message, on the row stored when the
    /// message was sent.
    func recordEchoedServerID(_ serverID: String, echo metadata: InboundMessageMetadata, body: String, in room: BareJID, accountID: UUID) async {
        guard let ownRow = await ownRow(echoedBy: metadata, body: body, in: room, accountID: accountID) else { return }
        try? await recordServerID(serverID, on: ownRow)
    }

    /// The row stored when the user sent the message `room` echoes, if this device sent it. The echo is matched by its
    /// origin-id, else its message id, and by its body unless it is encrypted.
    func ownRow(
        echoedBy metadata: InboundMessageMetadata, ofEncrypted isEncrypted: Bool = false, body: String, in room: BareJID, accountID: UUID
    ) async -> ChatMessage? {
        guard let conversation = try? await store.fetchConversation(jid: room.description, type: .groupchat, accountID: accountID, importSourceJID: nil)
        else { return nil }
        return try? await ownRow(echoedBy: metadata, ofEncrypted: isEncrypted, body: body, conversationID: conversation.id)
    }

    /// The row stored in the room's conversation `conversationID` when the user sent the message that `metadata` is a
    /// copy of, either the room's live echo or its archived copy. The room can give the copy an id of its own, so the
    /// copy is matched by its origin-id, else its message id.
    func ownRow(
        echoedBy metadata: InboundMessageMetadata, ofEncrypted isEncrypted: Bool, body: String, conversationID: UUID
    ) async throws -> ChatMessage? {
        guard let echoID = metadata.originID ?? metadata.stanzaID else { return nil }
        return try await ownOptimisticGroupRow(stanzaID: echoID, isEncryptedCopy: isEncrypted, body: body, conversationID: conversationID)
    }

    /// Records the server id the room assigned to the user's own room message, which was stored before it was sent.
    func recordServerID(_ serverID: String, on ownRow: ChatMessage) async throws {
        try await transcripts.appendAmendment(
            TranscriptAmendment(action: .serverIDAssigned, targetMessageID: ownRow.id, serverID: serverID),
            conversationID: ownRow.conversationID
        )
        await messagesChanged(in: ownRow.conversationID)
    }

    /// The un-reconciled optimistic own-MUC row (`serverID == nil`) that a copy of the user's own room message with
    /// `stanzaID` matches, so neither the room's echo nor a MAM replay of it is imported again. A plaintext copy
    /// matches on body equality. An encrypted copy matches on `isEncrypted` alone, since the row stores the plaintext
    /// and the copy carries none. Uses the all-candidates `findMessages` query so a stanza ID collision can't make
    /// `findMessage`'s first-match return an older, wrong row.
    func ownOptimisticGroupRow(
        stanzaID: String, isEncryptedCopy: Bool, body: String, conversationID: UUID
    ) async throws -> ChatMessage? {
        let candidates = try await transcripts.findMessages(stanzaID: stanzaID, conversationID: conversationID)
        return candidates.first { candidate in
            guard candidate.isOutgoing, candidate.serverID == nil else { return false }
            // A retracted optimistic row has its body cleared, so the body/isEncrypted disambiguation
            // below can't recognize it. Suppress the MAM replay anyway: a stanza we retracted must stay
            // gone, not re-import as a fresh unretracted row.
            if candidate.isRetracted { return true }
            return isEncryptedCopy ? candidate.isEncrypted : candidate.body == body
        }
    }
}
