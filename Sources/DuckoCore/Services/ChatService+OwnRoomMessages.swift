import DuckoXMPP
import Foundation

extension ChatService {
    /// What tells a copy of a room message apart as the user's once the room's features are known. Where the room
    /// advertises occupant ids, that is the user's own occupant id. Without them, it is the account's real JID where
    /// the copy shows one, and otherwise the user's nickname.
    struct OwnRoomIdentity {
        let supportsOccupantIDs: Bool
        let occupantID: String?
        let realJID: BareJID?
        let nickname: String?

        /// Whether `message`, a copy of a room message that `author` describes, comes from the user.
        func isSender(of message: XMPPMessage, author: RoomAuthorIdentity?) -> Bool {
            guard case let .full(occupant) = message.from else { return false }
            if supportsOccupantIDs {
                return author?.occupantID != nil && author?.occupantID == occupantID
            }
            if let realJID = author?.realJID { return realJID == self.realJID }
            return occupant.resourcePart == nickname
        }
    }

    /// The user in `room`, where `supportsOccupantIDs` tells whether the room advertises occupant ids, reading only what
    /// `OwnRoomIdentity` compares for it.
    func ownRoomIdentity(in room: BareJID, supportsOccupantIDs: Bool, accountID: UUID) async -> OwnRoomIdentity {
        if supportsOccupantIDs {
            return await OwnRoomIdentity(supportsOccupantIDs: true, occupantID: ownOccupantID(inRoom: room, accountID: accountID), realJID: nil, nickname: nil)
        }
        return await OwnRoomIdentity(
            supportsOccupantIDs: false, occupantID: nil, realJID: resolvedAccountJID(for: accountID), nickname: ownNickname(inRoom: room, accountID: accountID)
        )
    }

    /// The occupant id `room` gave the user's own presence, kept whether or not the room advertises them. The room
    /// module's comes first, and the one stored when the room last confirmed a join stands in, such as before a rejoin
    /// confirms. A room keeps an occupant's id stable (XEP-0421), so the stored one stays the user's.
    func ownOccupantID(inRoom room: BareJID, accountID: UUID) async -> String? {
        if let occupantID = accountService?.roomModule(for: accountID)?.ownOccupantID(in: room) { return occupantID }
        let stored = try? await store.fetchConversation(jid: room.description, type: .groupchat, accountID: accountID, importSourceJID: nil)
        return stored?.roomOccupantID
    }

    /// Whether `message`, which a room relays live, comes from the user. `author` is who sent it as the room's module
    /// saw it. Where the room's features are known, `OwnRoomIdentity` decides. Where they are unknown, an undelayed
    /// message under the nickname the room confirmed as the user's is theirs, since no one else holds that nickname
    /// meanwhile. Otherwise it must come under the user's nickname and match the row this device stored when sending
    /// it, by `body` unless it is encrypted.
    func isOwnRoomEcho(
        _ message: XMPPMessage, ofEncrypted isEncrypted: Bool = false, body: String, author: RoomAuthorIdentity?, accountID: UUID
    ) async -> Bool {
        guard case let .full(occupant) = message.from else { return false }
        let room = occupant.bareJID
        if let supportsOccupantIDs = author?.roomSupportsOccupantIDs {
            return await ownRoomIdentity(in: room, supportsOccupantIDs: supportsOccupantIDs, accountID: accountID).isSender(of: message, author: author)
        }
        if !message.isDelayed, occupant.resourcePart == accountService?.roomModule(for: accountID)?.confirmedNickname(in: room) { return true }
        guard await occupant.resourcePart == ownNickname(inRoom: room, accountID: accountID) else { return false }
        return await ownRow(echoedBy: InboundMessageMetadata(message), ofEncrypted: isEncrypted, body: body, in: room, accountID: accountID) != nil
    }

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

    /// Records the server id assigned to `row`, a message stored without one, such as the user's own room message,
    /// which was stored before it was sent.
    func recordServerID(_ serverID: String, on row: ChatMessage) async throws {
        try await transcripts.appendAmendment(
            TranscriptAmendment(action: .serverIDAssigned, targetMessageID: row.id, serverID: serverID),
            conversationID: row.conversationID
        )
        await messagesChanged(in: row.conversationID)
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
