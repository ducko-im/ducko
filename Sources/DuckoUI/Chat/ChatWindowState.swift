import DuckoCore
import Logging
import SwiftUI
import UniformTypeIdentifiers

private let log = Logger(label: "im.ducko.ui.chatwindow")

@MainActor @Observable
public final class ChatWindowState {
    var conversation: Conversation?
    var contact: Contact?
    var messages: [ChatMessage] = [] {
        didSet { prefetchLinkPreviews() }
    }

    /// The timeline notes from the oldest loaded message on.
    var notes: [TimelineNote] = []
    var isLoading = false

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

    var isContactTyping: Bool {
        environment.chatService.isPartnerTyping(jidString: jidString, accountID: accountID)
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
                contact = environment.rosterService.contact(jidString: jidString, accountID: accountID)
            }
            conversation = conv
            messages = await environment.chatService.loadMessages(for: conv.id)
            await loadNotes()
            guard shouldActivate() else { return }
            await environment.chatService.selectConversation(conv.id, accountID: accountID)
        } catch {
            // Conversation creation failed — leave state empty
        }
    }

    func refreshMessages() async {
        guard let conversationID = conversation?.id else { return }
        messages = await environment.chatService.loadMessages(for: conversationID)
        await loadNotes()
    }

    private func loadNotes() async {
        guard let conversationID = conversation?.id else { return }
        notes = await environment.chatService.fetchNotes(for: conversationID, since: messages.first?.timestamp)
    }

    func sendMessage(_ body: String) async {
        guard let accountID = resolvedAccountID else { return }

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

    func loadOlderMessages() async {
        guard let conversationID = conversation?.id else { return }
        guard !isLoadingOlder, !hasReachedEnd else { return }

        isLoadingOlder = true
        defer { isLoadingOlder = false }

        do {
            let older = try await environment.chatService.fetchMessageHistory(
                for: conversationID,
                before: messages.first?.timestamp,
                limit: 50
            )

            if older.isEmpty {
                // Local store exhausted — try server
                guard let accountID = resolvedAccountID else {
                    hasReachedEnd = true
                    return
                }
                let (serverMessages, hasMore) = try await environment.chatService.fetchServerHistory(
                    jidString: jidString,
                    accountID: accountID,
                    before: messages.first?.timestamp,
                    limit: 50
                )
                if serverMessages.isEmpty {
                    hasReachedEnd = true
                } else {
                    messages = serverMessages + messages
                    if !hasMore {
                        hasReachedEnd = true
                    }
                }
            } else {
                messages = older + messages
            }
            await loadNotes()
            lastLoadHistoryError = nil
        } catch {
            log.warning("Failed to load older messages: \(error)")
            lastLoadHistoryError = error.localizedDescription
        }
    }

    func clearLoadHistoryError() {
        lastLoadHistoryError = nil
    }

    // MARK: - Search

    func performSearch() {
        guard !searchText.isEmpty else {
            searchResults = []
            return
        }

        searchResults = messages
            .filter { $0.body.localizedStandardContains(searchText) }
            .map(\.id)
        currentSearchIndex = searchResults.isEmpty ? 0 : searchResults.count - 1
    }

    func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex + 1) % searchResults.count
    }

    func previousSearchResult() {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex - 1 + searchResults.count) % searchResults.count
    }

    func dismissSearch() {
        isSearching = false
        searchText = ""
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
        guard let url = Self.previewURL(of: message) else { return nil }
        return prefetchedLinkPreviews[url] ?? environment.linkPreviewService.cachedPreview(for: url)
    }

    /// A body that only repeats an attachment's link has no preview: fetching one would request the file on sight,
    /// which is the attachment's decision to make.
    private static func previewURL(of message: ChatMessage) -> String? {
        message.bodyIsAttachmentLink ? nil : extractFirstURL(from: message.body)
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
            guard let urlString = Self.previewURL(of: message),
                  service.cachedPreview(for: urlString) == nil,
                  let url = URL(string: urlString) else { continue }
            Task { [weak self] in
                guard let preview = try? await service.fetchPreview(for: url),
                      let self, prefetchedLinkPreviews[urlString] == nil else { return }
                prefetchedLinkPreviews[urlString] = preview
            }
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
