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

    public var bookmarks: [RoomBookmark] {
        bookmarksByAccount.values.flatMap(\.self)
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

    /// Drops one account's bookmarks on a lifecycle teardown that bypasses the `.disconnected` event handler
    /// (user-initiated `AccountService.disconnect`, account delete). Mirrors the `.disconnected` clear.
    func purgeAccount(_ accountID: UUID) {
        bookmarksByAccount.removeValue(forKey: accountID)
    }

    #if DEBUG
        /// Test seam: seeds per-account bookmarks without a live PEP fetch.
        func setBookmarksForTesting(_ bookmarks: [RoomBookmark], accountID: UUID) {
            bookmarksByAccount[accountID] = bookmarks
        }
    #endif

    // MARK: - Public API

    public func loadBookmarks(accountID: UUID) async {
        guard let client = accountService?.connectedClient(for: accountID) else { return }
        guard let pepModule = await client.module(ofType: PEPModule.self) else { return }

        do {
            let items = try await pepModule.retrieveItems(node: XMPPNamespaces.bookmarks2)
            let parsed = items.compactMap { Bookmark.parse(itemID: $0.id, payload: $0.payload) }
            // The same client must still be connected after the fetch: a disconnect/purge during the await
            // tore the account down, and republishing would resurrect a just-cleared account's bookmarks.
            guard accountService?.connectedClient(for: accountID) === client else { return }
            bookmarksByAccount[accountID] = parsed.map { mapToRoomBookmark($0) }
            await autojoinRooms(from: parsed, accountID: accountID)
        } catch {
            log.warning("Failed to load bookmarks: \(error.localizedDescription)")
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
            // Wait until initial presence + caps are on the wire before the bookmarks2 PEP fetch so the
            // server has seen this resource's caps first (XEP-0163 §3.3.2). Gating here rather than inside
            // `loadBookmarks` leaves the manual REPL `/bookmarks` refresh ungated.
            if let client = accountService?.connectedClient(for: accountID) {
                await client.awaitInitialPresenceSent()
            }
            await loadBookmarks(accountID: accountID)
            await rejoinRooms(accountID: accountID)
        case let .pepItemsPublished(from, node, items)
            where node == XMPPNamespaces.bookmarks2:
            await handleBookmarksPublished(from: from, items: items, accountID: accountID)
        case let .pepItemsRetracted(from, node, itemIDs)
            where node == XMPPNamespaces.bookmarks2:
            await handleBookmarksRetracted(from: from, itemIDs: itemIDs, accountID: accountID)
        case .disconnected:
            purgeAccount(accountID)
        case .streamResumed, .authenticationFailed,
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

    private func handleBookmarksPublished(from: BareJID, items: [PEPItem], accountID: UUID) async {
        // Only process our own bookmarks
        guard let account = accountService?.accounts.first(where: { $0.id == accountID }),
              from == account.jid else { return }

        let parsed = items.compactMap { Bookmark.parse(itemID: $0.id, payload: $0.payload) }

        var newBookmarks: [Bookmark] = []
        for bookmark in parsed {
            let roomBookmark = mapToRoomBookmark(bookmark)
            let isNew = upsertBookmark(roomBookmark, accountID: accountID)
            if isNew {
                newBookmarks.append(bookmark)
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

    private func autojoinRooms(from bookmarks: [Bookmark], accountID: UUID) async {
        guard autoJoinEnabled else { return }
        let account = accountService?.accounts.first(where: { $0.id == accountID })
        let fallbackNickname = account?.jid.localPart ?? ""

        for bookmark in bookmarks where bookmark.autojoin {
            let nickname = bookmark.nickname ?? fallbackNickname
            guard !nickname.isEmpty else { continue }
            try? await chatService?.joinRoom(
                jid: bookmark.jid,
                nickname: nickname,
                password: bookmark.password,
                accountID: accountID
            )
        }
    }

    /// Rejoins the rooms the user is in that no auto-join bookmark covers, where auto-join is on. Call it after the
    /// bookmark fetch, whether or not that succeeded: the fetch has already joined the rooms with such a bookmark.
    private func rejoinRooms(accountID: UUID) async {
        guard autoJoinEnabled else { return }
        let autoJoined = (bookmarksByAccount[accountID] ?? []).filter(\.autojoin).compactMap { BareJID.parse($0.jidString) }
        await chatService?.rejoinRooms(accountID: accountID, excluding: Set(autoJoined))
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
