import DuckoCore
import Logging
import SwiftUI
import UniformTypeIdentifiers

private let log = Logger(label: "im.ducko.ui.chatwindow")

@MainActor @Observable
public final class ChatWindowState {
    var conversation: Conversation?
    /// The loaded window: a run of the chat's stored messages, oldest first. Assigned only by `publish`.
    private(set) var messages: [ChatMessage] = []

    /// The timeline notes from the oldest loaded message on. Assigned only by `publish`.
    private(set) var notes: [TimelineNote] = []
    var isLoading = false

    /// Where the transcript is scrolled to. Kept here so the tab has its place back when it is selected again.
    let scroller = TranscriptScroller()
    let remoteImageConsent = RemoteImageConsent()

    var isAtNewest: Bool {
        scroller.isAtNewest
    }

    var timelineItems: [TimelineItem] {
        TimelineItem.merged(messages: messages, notes: notes)
    }

    // MARK: - Display

    /// The conversation as the service currently holds it (live), or `nil` when this
    /// tab's conversation isn't open. The value-type `conversation` copy is set once at
    /// `load()` and never refreshed, so it goes stale as unread, subject, and display
    /// fields change. `unreadCount`/`roomSubject` read this directly and surface `0`/`nil`
    /// once the conversation closes; only `displayName` (via `liveConversation`) keeps the
    /// last-known value as a fallback.
    private var serviceConversation: Conversation? {
        guard let id = conversation?.id else { return nil }
        return environment.chatService.openConversations.first { $0.id == id }
    }

    /// The live conversation, falling back to the value-type copy when this tab's
    /// conversation is no longer open (e.g. closed/destroyed) so the last-known display
    /// survives. For display reads only — routing uses the stable `conversation` copy directly.
    var liveConversation: Conversation? {
        serviceConversation ?? conversation
    }

    /// The contact as the roster holds it now, so a tab opened before the roster was loaded still gets its name.
    /// A room and a private chat within one have none, which is known once the conversation is loaded.
    var contact: Contact? {
        guard conversation?.isDirectChat != false, let accountID = resolvedAccountID else { return nil }
        return environment.rosterService.contact(jidString: jidString, accountID: accountID)
    }

    var displayName: String {
        liveConversation?.displayName ?? contact?.displayName ?? jidString
    }

    var unreadCount: Int {
        serviceConversation?.unreadCount ?? 0
    }

    var roomSubject: String? {
        serviceConversation?.roomSubject
    }

    /// The conversation as a Contact menu target; `nil` until `load()` resolves it.
    public var commandTarget: ContactCommandTarget? {
        guard let conversation = liveConversation else { return nil }
        return ContactCommandTarget(
            contactInfoRef: conversation.contactInfoRef,
            transcriptRef: ConversationRef(conversation: conversation),
            chatKey: ConversationKey(accountID: accountID, jid: jidString),
            contact: nil
        )
    }

    // MARK: - Composer Draft

    /// The composer's live text, retained per-tab so switching conversations in the
    /// single-window container neither bleeds the draft into another tab nor resets it.
    var draftText = ""

    // MARK: - Reply/Edit State

    var replyingTo: ChatMessage?
    var editingMessage: ChatMessage?

    // MARK: - Send Error

    /// Last send-side error message surfaced to the composer; cleared via `clearSendError()` or transparently on next successful send.
    var lastSendError: String?
    /// Body the user typed when the send threw, so `MessageInputView` can
    /// restore the composer text after a failed send. The composer clears
    /// `text` optimistically; this lets us put it back.
    var lastFailedSendBody: String?

    // MARK: - Attachments

    var pendingAttachments: [DraftAttachment] = []
    /// Whether the queued files go straight to the contact instead of being uploaded. Upload is preselected for every
    /// new batch.
    var sendsAttachmentsDirectly = false
    var isShowingFileImporter = false

    /// A direct transfer goes to one contact's device, so a room and a private chat within one only upload.
    var offersDirectTransfer: Bool {
        conversation?.isDirectChat == true
    }

    /// Encryption covers a chat's messages. A file is not encrypted on either way it can be sent: an upload is readable
    /// by the server that holds it, and a direct transfer by whatever its bytes pass through.
    var sendsFilesUnencryptedInEncryptedChat: Bool {
        liveConversation?.encryptionEnabled == true
    }

    /// The files this chat's contact is sending right now, each of which gets a row at the end of the timeline until
    /// its message replaces it. A room's occupant shares the room's address, so only a chat with one contact has them.
    var receivingTransfers: [FileTransferService.ActiveTransfer] {
        guard conversation?.isDirectChat == true, let accountID = resolvedAccountID else { return [] }
        return environment.fileTransferService.activeTransfers.filter { transfer in
            transfer.isReceiving && transfer.accountID == accountID && transfer.peerJIDString == jidString
        }
    }

    var canSendDirectly: Bool {
        guard let accountID = resolvedAccountID else { return false }
        return environment.fileTransferService.canSendDirectly(toJIDString: jidString, accountID: accountID)
    }

    /// The contact's online sessions, in the order the contact shows them.
    var contactOnlineResources: [String] {
        guard let accountID = resolvedAccountID else { return [] }
        return environment.presenceService.onlineResources(ofJIDString: jidString, accountID: accountID)
    }

    func refreshDirectTransferSupport() async {
        guard let accountID = resolvedAccountID else { return }
        await environment.fileTransferService.refreshDirectTransferSupport(forJIDString: jidString, accountID: accountID)
    }

    // MARK: - Groupchat

    var showParticipantSidebar = false

    var isGroupchat: Bool {
        conversation?.type == .groupchat
    }

    var myRoomRole: RoomRole? {
        guard isGroupchat,
              let nickname = liveConversation?.roomNickname,
              let accountID = resolvedAccountID else { return nil }
        let participants = environment.chatService.participants(forRoomJIDString: jidString, accountID: accountID)
        return participants.first { $0.nickname == nickname }?.role
    }

    // MARK: - Infinite Scroll

    var isLoadingOlder = false
    var hasReachedEnd = false
    /// Set when fetching older messages fails.
    var lastLoadHistoryError: String?

    // MARK: - Search

    var searchText = ""
    var isSearching = false
    var searchResults: [UUID] = []
    var currentSearchIndex = 0
    /// The text the results were found for. They and their highlight stay on it while the field is edited or emptied.
    private(set) var searchResultsQuery = ""

    var currentSearchResultID: UUID? {
        searchResults.indices.contains(currentSearchIndex) ? searchResults[currentSearchIndex] : nil
    }

    let jidString: String
    /// The account this tab is bound to, set at open time. Always non-nil in practice (every
    /// opened tab carries a real account); the `?? accounts.first?.id` fallbacks below are
    /// defensive only — there is no nil-account tab through which a live send could misroute.
    let accountID: UUID?
    private let environment: AppEnvironment

    init(jidString: String, accountID: UUID?, environment: AppEnvironment) {
        self.jidString = jidString
        self.accountID = accountID
        self.environment = environment
    }

    /// The account to route this tab's reads/sends through: the bound `accountID`, falling back
    /// to the first account only defensively (no live tab actually has a nil account).
    var resolvedAccountID: UUID? {
        accountID ?? environment.accountService.accounts.first?.id
    }

    // MARK: - Public API

    /// `shouldActivate` is checked right before this tab becomes the active conversation, so a load that finishes
    /// after the tab was deselected or closed doesn't re-point the active conversation.
    func load(shouldActivate: @MainActor () -> Bool = { true }) async {
        guard let accountID = resolvedAccountID else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let conv: Conversation
            if let slashIndex = jidString.firstIndex(of: "/"),
               jidString[..<slashIndex].contains("@") {
                // MUC PM: "room@conference/nick"
                let roomJIDString = String(jidString[..<slashIndex])
                let nickname = String(jidString[jidString.index(after: slashIndex)...])
                conv = try await environment.chatService.openMUCPMConversation(
                    roomJIDString: roomJIDString, nickname: nickname, accountID: accountID
                )
            } else {
                conv = try await environment.chatService.openConversation(jidString: jidString, accountID: accountID)
            }
            conversation = conv
            // From here on, whatever observes the conversation can ask for a refresh. The first fetch is therefore a
            // refresh itself, so one asked for meanwhile runs after it instead of being published over.
            await refreshMessages()
            guard shouldActivate() else { return }
            await environment.chatService.selectConversation(conv.id, accountID: accountID)
        } catch {
            // Conversation creation failed — leave state empty
        }
    }

    /// Reads the newest messages again and merges them into the window. A call made while one is running does not
    /// run beside it: the running one goes round once more when it is done.
    func refreshMessages() async {
        guard let conversationID = conversation?.id else { return }
        guard !isRefreshing else {
            needsAnotherRefresh = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            needsAnotherRefresh = false
            await refreshOnce(conversationID)
        } while needsAnotherRefresh
    }

    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var needsAnotherRefresh = false

    private func refreshOnce(_ conversationID: UUID) async {
        let chatService = environment.chatService
        let limit = max(MessageWindow.initialCount, min(messages.count + MessageWindow.pageSize, MessageWindow.refreshDepth))
        let reloaded = await (try? chatService.fetchMessageHistory(for: conversationID, before: nil, limit: limit)) ?? []
        let fetchedNotes = await chatService.fetchNotes(for: conversationID, since: reloaded.first?.timestamp)
        let loadedIDs = Set(messages.map(\.id))
        await loadStoredPreviews(for: reloaded.filter { !loadedIDs.contains($0.id) })

        // Older pages and scrolling interleave at every wait above. The window is therefore put together only now,
        // from the state as it is, with nothing waited for until it is published.
        let readingFrom = isAtNewest ? nil : messages.first
        let window = MessageWindow.refreshed(loaded: messages, reloaded: reloaded, isAtNewest: isAtNewest)
        publish(messages: window, fetchedNotes: fetchedNotes)
        // The reloaded messages no longer overlap the window, so it started over and what was being read is gone.
        if let readingFrom, !window.contains(where: { $0.id == readingFrom.id }) {
            scroller.scrollToNewest()
        }
    }

    /// The only place that assigns `messages` and `notes`, in one step, so the timeline is never seen with the
    /// messages of one fetch and the notes of another.
    private func publish(messages window: [ChatMessage], fetchedNotes: [TimelineNote]) {
        let fetchedNoteIDs = Set(fetchedNotes.map(\.id))
        var windowNotes = fetchedNotes + notes.filter { !fetchedNoteIDs.contains($0.id) }
        if let start = window.first?.timestamp {
            // A note older than everything loaded belongs with the older messages, which are not on screen.
            windowNotes.removeAll { $0.timestamp < start }
        }
        // A window that lost its oldest message starts later than it did, so what was the end of history is no longer.
        if let previousOldest = messages.first, !window.contains(where: { $0.id == previousOldest.id }) {
            hasReachedEnd = false
        }
        let windowIDs = Set(window.map(\.id))
        previewURLs = previewURLs.filter { windowIDs.contains($0.key) }

        messages = window
        notes = windowNotes
        refreshSearchResults()
        prefetchLinkPreviews()
    }

    func sendMessage(_ body: String) async {
        guard let accountID = resolvedAccountID else { return }
        // A new message is read where it lands. A correction stays where its message is.
        if editingMessage == nil {
            scroller.scrollToNewest()
        }

        do {
            if isGroupchat, let editing = editingMessage {
                try await environment.chatService.sendGroupCorrection(
                    original: editing,
                    inRoomJIDString: jidString,
                    newBody: body,
                    accountID: accountID
                )
            } else if isGroupchat {
                try await environment.chatService.sendGroupMessage(toJIDString: jidString, body: body, accountID: accountID)
            } else if let conv = conversation, let nick = conv.occupantNickname {
                // Routing reads the stable value-type copy, not `liveConversation`: the
                // identity (room JID, occupant nick) doesn't change, and a live lookup
                // could miss a conversation already removed from `openConversations`.
                try await environment.chatService.sendMUCPrivateMessage(
                    roomJIDString: conv.jid.description,
                    nickname: nick, body: body, accountID: accountID
                )
            } else if let editing = editingMessage {
                try await environment.chatService.sendCorrection(
                    original: editing,
                    toJIDString: jidString,
                    newBody: body,
                    accountID: accountID
                )
            } else if let replyTo = replyingTo, let stanzaID = replyTo.stanzaID {
                try await environment.chatService.sendReply(
                    toJIDString: jidString,
                    body: body,
                    replyToStanzaID: stanzaID,
                    accountID: accountID
                )
            } else {
                try await environment.chatService.sendMessage(toJIDString: jidString, body: body, accountID: accountID)
            }
            lastSendError = nil
            lastFailedSendBody = nil
            draftText = ""
        } catch let error as ChatService.ChatServiceError {
            // Typed failures surface to the composer and let it restore the body.
            lastSendError = error.localizedDescription
            lastFailedSendBody = body
            log.warning("Send failed: \(error.localizedDescription)")
        } catch {
            // Untyped send failures (network, etc.) leave messages as-is.
            log.warning("Send failed: \(error)")
        }

        cancelReplyOrEdit()
    }

    func clearSendError() {
        lastSendError = nil
        lastFailedSendBody = nil
    }

    func setRoomSubject(_ subject: String) async {
        guard let accountID = resolvedAccountID else { return }
        try? await environment.chatService.setRoomSubject(jidString: jidString, subject: subject, accountID: accountID)
    }

    func userIsTyping() async {
        guard let accountID = resolvedAccountID else { return }
        await environment.chatService.userIsTyping(inJIDString: jidString, accountID: accountID)
    }

    // MARK: - Reply/Edit

    func startReply(to message: ChatMessage) {
        editingMessage = nil
        replyingTo = message
    }

    func startEdit(of message: ChatMessage) {
        replyingTo = nil
        editingMessage = message
    }

    func cancelReplyOrEdit() {
        replyingTo = nil
        editingMessage = nil
    }

    // MARK: - Retraction

    func retractMessage(_ message: ChatMessage) async {
        // Preflight skip when the bubble has no stanzaID — never reached
        // the server, so retraction is a no-op even with the service guard.
        guard let accountID = resolvedAccountID,
              message.stanzaID != nil else { return }

        do {
            if isGroupchat {
                try await environment.chatService.retractGroupMessage(original: message, inRoomJIDString: jidString, accountID: accountID)
            } else {
                try await environment.chatService.retractMessage(original: message, toJIDString: jidString, accountID: accountID)
            }
            await refreshMessages()
        } catch {
            log.warning("Failed to retract message: \(error)")
        }
    }

    // MARK: - Moderation

    func moderateMessage(_ message: ChatMessage, reason: String?) async {
        guard let accountID = resolvedAccountID,
              let serverID = message.serverID else { return }

        do {
            try await environment.chatService.moderateMessage(
                serverID: serverID, inRoomJIDString: jidString, reason: reason, accountID: accountID
            )
            await refreshMessages()
        } catch {
            log.warning("Failed to moderate message: \(error)")
        }
    }

    // MARK: - Infinite Scroll

    /// Loads the page before the oldest loaded message from the store, asking the server archive first when the store
    /// has nothing older. The page is inserted once scrolling has come to rest. The call returns once the page is
    /// waiting for that, not once it is inserted.
    func loadOlderMessages() async {
        guard let conversationID = conversation?.id else { return }
        guard !isLoading, !isLoadingOlder, !hasReachedEnd else { return }

        isLoadingOlder = true
        do {
            guard let older = try await fetchOlderPage(conversationID) else {
                // The oldest loaded message is no longer stored, so the window itself is out of date.
                isLoadingOlder = false
                await refreshMessages()
                return
            }
            let chatService = environment.chatService
            let fetchedNotes = await chatService.fetchNotes(
                for: conversationID, since: older.page.first?.timestamp ?? older.anchor?.timestamp
            )
            await loadStoredPreviews(for: older.page)
            lastLoadHistoryError = nil
            scroller.performWhenAtRest { [weak self] in
                self?.insert(older, fetchedNotes: fetchedNotes)
            }
        } catch {
            log.warning("Failed to load older messages: \(error)")
            lastLoadHistoryError = error.localizedDescription
            isLoadingOlder = false
            // No refresh here, though an earlier answer of the server may have stored entries that are not shown yet:
            // new rows would have the list ask for a page again, and an archive that answers with entries and then
            // an error could keep that going without end. They show with the next refresh.
        }
    }

    private struct OlderPage {
        var page: [ChatMessage]
        /// The message the page was taken before.
        var anchor: ChatMessage?
        var addedFromServer = false
        var endsHistory = false
    }

    /// Run at rest, from the state as it is then. A page whose window was replaced meanwhile is dropped.
    private func insert(_ older: OlderPage, fetchedNotes: [TimelineNote]) {
        isLoadingOlder = false
        if messages.first?.id == older.anchor?.id {
            let loadedIDs = Set(messages.map(\.id))
            publish(messages: older.page.filter { !loadedIDs.contains($0.id) } + messages, fetchedNotes: fetchedNotes)
            if older.endsHistory {
                hasReachedEnd = true
            }
        }
        if older.addedFromServer {
            Task { await refreshMessages() }
        }
    }

    /// The cutoff of a fetch for what is older than the window: the start of the second after the oldest loaded
    /// message's. Stored timestamps are cut to the second while archive entries carry fractions, so the cutoff takes
    /// in the whole second. The page is then found by position.
    private var olderCutoff: Date? {
        messages.first.map { Date(timeIntervalSince1970: $0.timestamp.timeIntervalSince1970.rounded(.down) + 1) }
    }

    /// Returns nil when the oldest loaded message is no longer stored.
    private func fetchOlderPage(_ conversationID: UUID) async throws -> OlderPage? {
        guard var older = try await fetchStoredOlderPage(conversationID) else { return nil }
        guard older.page.isEmpty else { return older }
        guard let accountID = resolvedAccountID else {
            older.endsHistory = true
            return older
        }
        // The store has nothing older, so the server is asked. A round that adds nothing is the end, and a round that
        // stores older entries gives a page. A round can also add only entries that share the oldest loaded message's
        // second and sort after it. Those give no page, and the next round reads past them as duplicates. The rounds
        // are counted, so an archive that keeps adding such entries ends paging as well.
        for _ in 0 ..< MessageWindow.serverRounds {
            let (additions, _) = try await environment.chatService.fetchServerHistory(
                jidString: jidString, accountID: accountID, before: olderCutoff, limit: MessageWindow.pageSize
            )
            guard !additions.isEmpty else { break }
            guard var stored = try await fetchStoredOlderPage(conversationID) else { return nil }
            stored.addedFromServer = true
            if !stored.page.isEmpty { return stored }
            older = stored
        }
        older.endsHistory = true
        return older
    }

    /// The page before the window as the store has it, empty when the store has nothing older, and nil when the
    /// store no longer has the oldest loaded message.
    private func fetchStoredOlderPage(_ conversationID: UUID) async throws -> OlderPage? {
        var limit = 2 * MessageWindow.pageSize
        while true {
            let fetched = try await environment.chatService.fetchMessageHistory(for: conversationID, before: olderCutoff, limit: limit)
            let anchor = messages.first
            let page = MessageWindow.olderPage(before: messages, in: fetched)
            if let page, !page.isEmpty {
                return OlderPage(page: page, anchor: anchor)
            }
            // Only a fetch that came back short holds everything before the cutoff. A full one was cut off inside a
            // run of messages sharing the oldest loaded one's second.
            guard fetched.count == limit else {
                return page.map { OlderPage(page: $0, anchor: anchor) }
            }
            limit *= 2
        }
    }

    func clearLoadHistoryError() {
        lastLoadHistoryError = nil
    }

    // MARK: - Search

    func performSearch() {
        searchResultsQuery = searchText
        guard !searchText.isEmpty else {
            searchResults = []
            return
        }

        searchResults = searchMatches
        currentSearchIndex = searchResults.isEmpty ? 0 : searchResults.count - 1
        revealCurrentSearchResult()
    }

    func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex + 1) % searchResults.count
        revealCurrentSearchResult()
    }

    func previousSearchResult() {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex - 1 + searchResults.count) % searchResults.count
        revealCurrentSearchResult()
    }

    private var searchMatches: [UUID] {
        messages
            .filter { $0.matchesSearch(searchResultsQuery) }
            .map(\.id)
    }

    private func revealCurrentSearchResult() {
        guard let currentSearchResultID else { return }
        scroller.reveal(currentSearchResultID)
    }

    /// Results are ids of loaded messages, and a published window can have lost some. The current result stays
    /// selected while its message is loaded, and nothing is scrolled to.
    private func refreshSearchResults() {
        guard !searchResultsQuery.isEmpty else { return }
        let matches = searchMatches
        guard matches != searchResults else { return }
        let current = currentSearchResultID
        searchResults = matches
        currentSearchIndex = current.flatMap { matches.firstIndex(of: $0) } ?? min(currentSearchIndex, max(0, matches.count - 1))
    }

    func dismissSearch() {
        isSearching = false
        searchText = ""
        searchResultsQuery = ""
        searchResults = []
        currentSearchIndex = 0
    }

    public func toggleSearch() {
        if isSearching {
            dismissSearch()
        } else {
            isSearching = true
        }
    }

    // MARK: - Link Previews

    /// Prefetched previews by URL string. The service's cache is not observable, so reading this is what redraws a
    /// bubble once its preview arrives.
    private var prefetchedLinkPreviews: [String: LinkPreview] = [:]

    func linkPreview(for message: ChatMessage) -> LinkPreview? {
        guard let url = previewURL(of: message) else { return nil }
        return prefetchedLinkPreviews[url] ?? environment.linkPreviewService.cachedPreview(for: url)
    }

    /// The link each loaded message shows a preview for, and the body it was found in. Finding a link costs a pass
    /// of the link detector, which building the rows would otherwise repeat for every loaded message.
    @ObservationIgnored private var previewURLs: [UUID: (body: String, url: String?)] = [:]

    /// A body that only repeats an attachment's link has no preview: fetching one would request the file on sight,
    /// which is the attachment's decision to make.
    private func previewURL(of message: ChatMessage) -> String? {
        if let known = previewURLs[message.id], known.body == message.body { return known.url }
        let url = message.bodyIsAttachmentLink ? nil : Self.extractFirstURL(from: message.body)
        previewURLs[message.id] = (message.body, url)
        return url
    }

    private static let linkDetector: NSDataDetector = {
        do {
            return try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        } catch {
            fatalError("Failed to create link detector: \(error)")
        }
    }()

    private static func extractFirstURL(from body: String) -> String? {
        let range = NSRange(body.startIndex..., in: body)
        return linkDetector.firstMatch(in: body, range: range)?.url?.absoluteString
    }

    /// Fetches link previews for message URLs not yet in the service's cache.
    private func prefetchLinkPreviews() {
        let service = environment.linkPreviewService
        for message in messages {
            guard let urlString = previewURL(of: message),
                  service.cachedPreview(for: urlString) == nil,
                  let url = URL(string: urlString) else { continue }
            Task { [weak self] in
                guard let preview = try? await service.fetchPreview(for: url),
                      let self, prefetchedLinkPreviews[urlString] == nil else { return }
                prefetchedLinkPreviews[urlString] = preview
            }
        }
    }

    /// Reads the previews the store already has for `entering` into memory before their messages are published, so
    /// the rows are built with their previews and do not grow afterwards.
    private func loadStoredPreviews(for entering: [ChatMessage]) async {
        let service = environment.linkPreviewService
        for message in entering {
            guard let urlString = previewURL(of: message), service.cachedPreview(for: urlString) == nil else { continue }
            _ = await service.storedPreview(for: urlString)
        }
    }

    // MARK: - Attachments

    public func showFileImporter() {
        isShowingFileImporter = true
    }

    func addAttachment(url: URL) {
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

        let draft = DraftAttachment(
            url: url,
            fileName: url.lastPathComponent,
            mimeType: mimeType
        )
        if pendingAttachments.isEmpty {
            sendsAttachmentsDirectly = false
        }
        pendingAttachments.append(draft)
    }

    func loadFileURL(from provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            let url: URL? = if let data = item as? Data {
                URL(dataRepresentation: data, relativeTo: nil)
            } else if let nsURL = item as? URL {
                nsURL
            } else {
                nil
            }
            guard let url else { return }
            Task { @MainActor in
                self.addAttachment(url: url)
            }
        }
    }

    func removeAttachment(id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func clearAttachments() {
        pendingAttachments = []
    }

    func sendAttachments() async {
        guard let accountID = resolvedAccountID else { return }
        guard let conversation else { return }

        let attachmentsToSend = pendingAttachments
        let directly = sendsAttachmentsDirectly
        scroller.scrollToNewest()
        clearAttachments()
        lastSendError = nil

        let fileTransferService = environment.fileTransferService
        for attachment in attachmentsToSend {
            do {
                if directly {
                    // Returns once the file has its row in the chat, which reports how the transfer goes from there.
                    try await fileTransferService.startDirectTransfer(url: attachment.url, in: conversation, accountID: accountID)
                } else {
                    try await fileTransferService.sendFile(url: attachment.url, in: conversation, accountID: accountID)
                }
            } catch {
                lastSendError = error.localizedDescription
            }
        }
    }
}
