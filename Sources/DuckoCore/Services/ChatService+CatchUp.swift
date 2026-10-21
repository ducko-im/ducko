import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.chat")

extension ChatService {
    /// Where catch-up starts reading the archives: after the newest message stored in any of the account's chats, and
    /// for each room after the newest one stored there. Nil where nothing is stored.
    struct CatchUpStart {
        var chats: Date?
        var rooms: [UUID: Date] = [:]

        /// For each archive, the older of this start and `other`, so what a catch-up cut short did not read is read
        /// again. An archive only one of them starts somewhere starts there.
        func keepingOlder(_ other: CatchUpStart) -> CatchUpStart {
            CatchUpStart(chats: [chats, other.chats].compactMap(\.self).min(), rooms: rooms.merging(other.rooms) { min($0, $1) })
        }
    }

    /// The connection a catch-up reads the archives over.
    private struct CatchUpSession {
        let client: XMPPClient
        let mamModule: MAMModule
        let accountID: UUID
        let accountJID: BareJID
    }

    /// How many entries one catch-up query asks an archive for.
    private static let catchUpPageSize = 50

    /// Notes where the next catch-up starts, as `CatchUpStart` describes. Called on connect before the session can
    /// store anything, so messages it delivers before catch-up runs, such as ones held offline, cannot move the start
    /// past messages only the archive has. A start noted for a catch-up that has not completed is kept where it is
    /// older.
    func captureCatchUpStart(accountID: UUID) async {
        do {
            var start = CatchUpStart()
            for conversation in try await store.fetchConversations(for: accountID) {
                guard let newest = conversation.lastMessageDate else { continue }
                switch conversation.type {
                case .chat: start.chats = max(start.chats ?? newest, newest)
                case .groupchat: start.rooms[conversation.id] = newest
                }
            }
            catchUpStarts[accountID] = catchUpStarts[accountID]?.keepingOlder(start) ?? start
        } catch {
            log.warning("Could not note where catch-up starts: \(error.localizedDescription)")
        }
    }

    /// Catches up on what the archives hold since the start noted on connect: the account's own archive, which holds
    /// every chat, then each room's. Each archive is read page by page to its end, or only its newest page when nothing
    /// is stored to start from. An archive's start is let go once it was read on the session that asked, and a room
    /// whose archive cannot be read keeps its start without holding up the rooms after it.
    func syncRecentHistory(accountID: UUID) async {
        let start = catchUpStarts[accountID]
        guard let client = accountService?.connectedClient(for: accountID), let mamModule = await client.module(ofType: MAMModule.self),
              let accountJID = resolvedAccountJID(for: accountID) else { return }
        let session = CatchUpSession(client: client, mamModule: mamModule, accountID: accountID, accountJID: accountJID)

        do {
            let conversations = try await store.fetchConversations(for: accountID)
            try await readArchive(of: nil, from: start?.chats, session: session) { page in
                try await ingestAccountArchivePage(page, among: conversations, session: session)
                return true
            }
            if isCurrent(session) {
                catchUpStarts[accountID]?.chats = nil
            }
            for room in conversations where room.type == .groupchat {
                guard isCurrent(session) else { return }
                do {
                    try await readArchive(of: room.jid, from: start?.rooms[room.id], session: session) { page in
                        try await ingestArchivePage(page, in: room, session: session)
                    }
                    if isCurrent(session) {
                        catchUpStarts[accountID]?.rooms[room.id] = nil
                    }
                } catch {
                    log.warning("Could not catch up on a room: \(error.localizedDescription)")
                    log.debug("The room catch-up could not read is \(room.jid)")
                }
            }
            try await loadConversations(for: accountID)
        } catch {
            let desc = error.localizedDescription
            log.warning("MAM sync failed: \(desc)")
        }
    }

    /// Whether `session` is still the account's, and the catch-up on it was not cancelled.
    private func isCurrent(_ session: CatchUpSession) -> Bool {
        !Task.isCancelled && accountService?.connectedClient(for: session.accountID) === session.client
    }

    /// Reads the archive of `room`, or the account's own when nil, forward from `start` until it reports its end,
    /// handing each page to `ingest` while that returns true. Without a start, only the newest page is read. Reading
    /// stops when the task is cancelled or the session that asked has ended.
    private func readArchive(
        of room: BareJID?, from start: Date?, session: CatchUpSession, ingest: ([ArchivedMessage]) async throws -> Bool
    ) async throws {
        var after: String?
        while true {
            let query = if let start {
                MAMModule.Query(to: room, start: start.formatted(.iso8601), after: after, max: Self.catchUpPageSize)
            } else {
                MAMModule.Query(to: room, before: .lastPage, max: Self.catchUpPageSize)
            }
            let (archived, fin) = try await session.mamModule.queryMessages(query)
            guard try await ingest(archived), start != nil, !fin.complete, let last = fin.last, last != after, isCurrent(session)
            else { return }
            after = last
        }
    }

    /// Files each entry of a page of the account's own archive in its chat among the account's `conversations`, and
    /// stores it there.
    private func ingestAccountArchivePage(_ page: [ArchivedMessage], among conversations: [Conversation], session: CatchUpSession) async throws {
        var filedIn: [Conversation] = []
        var entries: [UUID: [ArchivedMessage]] = [:]
        for entry in page {
            guard let conversation = try await catchUpConversation(for: entry.forwarded.message, among: conversations, session: session) else {
                continue
            }
            if entries[conversation.id] == nil {
                filedIn.append(conversation)
            }
            entries[conversation.id, default: []].append(entry)
        }
        for conversation in filedIn {
            try await ingestArchivePage(entries[conversation.id] ?? [], in: conversation, session: session)
        }
    }

    /// The chat an entry of the account's own archive belongs in, created for a message from or to someone the account
    /// has no chat with yet. A room occupant's message goes to the private chat with them, and a correction or
    /// retraction goes only to a chat that exists. Nil for entries that make no chat: room messages, headlines and
    /// errors; anything to or from the account's server or a room's own address; invites; private messages from a room
    /// the user has no chat with; and entries without a message, such as receipts, chat states or OMEMO key exchanges.
    private func catchUpConversation(
        for message: XMPPMessage, among conversations: [Conversation], session: CatchUpSession
    ) async throws -> Conversation? {
        let messageType = message.messageType ?? .normal
        switch messageType {
        case .groupchat, .headline, .error: return nil
        case .chat, .normal: break
        }
        let isOutgoing = message.from?.bareJID == session.accountJID
        guard let peer = isOutgoing ? message.to : message.from,
              peer.bareJID.localPart != nil || peer.bareJID.domainPart != session.accountJID.domainPart
        else { return nil }
        if MessageAmendment.isCarried(by: message) {
            return await amendedConversation(chatWith: peer, messageType: messageType, accountID: session.accountID)
        }
        guard Self.holdsArchivedMessage(message) else { return nil }
        guard Self.isRoom(peer.bareJID, among: conversations) else {
            // The live path shows an invite, or a room's private message, as an event of its own, never in a chat.
            guard message.isEncrypted || !message.hasClassifiedEvent else { return nil }
            return try await findOrCreateConversation(for: peer.bareJID, accountID: session.accountID)
        }
        guard case let .full(occupant) = peer, message.isEncrypted || !message.carriesInvite else { return nil }
        return try await findOrCreateMUCPMConversation(for: occupant.bareJID, nickname: occupant.resourcePart, accountID: session.accountID)
    }

    /// Whether an archived message holds something to show: a body or attachment, an OMEMO payload, or a message
    /// encrypted with another method. An OMEMO message without a payload only manages keys.
    private static func holdsArchivedMessage(_ message: XMPPMessage) -> Bool {
        if message.isOMEMOEncrypted {
            return !message.carriesOnlyOMEMOKeys
        }
        return message.body != nil || !InboundMessageMetadata(message).attachments.isEmpty || message.isEncrypted
    }

    /// Stores an archive page's new messages in `conversation` and applies its corrections and retractions. Returns
    /// false when the conversation was deleted meanwhile, so nothing more is read into it.
    @discardableResult
    private func ingestArchivePage(_ page: [ArchivedMessage], in conversation: Conversation, session: CatchUpSession) async throws -> Bool {
        let (newMessages, amendments) = try await convertAndDedup(
            archived: page, conversation: conversation, accountJID: session.accountJID, accountID: session.accountID
        )
        await applyArchivedAmendments(amendments, in: conversation, accountID: session.accountID)
        // `convertAndDedup` appended the archived rows to the transcript across several awaits. If the conversation was
        // deleted during the MAM round-trip or those appends, delete the transcript it recreated rather than leave an
        // orphaned JSONL the account-purge sweep can no longer reach. Checked after the appends so no transcript write
        // can follow it; the metadata write below is guarded separately by `updateConversation`.
        guard try await store.fetchConversations(for: session.accountID).contains(where: { $0.id == conversation.id }) else {
            try? await transcripts.deleteTranscripts(for: conversation.id)
            return false
        }
        try await recordLastMessage(of: newMessages, in: conversation.id)
        return true
    }

    /// Makes the newest of `newMessages`, read from an archive oldest first, the conversation's last message unless the
    /// one it has is newer, so the next catch-up starts after it.
    func recordLastMessage(of newMessages: [ChatMessage], in conversationID: UUID) async throws {
        guard let lastMessage = newMessages.last else { return }
        // Updates an existing row only, since the conversation may have been destroyed during this MAM round-trip. It
        // writes only the last message's date and preview, because the conversation was read before the round-trip and
        // the rest of it may have changed since. A live message as new as this one keeps its preview, which can be the
        // decrypted text of the archive's undecryptable copy.
        try await store.updateConversation(conversationID) { conversation in
            conversation.recordLastMessage(lastMessage, winsTies: false)
        }
    }
}
