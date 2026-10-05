import DuckoXMPP
import Foundation
import Logging

enum BookmarksError: Error, LocalizedError {
    case invalidJID(String)
    case notConnected(UUID)

    var errorDescription: String? {
        switch self {
        case let .invalidJID(jid):
            return "Invalid JID: \(jid)"
        case .notConnected:
            return notConnectedDescription
        }
    }
}

@MainActor @Observable
public final class BookmarksService {
    private var bookmarksByAccount: [UUID: [RoomBookmark]] = [:]
    /// Accounts whose stream dropped and may yet resume. Their bookmarks are kept but not shown: a resumed stream
    /// carries on where it left off, so the server replays the pushes that were missed rather than the whole list.
    private var suspendedAccounts: Set<UUID> = []
    /// Accounts whose sign-in pass (bookmark fetch, auto-joins, rejoins) ran to its end on the session they are in.
    private(set) var completedSignInPass: Set<UUID> = []

    public var bookmarks: [RoomBookmark] {
        bookmarksByAccount.filter { !suspendedAccounts.contains($0.key) }.values.flatMap(\.self)
    }

    public var autoJoinEnabled: Bool = false

    private weak var accountService: AccountService?
    private weak var chatService: ChatService?
    private let log = Logger(label: "im.ducko.core.bookmarksservice")

    public init() {}

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    func setChatService(_ service: ChatService) {
        chatService = service
    }

    // MARK: - Lifecycle

    /// Drops what is kept for one account: its bookmarks, its suspension and its completed sign-in pass. A stream blip
    /// never gets here, so the list is kept for a resume.
    func purgeAccount(_ accountID: UUID) {
        bookmarksByAccount.removeValue(forKey: accountID)
        suspendedAccounts.remove(accountID)
        completedSignInPass.remove(accountID)
    }

    #if DEBUG
        /// Test seam: seeds per-account bookmarks without a live PEP fetch.
        func setBookmarksForTesting(_ bookmarks: [RoomBookmark], accountID: UUID) {
            bookmarksByAccount[accountID] = bookmarks
        }
    #endif

    // MARK: - Public API

    /// Fetches the bookmarks and joins their auto-join rooms. Returns whether the fetched list replaced the kept one.
    @discardableResult
    public func loadBookmarks(accountID: UUID) async -> Bool {
        guard let client = accountService?.connectedClient(for: accountID) else { return false }
        guard let pepModule = await client.module(ofType: PEPModule.self) else { return false }

        do {
            let items = try await pepModule.retrieveItems(node: XMPPNamespaces.bookmarks2)
            let parsed = items.compactMap { Bookmark.parse(itemID: $0.id, payload: $0.payload) }
            // The same client must still be connected after the fetch: a requested disconnect or a purge during the
            // await cleared the account, and storing the list would resurrect its bookmarks.
            guard accountService?.connectedClient(for: accountID) === client else { return false }
            let bookmarks = parsed.map { mapToRoomBookmark($0) }
            bookmarksByAccount[accountID] = bookmarks
            await autojoinRooms(from: bookmarks, accountID: accountID)
            return true
        } catch {
            log.warning("Failed to load bookmarks: \(error.localizedDescription)")
            return false
        }
    }

    public func addBookmark(_ bookmark: RoomBookmark, accountID: UUID) async throws {
        guard let client = accountService?.connectedClient(for: accountID) else {
            throw BookmarksError.notConnected(accountID)
        }
        guard let pepModule = await client.module(ofType: PEPModule.self) else {
            throw BookmarksError.notConnected(accountID)
        }

        guard let jid = BareJID.parse(bookmark.jidString) else {
            throw BookmarksError.invalidJID(bookmark.jidString)
        }
        let xmppBookmark = Bookmark(
            jid: jid,
            name: bookmark.name,
            autojoin: bookmark.autojoin,
            nickname: bookmark.nickname,
            password: bookmark.password
        )
        try await pepModule.publishItem(
            node: XMPPNamespaces.bookmarks2,
            itemID: jid.description,
            payload: xmppBookmark.toXMLElement(),
            options: Bookmark.publishOptions
        )

        // Merge into local state
        upsertBookmark(bookmark, accountID: accountID)
    }

    public func removeBookmark(jidString: String, accountID: UUID) async throws {
        guard let client = accountService?.connectedClient(for: accountID) else { return }
        guard let pepModule = await client.module(ofType: PEPModule.self) else { return }

        try await pepModule.retractItem(node: XMPPNamespaces.bookmarks2, itemID: jidString)
        bookmarksByAccount[accountID]?.removeAll { $0.jidString == jidString }
    }

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case .connected:
            // A fresh stream fetches the bookmarks anew, so the list kept from the last one is dropped.
            purgeAccount(accountID)
            // Wait until initial presence + caps are on the wire before the bookmarks2 PEP fetch so the
            // server has seen this resource's caps first (XEP-0163 §3.3.2). Gating here rather than inside
            // `loadBookmarks` leaves the manual REPL `/bookmarks` refresh ungated.
            let client = accountService?.connectedClient(for: accountID)
            await client?.awaitInitialPresenceSent()
            await runSignInPass(accountID: accountID, client: client)
        case .streamResumed:
            suspendedAccounts.remove(accountID)
            // A drop interrupted the sign-in pass, so it is finished on the resumed stream.
            if !completedSignInPass.contains(accountID) {
                await runSignInPass(accountID: accountID, client: accountService?.connectedClient(for: accountID))
            }
        case let .pepItemsPublished(from, node, items)
            where node == XMPPNamespaces.bookmarks2:
            await handleBookmarksPublished(from: from, items: items, accountID: accountID)
        case let .pepItemsRetracted(from, node, itemIDs)
            where node == XMPPNamespaces.bookmarks2:
            await handleBookmarksRetracted(from: from, itemIDs: itemIDs, accountID: accountID)
        case let .disconnected(reason):
            if case .requested = reason {
                purgeAccount(accountID)
            } else {
                suspendedAccounts.insert(accountID)
            }
        case .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterUpdated,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived, .roomDestroyed,
             .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .jingleChecksumReceived,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced, .omemoRecipientsPartial,
             .oobIQOfferReceived, .serviceOutageReceived:
            break
        }
    }

    /// Fetches the bookmarks, then joins the auto-join rooms and the remembered ones. The pass counts as complete
    /// only while `client`, the one it started with, is still connected at its end. The client itself is asked too:
    /// the account's state lags a client that is tearing down, and that client has refused what the pass sent.
    private func runSignInPass(accountID: UUID, client: XMPPClient?) async {
        if await !loadBookmarks(accountID: accountID) {
            // Without a fetched list, the one kept through a drop still names the auto-join rooms. A fresh session
            // has kept none.
            await autojoinRooms(from: bookmarksByAccount[accountID] ?? [], accountID: accountID)
        }
        await rejoinRooms(accountID: accountID)
        guard let client, await client.acceptsStanzas, accountService?.connectedClient(for: accountID) === client else { return }
        completedSignInPass.insert(accountID)
    }

    private func handleBookmarksPublished(from: BareJID, items: [PEPItem], accountID: UUID) async {
        // Only process our own bookmarks
        guard let account = accountService?.accounts.first(where: { $0.id == accountID }),
              from == account.jid else { return }

        let parsed = items.compactMap { Bookmark.parse(itemID: $0.id, payload: $0.payload) }

        var newBookmarks: [RoomBookmark] = []
        for bookmark in parsed {
            let roomBookmark = mapToRoomBookmark(bookmark)
            let isNew = upsertBookmark(roomBookmark, accountID: accountID)
            if isNew {
                newBookmarks.append(roomBookmark)
            }
        }

        await autojoinRooms(from: newBookmarks, accountID: accountID)
    }

    private func handleBookmarksRetracted(from: BareJID, itemIDs: [String], accountID: UUID) async {
        guard let account = accountService?.accounts.first(where: { $0.id == accountID }),
              from == account.jid else { return }

        for itemID in itemIDs {
            bookmarksByAccount[accountID]?.removeAll { $0.jidString == itemID }
            try? await chatService?.leaveRoom(jidString: itemID, accountID: accountID)
        }
    }

    private func autojoinRooms(from bookmarks: [RoomBookmark], accountID: UUID) async {
        guard autoJoinEnabled else { return }
        let account = accountService?.accounts.first(where: { $0.id == accountID })
        let fallbackNickname = account?.jid.localPart ?? ""
        let tracked = trackedRooms(accountID: accountID)

        for bookmark in bookmarks where bookmark.autojoin {
            guard let jid = BareJID.parse(bookmark.jidString), !tracked.contains(jid) else { continue }
            let nickname = bookmark.nickname ?? fallbackNickname
            guard !nickname.isEmpty else { continue }
            try? await chatService?.joinRoom(
                jid: jid,
                nickname: nickname,
                password: bookmark.password,
                accountID: accountID
            )
        }
    }

    /// Rejoins the remembered rooms that no auto-join bookmark covers and that the room module does not already track,
    /// where auto-join is on. It reads the account's bookmark list, so call it once that list is settled, fetched or
    /// kept.
    private func rejoinRooms(accountID: UUID) async {
        guard autoJoinEnabled else { return }
        let autoJoined = (bookmarksByAccount[accountID] ?? []).filter(\.autojoin).compactMap { BareJID.parse($0.jidString) }
        await chatService?.rejoinRooms(accountID: accountID, excluding: trackedRooms(accountID: accountID).union(autoJoined))
    }

    /// The rooms the room module already tracks, which a join must leave alone. A resumed stream carries its rooms
    /// over, and a fresh session starts with none.
    private func trackedRooms(accountID: UUID) -> Set<BareJID> {
        Set((accountService?.roomModule(for: accountID)?.roomOccupancies ?? [:]).keys)
    }

    @discardableResult
    private func upsertBookmark(_ bookmark: RoomBookmark, accountID: UUID) -> Bool {
        if let index = bookmarksByAccount[accountID]?.firstIndex(where: { $0.jidString == bookmark.jidString }) {
            bookmarksByAccount[accountID]?[index] = bookmark
            return false
        } else {
            bookmarksByAccount[accountID, default: []].append(bookmark)
            return true
        }
    }

    private func mapToRoomBookmark(_ bookmark: Bookmark) -> RoomBookmark {
        RoomBookmark(
            jidString: bookmark.jid.description,
            name: bookmark.name,
            autojoin: bookmark.autojoin,
            nickname: bookmark.nickname,
            password: bookmark.password
        )
    }
}
