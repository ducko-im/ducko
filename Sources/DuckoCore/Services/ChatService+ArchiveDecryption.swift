import DuckoXMPP
import Foundation

/// One read of an archive (XEP-0313), and what it tells about its entries beyond what they hold.
struct ArchiveRead {
    /// Whether the room, or the room of a private chat, advertised occupant ids when its features were read for this
    /// read, which tells the entries' senders apart.
    let roomSupportsOccupantIDs: Bool?
    /// Catch-up reads what came since the last connection, so its encrypted entries take up key exchanges and record
    /// opt-outs. Scrollback reads older entries, whose key exchanges can be older than the sessions in use and whose
    /// opt-outs the contact may long since have taken back, so it does neither.
    let isCatchUp: Bool
    /// What the read's encrypted entries decrypted to, by archive id.
    var decrypted: [String: EncryptedContent] = [:]
}

/// Decrypting the OMEMO messages archives return and storing what they decrypt to.
extension ChatService {
    /// What the encrypted entries of `page`, read from `conversation`'s archive in archive order, decrypt to, by archive
    /// id. A room message or room private message is decrypted with the session of the real JID the archive recorded
    /// for its author. An entry stored decrypted already is not decrypted again. Decrypting stops once `isCurrent` turns
    /// false, so the rest stays for a later read.
    func decryptedEntries(
        of page: [ArchivedMessage], in conversation: Conversation, read: ArchiveRead, accountID: UUID, isCurrent: () -> Bool
    ) async -> [String: EncryptedContent] {
        guard let omemoService else { return [:] }
        var decrypted: [String: EncryptedContent] = [:]
        for entry in page where entry.forwarded.message.isOMEMOEncrypted {
            guard isCurrent() else { break }
            guard await !isStoredDecrypted(entry, in: conversation) else { continue }
            let message = entry.forwarded.message
            let author = archivedRoomAuthor(of: message, in: conversation, roomSupportsOccupantIDs: read.roomSupportsOccupantIDs, accountID: accountID)
            decrypted[entry.messageID] = await omemoService.decryptArchivedMessage(
                message, sender: author?.realJID, isRoomPrivateMessage: conversation.occupantNickname != nil, allowsKeyExchange: read.isCatchUp,
                accountID: accountID
            )
        }
        return decrypted
    }

    /// What an encrypted entry of the account's own archive decrypts to, taking up a key exchange it carries. Whether it
    /// is a room's private message is told as `catchUpConversation` tells it, before any chat is made: by a full peer JID
    /// whose bare JID is one of the rooms among `conversations`. Only the user's own private message names its sender,
    /// since the account's archive records no occupant's real JID. An entry stored decrypted already in its chat among
    /// `conversations` is not decrypted again.
    func decryptedAccountArchiveEntry(
        _ entry: ArchivedMessage, among conversations: [Conversation], accountJID: BareJID, accountID: UUID
    ) async -> EncryptedContent? {
        guard let omemoService else { return nil }
        let message = entry.forwarded.message
        let isOutgoing = message.from?.bareJID == accountJID
        let peer = isOutgoing ? message.to : message.from
        let occupant: FullJID? = if case let .full(occupant) = peer, Self.isRoom(occupant.bareJID, among: conversations) { occupant } else { nil }
        let chat = conversations.first { conversation in
            if let occupant {
                return conversation.jid == occupant.bareJID && conversation.type == .chat && conversation.occupantNickname == occupant.resourcePart
            }
            return conversation.jid == peer?.bareJID && conversation.occupantNickname == nil
        }
        if let chat, await isStoredDecrypted(entry, in: chat) { return nil }
        return await omemoService.decryptArchivedMessage(
            message, sender: isOutgoing ? accountJID : nil, isRoomPrivateMessage: occupant != nil, allowsKeyExchange: true, accountID: accountID
        )
    }

    /// Whether `conversation` stores `entry` under its archive id as a readable row. A notice stored for it does not
    /// count, so what it decrypts to can replace the notice.
    private func isStoredDecrypted(_ entry: ArchivedMessage, in conversation: Conversation) async -> Bool {
        guard let stored = try? await transcripts.findMessage(serverID: entry.messageID, conversationID: conversation.id) else { return false }
        return !stored.isUndecryptable
    }

    /// Stores an archived encrypted entry unless a copy of it is stored already, and returns its row when this call added
    /// it. It is stored as what `read` decrypted it to when that passes the envelope's time check (XEP-0420), and as a
    /// notice otherwise, which a decrypted copy replaces. A decrypted correction or retraction, or a decrypted message
    /// without a body or attachment, stores nothing. At catch-up, a message from someone else is taken up as a live
    /// one is, by `takeUpDecryptedMessage`.
    func storeArchivedEncryptedEntry(
        _ entry: ArchivedEntry, read: ArchiveRead, in conversation: Conversation, accountJID: BareJID, accountID: UUID
    ) async throws -> ChatMessage? {
        var entry = entry
        let checked = read.decrypted[entry.serverID].map { checkingTime(of: $0, sentAt: entry.forwarded.sentTime) }
        guard case let .decrypted(decrypted, _, isFromUntrustedDevice) = checked else {
            if case let .undecryptable(reason) = checked {
                entry.undecryptableReason = reason
            }
            let notice = await makeArchivedMessage(entry, in: conversation, accountJID: accountJID)
            return try await storeArchivedEncryptedMessage(notice, of: entry, in: conversation) == .inserted ? notice : nil
        }
        guard !MessageAmendment.isCarried(by: decrypted) else { return nil }
        let row = await decryptedRow(
            makeArchivedMessage(entry, in: conversation, accountJID: accountJID), reading: decrypted, isFromUntrustedDevice: isFromUntrustedDevice,
            in: conversation, accountID: accountID
        )
        let outcome = if let row { try await storeArchivedEncryptedMessage(row, of: entry, in: conversation) } else { nil as EncryptedMessageStoreOutcome? }
        if case .upgraded = outcome {
            await messagesChanged(in: conversation.id)
        }
        if read.isCatchUp, !entry.meta.isOutgoing {
            let received = ReceivedDecryptedMessage(
                message: decrypted, sender: entry.meta.fromJID, sentTime: entry.forwarded.sentTime, isFromUntrustedDevice: isFromUntrustedDevice
            )
            await takeUpDecryptedMessage(received, storedAs: outcome, in: current(conversation), accountID: accountID)
        }
        return outcome == .inserted ? row : nil
    }

    /// Stores `message`, the row of an archived encrypted `entry`. A copy stored without a server id, such as the user's
    /// own message stored before it was sent, gets the archive's id recorded rather than a second row, and is then
    /// upgraded when it is a notice and `message` is readable.
    private func storeArchivedEncryptedMessage(
        _ message: ChatMessage, of entry: ArchivedEntry, in conversation: Conversation
    ) async throws -> EncryptedMessageStoreOutcome {
        if let copy = try await recordArchiveID(onCopyOf: entry, in: conversation), !copy.isUndecryptable || message.isUndecryptable {
            return .duplicate
        }
        return try await transcripts.storeEncryptedMessage(message, fromArchive: true)
    }

    /// `conversation` as the service holds it now, with the changes stored since it was read, or `conversation` itself
    /// while it is not loaded.
    func current(_ conversation: Conversation) -> Conversation {
        openConversations.first { $0.id == conversation.id } ?? conversation
    }
}
