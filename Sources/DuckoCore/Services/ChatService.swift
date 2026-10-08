// Split candidate.
// swiftlint:disable file_length
import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.chat")

@MainActor @Observable
public final class ChatService { // swiftlint:disable:this type_body_length
    public private(set) var openConversations: [Conversation] = []
    /// Per-account conversation cache. `openConversations` is the rebuilt union of every slot,
    /// so a fetch/refresh on one account never drops another account's conversations. Stays the
    /// source of truth behind the published union — mutate slots and call `rebuildOpenConversations()`.
    private var conversationsByAccount: [UUID: [Conversation]] = [:]
    public private(set) var activeConversationID: UUID?
    public private(set) var messages: [ChatMessage] = []
    /// Incoming typing state keyed by account, then peer — the same peer JID on two accounts
    /// must light up only the account that received the `composing`.
    public private(set) var typingStates: [UUID: [BareJID: ChatState]] = [:]
    public var pendingInvites: [PendingRoomInvite] {
        roomService.pendingInvites
    }

    /// Per-conversation revision tick. The chat view observes via `.onChange` to refresh after amendments
    /// (corrections, retractions, markers) — these don't bump `lastMessageDate`.
    public private(set) var messagesRevisions: [UUID: Int] = [:]
    public var onIncomingMessage: ((ChatMessage, Conversation) -> Void)?
    public var onHeadlineMessage: (@Sendable (XMPPMessage) -> Void)?

    private let store: any PersistenceStore
    private let transcripts: any TranscriptStore
    private let filterPipeline: MessageFilterPipeline
    private weak var accountService: AccountService?
    private weak var omemoService: OMEMOService?
    private var typingDebounce: [UUID: [BareJID: Task<Void, Never>]] = [:]
    /// Fire-and-forget MAM sync tasks that outlive the
    /// call that spawned them. Drained by `AppEnvironment.shutdown(within:)` so they can't race transcript
    /// teardown; each task removes its own handle on completion via `defer`.
    private var pendingTasks: [UUID: Task<Void, Never>] = [:]
    /// Per-account map of the peer's most-recently-seen full-JID resource for live 1:1 chats
    /// (RFC 6121 §5.1 resource locking). Account-scoped — the same bare peer JID can exist under
    /// multiple accounts. Internal routing state, not observed UI state, so kept `private`.
    private var lockedResourcesByAccount: [UUID: [BareJID: String]] = [:]
    /// Arrival sequence (from `nextLockSequence`) of the inbound that currently owns each peer's lock.
    /// Guards against an arrival-older message overwriting a newer lock when the per-event handler Tasks
    /// resume on the MainActor out of order.
    private var lockSequenceByPeer: [UUID: [BareJID: UInt64]] = [:]
    private var nextInboundLockSequence: UInt64 = 0
    /// Chats whose encryption a contact's message is switching on right now.
    private var encryptionSwitchesInFlight: Set<UUID> = []
    /// The message each conversation's last displayed marker named, so looking at an unchanged chat again does not
    /// send the contact the same marker again.
    private var lastDisplayedMarkerSent: [UUID: UUID] = [:]
    /// Registry of pending room-join waiters keyed by `(accountID, room)`.
    var roomJoinNotifiers: [RoomJoinKey: RoomJoinNotifier] {
        roomService.roomJoinNotifiers
    }

    @ObservationIgnored private lazy var roomService = RoomService(
        store: store,
        ensureConversation: { [weak self] room, nickname, accountID in
            guard let self else { throw CancellationError() }
            _ = try await findOrCreateGroupConversation(for: room, nickname: nickname, accountID: accountID)
        },
        conversation: { [weak self] room, accountID in
            self?.openConversations.first { $0.jid == room && $0.type == .groupchat && $0.accountID == accountID }
        },
        didUpdateConversation: { [weak self] conversation in self?.updateCachedConversation(conversation) }
    )

    public init(store: any PersistenceStore, transcripts: any TranscriptStore, filterPipeline: MessageFilterPipeline) {
        self.store = store
        self.transcripts = transcripts
        self.filterPipeline = filterPipeline
    }

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
        roomService.setAccountService(service)
    }

    func setOMEMOService(_ service: OMEMOService) {
        omemoService = service
    }

    // MARK: - Shutdown

    /// Returns the in-flight fire-and-forget task handles and clears the stores, so
    /// `AppEnvironment.shutdown(within:)` can cancel and bounded-await a captured snapshot.
    /// Synchronous: it neither cancels nor awaits — that is the caller's job.
    func takePendingTasks() -> [Task<Void, Never>] {
        var tasks = Array(pendingTasks.values) + roomService.takePendingTasks()
        pendingTasks.removeAll()
        for perJID in typingDebounce.values {
            tasks.append(contentsOf: perJID.values)
        }
        typingDebounce.removeAll()
        return tasks
    }

    #if DEBUG
        /// Test seam: lets `shutdown` draining run against a task of controlled duration.
        func registerPendingTaskForTesting(_ task: Task<Void, Never>) {
            pendingTasks[UUID()] = task
        }
    #endif

    // MARK: - Resource Locking (RFC 6121 §5.1)

    /// Resolves the recipient for a 1:1 send: the locked full JID when a resource is locked for `jid`,
    /// otherwise the bare JID. Single decision point for full-vs-bare so the fallback rule lives in one place.
    private func recipientJID(for jid: BareJID, accountID: UUID) -> JID {
        guard let resource = lockedResourcesByAccount[accountID]?[jid],
              let fullJID = FullJID(bareJID: jid, resourcePart: resource) else {
            return .bare(jid)
        }
        return .full(fullJID)
    }

    /// The resource the contact last wrote from, while it is still online.
    func lockedResource(for jid: BareJID, accountID: UUID) -> String? {
        lockedResourcesByAccount[accountID]?[jid]
    }

    /// Releases the lock for `jid`, so subsequent sends fall back to the bare JID.
    private func clearLock(for jid: BareJID, accountID: UUID) {
        lockedResourcesByAccount[accountID]?.removeValue(forKey: jid)
    }

    /// Drops every lock for `accountID`. Peer-resource locks are meaningless once our own session ends.
    private func clearLocks(accountID: UUID) {
        lockedResourcesByAccount.removeValue(forKey: accountID)
        lockSequenceByPeer.removeValue(forKey: accountID)
    }

    /// Returns a monotonic arrival tick. Captured synchronously at an inbound handler's entry (before any
    /// await) so `learnResourceLock` can reject out-of-order learns when interleaved per-event Tasks resume
    /// on the MainActor in a different order than the messages arrived. Internal so `OMEMOService` can call it.
    func nextLockSequence() -> UInt64 {
        defer { nextInboundLockSequence &+= 1 }
        return nextInboundLockSequence
    }

    /// Learns the peer's resource from an accepted live 1:1 inbound message (plaintext or OMEMO).
    /// A full `from` locks (re-locking when the resource differs; `FullJID` guarantees a non-empty resource);
    /// a bare `from` releases the lock (RFC 6121 §5.1: a message from the bare JID releases it). `sequence` is
    /// the inbound's arrival tick — an arrival-older learn (lower sequence) is dropped so it can't overwrite a
    /// newer lock. Internal so `OMEMOService` can call it, mirroring `persistEncryptedMessage`.
    func learnResourceLock(from: JID, accountID: UUID, sequence: UInt64) {
        // A groupchat/MUC sender (room@conference/nick) must never move the 1:1 lock. The plaintext path
        // routes room messages to separate handlers, but the OMEMO event carries no message type, so guard
        // here with the same groupchat-conversation check `shouldSkipRawMessage` uses.
        let bareJID = from.bareJID
        if openConversations.contains(where: { $0.jid == bareJID && $0.type == .groupchat && $0.accountID == accountID }) { return }
        if let owning = lockSequenceByPeer[accountID]?[bareJID], sequence < owning { return }
        lockSequenceByPeer[accountID, default: [:]][bareJID] = sequence
        switch from {
        case let .full(fullJID):
            lockedResourcesByAccount[accountID, default: [:]][bareJID] = fullJID.resourcePart
        case .bare:
            clearLock(for: bareJID, accountID: accountID)
        }
    }

    /// RFC 6121 §5.1: releases the lock when the *locked* resource goes unavailable. Available presence does
    /// not move the lock; an unavailable presence from a non-locked resource is ignored.
    private func handlePresenceForResourceLock(from: JID, presence: XMPPPresence, accountID: UUID) {
        guard presence.presenceType == .unavailable, case let .full(fullJID) = from else { return }
        if lockedResourcesByAccount[accountID]?[fullJID.bareJID] == fullJID.resourcePart {
            clearLock(for: fullJID.bareJID, accountID: accountID)
        }
    }

    // MARK: - Public API

    public func loadConversations(for accountID: UUID) async throws {
        try await setConversations(store.fetchConversations(for: accountID), for: accountID)
    }

    /// Replaces one account's cached conversations and republishes the union. The single place
    /// a wholesale per-account fetch result lands so cross-account derived reads stay current.
    private func setConversations(_ conversations: [Conversation], for accountID: UUID) {
        conversationsByAccount[accountID] = conversations
        rebuildOpenConversations()
    }

    /// Replaces a single conversation in its owning account's slot and republishes. Mutating only
    /// the union would be transient — the next rebuild from another slot resurrects the stale value.
    private func updateCachedConversation(_ conversation: Conversation) {
        guard let accountID = conversation.accountID,
              let index = conversationsByAccount[accountID]?.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversationsByAccount[accountID]?[index] = conversation
        rebuildOpenConversations()
    }

    /// Drops a single conversation from its owning account's slot and republishes. The no-op
    /// guard keeps the union rebuild off the hot path when the id isn't cached (e.g. a destroyed
    /// room that was never open).
    private func removeCachedConversation(id: UUID, accountID: UUID) {
        guard conversationsByAccount[accountID]?.contains(where: { $0.id == id }) == true else { return }
        conversationsByAccount[accountID]?.removeAll { $0.id == id }
        rebuildOpenConversations()
    }

    /// Rebuilds the published `openConversations` as the union of every cached account slot, sorted
    /// most-recent-first to match the per-account `store.fetchConversations` order (a bare
    /// `Dictionary.values` union has no defined order, which would reshuffle the rooms list on every
    /// rebuild). `openConversations` stays a stored property so `@Observable` change-tracking and the
    /// ID-based single-element lookups keep working.
    private func rebuildOpenConversations() {
        openConversations = conversationsByAccount.values.flatMap(\.self)
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastMessageDate ?? .distantPast
                let rhsDate = rhs.lastMessageDate ?? .distantPast
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                // Deterministic tie-breakers so equal/nil dates (e.g. fresh, message-less
                // conversations) don't inherit the undefined `Dictionary.values` order and reshuffle.
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    public func sendMessage(to jid: BareJID, body: String, accountID: UUID, attachments: [Attachment] = []) async throws {
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let chatModule = await client.module(ofType: ChatModule.self) else { return }

        let filtered = await filterBody(body, direction: .outgoing, accountID: accountID, fallback: jid)

        let conversation = try await findOrCreateConversation(for: jid, accountID: accountID)
        let stanzaID = client.generateID()
        let trustedDeviceIDs = try await trustedDeviceIDsForSend(
            jid: jid, accountID: accountID, conversation: conversation
        )

        // Persist before sending so the server's carbon copy finds the stanzaID
        // via isDuplicate and is correctly skipped. Without this, handleCarbon
        // can persist a duplicate before persistMessage runs.
        let message = ChatMessage(
            id: UUID(), conversationID: conversation.id, stanzaID: stanzaID,
            fromJID: jid.description, body: filtered.body, htmlBody: filtered.htmlBody,
            timestamp: Date(), isOutgoing: true, isDelivered: false, isEdited: false,
            type: "chat", isEncrypted: trustedDeviceIDs != nil, attachments: attachments
        )
        try await persistMessage(message, in: conversation, accountID: accountID)

        do {
            try await dispatchSend(SendDispatchContext(
                jid: jid, filteredBody: filtered.body, stanzaID: stanzaID,
                trustedDeviceIDs: trustedDeviceIDs, accountID: accountID,
                chatModule: chatModule, additionalElements: attachments.map(Self.oobElement)
            ))
        } catch {
            await appendFailedSendRetract(message, stanzaID: stanzaID, conversationID: conversation.id)
            throw error
        }
    }

    /// Appends a local-only retract for an optimistic message whose network send failed, so the ghost row
    /// doesn't linger in the transcript. The retract has no server effect — the message never reached it.
    /// Callers re-throw the original send error after calling this.
    private func appendFailedSendRetract(_ message: ChatMessage, stanzaID: String, conversationID: UUID) async {
        try? await transcripts.appendAmendment(
            TranscriptAmendment(action: .retract, targetMessageID: message.id, targetStanzaID: stanzaID, timestamp: Date()),
            conversationID: conversationID
        )
        await messagesChanged(in: conversationID)
    }

    /// Resolves encryption for `sendMessage` and converts fail-closed resolutions into typed throws.
    /// Returns trusted device IDs or nil for user-opted-out plaintext.
    private func trustedDeviceIDsForSend(
        jid: BareJID, accountID: UUID, conversation: Conversation
    ) async throws -> [UInt32]? {
        let resolution = await resolveEncryption(
            jid: jid, accountID: accountID,
            conversationEncryptionEnabled: conversation.encryptionEnabled
        )
        switch resolution {
        case let .proceed(ids): return ids
        case .userDisabled: return nil
        case .noLocalDevicesForPeer: throw ChatServiceError.omemoNoLocalDevices(conversationJID: jid)
        case .noTrustedDevicesForPeer: throw ChatServiceError.omemoNoTrustedDevices(conversationJID: jid)
        case .serviceUnavailable: throw ChatServiceError.omemoServiceUnavailable(conversationJID: jid)
        }
    }

    private struct SendDispatchContext {
        let jid: BareJID
        let filteredBody: String
        let stanzaID: String
        let trustedDeviceIDs: [UInt32]?
        let accountID: UUID
        let chatModule: ChatModule
        let additionalElements: [DuckoXMPP.XMLElement]
    }

    /// Sends a 1:1 stanza; encrypts when `trustedDeviceIDs` is non-nil. Branches on `trustedDeviceIDs` (not on
    /// `omemoService`) because `trustedDeviceIDsForSend` only returns nil on intentional `.userDisabled` —
    /// folding `omemoService` into the optional-binding would silently downgrade to plaintext when the service is unwired.
    private func dispatchSend(_ context: SendDispatchContext) async throws {
        let recipient = recipientJID(for: context.jid, accountID: context.accountID)
        let chatStatesEnabled = ChatPreferences.shared.enableChatStates
        guard let trustedDeviceIDs = context.trustedDeviceIDs else {
            try await context.chatModule.sendMessage(
                to: recipient, body: context.filteredBody, id: context.stanzaID,
                requestReceipt: true, markable: true,
                includeChatState: chatStatesEnabled,
                additionalElements: context.additionalElements
            )
            return
        }
        guard let omemoService else {
            // Unreachable in production: `resolveEncryption` returns
            // `.serviceUnavailable` (→ `trustedDeviceIDsForSend` throws)
            // when the service is nil. Defense in depth — if a future
            // refactor lets a nil service slip past the resolution gate,
            // fail closed instead of silently downgrading.
            throw ChatServiceError.omemoServiceUnavailable(conversationJID: context.jid)
        }
        let elements = try await omemoService.encryptMessage(
            body: context.filteredBody, to: context.jid,
            trustedDeviceIDs: trustedDeviceIDs, accountID: context.accountID
        )
        let storeHint = DuckoXMPP.XMLElement(name: "store", namespace: XMPPNamespaces.processingHints)
        try await context.chatModule.sendMessage(
            to: recipient, body: elements.fallbackBody, id: context.stanzaID,
            requestReceipt: true, markable: true, includeChatState: chatStatesEnabled,
            additionalElements: [elements.encrypted, elements.encryption, storeHint]
        )
    }

    /// XEP-0066: the element that lets other clients render the message as a file attachment.
    private static func oobElement(for attachment: Attachment) -> DuckoXMPP.XMLElement {
        var oobX = DuckoXMPP.XMLElement(name: "x", namespace: XMPPNamespaces.oob)
        oobX.setChildText(named: "url", to: attachment.url)
        return oobX
    }

    public func selectConversation(_ id: UUID?, accountID: UUID? = nil) async {
        let previousID = activeConversationID
        activeConversationID = id
        guard let id else {
            messages = []
            return
        }
        let loaded = await loadMessages(for: id)
        // A later selection, or the chat going out of view, took over during the load. It owns `messages` now, and
        // this one must not mark a chat read that nobody is looking at any more.
        guard activeConversationID == id else { return }
        messages = loaded
        // Only bump when the active conversation actually changed: re-selecting
        // the same conversation is a no-op for observers, and the unconditional
        // bump triggered a redundant `windowState.refreshMessages()` round-trip.
        if previousID != id {
            bumpRevision(for: id)
        }
        try? await store.markConversationRead(id)
        if let accountID {
            await republishConversations(for: accountID)
            await sendDisplayedMarkerForLatest(conversationID: id, accountID: accountID)
        }
    }

    public func openConversation(for jid: BareJID, accountID: UUID) async throws -> Conversation {
        let conversation = try await findOrCreateConversation(for: jid, accountID: accountID)
        try await setConversations(store.fetchConversations(for: accountID), for: accountID)
        return conversation
    }

    public func openConversation(jidString: String, accountID: UUID) async throws -> Conversation {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        return try await openConversation(for: jid, accountID: accountID)
    }

    /// The user's own switch. Switching it off also keeps a contact's encrypted message from switching it back on.
    public func setEncryptionEnabled(_ enabled: Bool, for conversationID: UUID, accountID: UUID) async throws {
        try await mutateConversation(conversationID, accountID: accountID) {
            $0.encryptionEnabled = enabled
            $0.encryptionOptedOut = !enabled
        }
    }

    /// Switches a 1:1 chat's encryption on because the contact sent an encrypted message, so the reply is not sent in
    /// the clear. Leaves a note in the timeline saying so, and does nothing once the user has switched it off.
    func enableEncryptionForContact(in conversationID: UUID, accountID: UUID) async {
        // Each event runs in its own task, so the messages of a burst can all get here before the first one's switch is
        // stored. Only the first goes on: the rest would each leave a note of their own.
        guard let conversation = openConversations.first(where: { $0.id == conversationID }),
              conversation.isDirectChat, !conversation.encryptionEnabled, !conversation.encryptionOptedOut,
              encryptionSwitchesInFlight.insert(conversationID).inserted else { return }
        defer { encryptionSwitchesInFlight.remove(conversationID) }
        do {
            // Decided again on the row as it is stored: the copy above can be older than a switch-off the user made a
            // moment ago, and that one holds.
            let stored = try await store.updateConversation(conversationID) {
                guard !$0.encryptionEnabled, !$0.encryptionOptedOut else { return }
                $0.encryptionEnabled = true
            }
            try await setConversations(store.fetchConversations(for: accountID), for: accountID)
            guard let stored, stored.encryptionEnabled, !stored.encryptionOptedOut else { return }
        } catch {
            log.warning("Could not switch encryption on after an encrypted message: \(error)")
            return
        }
        do {
            try await transcripts.appendNote(TimelineNote(conversationID: conversationID, kind: .encryptionEnabledByContact))
        } catch {
            log.warning("Could not note that encryption was switched on: \(error)")
        }
        bumpRevision(for: conversationID)
    }

    /// Persists an encrypted message received via OMEMO. Called by OMEMOService.
    func persistEncryptedMessage(_ message: ChatMessage, in conversation: Conversation, accountID: UUID) async {
        await persistAndNotify(message, in: conversation, accountID: accountID)
    }

    public func sendMessage(toJIDString jidString: String, body: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await sendMessage(to: jid, body: body, accountID: accountID)
    }

    // MARK: - Typing

    public func userIsTyping(in jid: BareJID, accountID: UUID) async {
        guard ChatPreferences.shared.enableChatStates else { return }
        guard let client = accountService?.connectedClient(for: accountID) else { return }
        guard let module = await client.module(ofType: ChatStatesModule.self) else { return }

        typingDebounce[accountID]?[jid]?.cancel()
        try? await module.sendChatState(.composing, to: recipientJID(for: jid, accountID: accountID))
        typingDebounce[accountID, default: [:]][jid] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            try? await module.sendChatState(.paused, to: recipientJID(for: jid, accountID: accountID))
            typingDebounce[accountID]?[jid] = nil
        }
    }

    public func userIsTyping(inJIDString jidString: String, accountID: UUID) async {
        guard let jid = BareJID.parse(jidString) else { return }
        await userIsTyping(in: jid, accountID: accountID)
    }

    public func isPartnerTyping(jidString: String, accountID: UUID?) -> Bool {
        guard let accountID, let jid = BareJID.parse(jidString) else { return false }
        return typingStates[accountID]?[jid] == .composing
    }

    // MARK: - Corrections

    /// Sends an XEP-0308 correction for `original` and appends the matching
    /// local edit amendment. Caller passes the already-resolved `ChatMessage`
    /// so the service never re-resolves by stanzaID — per-session `ducko-N`
    /// counters can collide with peers or with MAM-imported messages of
    /// prior sessions, and a re-lookup may pick an incoming row instead.
    public func sendCorrection(
        original: ChatMessage,
        to jid: BareJID,
        newBody: String,
        accountID: UUID
    ) async throws {
        guard original.isOutgoing, let originalStanzaID = original.stanzaID else {
            throw ChatServiceError.notOutgoingMessage
        }
        let conversation = try await findOrCreateConversation(for: jid, accountID: accountID)
        // Reject mismatched destination — a caller that passes a message
        // from conversation A while addressing JID B would otherwise route
        // the network stanza to B while writing the local amendment under A,
        // splitting the transcript from the wire.
        guard original.conversationID == conversation.id else {
            throw ChatServiceError.notOutgoingMessage
        }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let chatModule = await client.module(ofType: ChatModule.self) else { return }

        let chatStatesEnabled = ChatPreferences.shared.enableChatStates

        let filtered = await filterBody(newBody, direction: .outgoing, accountID: accountID, fallback: jid)

        let resolution = await resolveEncryption(
            jid: jid, accountID: accountID, conversationEncryptionEnabled: conversation.encryptionEnabled
        )
        switch resolution {
        case let .proceed(trustedDeviceIDs):
            guard let omemoService else {
                // Unreachable in production: `resolveEncryption` returns
                // `.serviceUnavailable` when the service is nil. Defense in
                // depth.
                throw ChatServiceError.omemoServiceUnavailable(conversationJID: jid)
            }
            let elements = try await omemoService.encryptMessage(body: filtered.body, to: jid, trustedDeviceIDs: trustedDeviceIDs, accountID: accountID)
            let replaceElement = DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": originalStanzaID])
            let storeHint = DuckoXMPP.XMLElement(name: "store", namespace: XMPPNamespaces.processingHints)
            try await chatModule.sendMessage(
                to: recipientJID(for: jid, accountID: accountID), body: elements.fallbackBody, id: client.generateID(),
                includeChatState: chatStatesEnabled,
                additionalElements: [elements.encrypted, elements.encryption, storeHint, replaceElement]
            )
        case .userDisabled:
            try await chatModule.sendCorrection(to: recipientJID(for: jid, accountID: accountID), body: filtered.body, replacingID: originalStanzaID, includeChatState: chatStatesEnabled)
        case .noLocalDevicesForPeer:
            throw ChatServiceError.omemoNoLocalDevices(conversationJID: jid)
        case .noTrustedDevicesForPeer:
            throw ChatServiceError.omemoNoTrustedDevices(conversationJID: jid)
        case .serviceUnavailable:
            throw ChatServiceError.omemoServiceUnavailable(conversationJID: jid)
        }
        try await transcripts.appendAmendment(
            TranscriptAmendment(action: .edit, targetMessageID: original.id, targetStanzaID: originalStanzaID, timestamp: Date(), body: filtered.body, htmlBody: filtered.htmlBody),
            conversationID: conversation.id
        )
        await messagesChanged(in: conversation.id)
    }

    public func sendCorrection(
        original: ChatMessage,
        toJIDString jidString: String,
        newBody: String,
        accountID: UUID
    ) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await sendCorrection(original: original, to: jid, newBody: newBody, accountID: accountID)
    }

    // MARK: - Group Corrections

    public func sendGroupCorrection(original: ChatMessage, in room: BareJID, newBody: String, accountID: UUID) async throws {
        guard original.isOutgoing, let originalStanzaID = original.stanzaID else {
            throw ChatServiceError.notOutgoingMessage
        }
        let conversation = try await findOrCreateGroupConversation(for: room, nickname: nil, accountID: accountID)
        guard original.conversationID == conversation.id else {
            throw ChatServiceError.notOutgoingMessage
        }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }

        let filtered = await filterBody(newBody, direction: .outgoing, accountID: accountID, fallback: room)

        let replaceElement = DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": originalStanzaID])
        _ = try await encryptAndSendGroupMessage(
            room: room, body: filtered.body, stanzaID: client.generateID(),
            conversation: conversation, mucModule: mucModule,
            additionalElements: [replaceElement]
        )
        try await transcripts.appendAmendment(
            TranscriptAmendment(action: .edit, targetMessageID: original.id, targetStanzaID: originalStanzaID, timestamp: Date(), body: filtered.body, htmlBody: filtered.htmlBody),
            conversationID: conversation.id
        )
        await messagesChanged(in: conversation.id)
    }

    public func sendGroupCorrection(original: ChatMessage, inRoomJIDString roomJIDString: String, newBody: String, accountID: UUID) async throws {
        guard let room = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        try await sendGroupCorrection(original: original, in: room, newBody: newBody, accountID: accountID)
    }

    // MARK: - Retractions

    public func retractMessage(original: ChatMessage, to jid: BareJID, accountID: UUID) async throws {
        guard original.isOutgoing, let stanzaID = original.stanzaID else {
            throw ChatServiceError.notOutgoingMessage
        }
        let conversation = try await findOrCreateConversation(for: jid, accountID: accountID)
        guard original.conversationID == conversation.id else {
            throw ChatServiceError.notOutgoingMessage
        }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let chatModule = await client.module(ofType: ChatModule.self) else { return }

        let resolution = await resolveEncryption(
            jid: jid, accountID: accountID, conversationEncryptionEnabled: conversation.encryptionEnabled
        )
        switch resolution {
        case let .proceed(trustedDeviceIDs):
            guard let omemoService else {
                throw ChatServiceError.omemoServiceUnavailable(conversationJID: jid)
            }
            let elements = try await omemoService.encryptMessage(body: retractionFallbackBody, to: jid, trustedDeviceIDs: trustedDeviceIDs, accountID: accountID)
            let retractElement = DuckoXMPP.XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": stanzaID])
            let fallbackElement = DuckoXMPP.XMLElement(name: "fallback", namespace: XMPPNamespaces.fallbackIndication, attributes: ["for": XMPPNamespaces.messageRetract])
            let storeHint = DuckoXMPP.XMLElement(name: "store", namespace: XMPPNamespaces.processingHints)
            try await chatModule.sendMessage(
                to: recipientJID(for: jid, accountID: accountID), body: elements.fallbackBody, id: client.generateID(),
                includeChatState: false,
                additionalElements: [elements.encrypted, elements.encryption, storeHint, retractElement, fallbackElement]
            )
        case .userDisabled:
            try await chatModule.sendRetraction(to: recipientJID(for: jid, accountID: accountID), originalID: stanzaID)
        case .noLocalDevicesForPeer:
            throw ChatServiceError.omemoNoLocalDevices(conversationJID: jid)
        case .serviceUnavailable:
            throw ChatServiceError.omemoServiceUnavailable(conversationJID: jid)
        case .noTrustedDevicesForPeer:
            throw ChatServiceError.omemoNoTrustedDevices(conversationJID: jid)
        }
        try await transcripts.appendAmendment(
            TranscriptAmendment(action: .retract, targetMessageID: original.id, targetStanzaID: stanzaID, timestamp: Date()),
            conversationID: conversation.id
        )
        await messagesChanged(in: conversation.id)
    }

    public func retractMessage(original: ChatMessage, toJIDString jidString: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await retractMessage(original: original, to: jid, accountID: accountID)
    }

    public func retractGroupMessage(original: ChatMessage, inRoomJIDString roomJIDString: String, accountID: UUID) async throws {
        guard let room = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        try await retractGroupMessage(original: original, in: room, accountID: accountID)
    }

    public func retractGroupMessage(original: ChatMessage, in room: BareJID, accountID: UUID) async throws {
        guard original.isOutgoing, let stanzaID = original.stanzaID else {
            throw ChatServiceError.notOutgoingMessage
        }
        let conversation = try await findOrCreateGroupConversation(for: room, nickname: nil, accountID: accountID)
        guard original.conversationID == conversation.id else {
            throw ChatServiceError.notOutgoingMessage
        }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }

        let retractElement = DuckoXMPP.XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": stanzaID])
        let fallbackElement = DuckoXMPP.XMLElement(name: "fallback", namespace: XMPPNamespaces.fallbackIndication, attributes: ["for": XMPPNamespaces.messageRetract])
        _ = try await encryptAndSendGroupMessage(
            room: room, body: retractionFallbackBody, stanzaID: client.generateID(),
            conversation: conversation, mucModule: mucModule,
            additionalElements: [retractElement, fallbackElement]
        )
        try await transcripts.appendAmendment(
            TranscriptAmendment(action: .retract, targetMessageID: original.id, targetStanzaID: stanzaID, timestamp: Date()),
            conversationID: conversation.id
        )
        await messagesChanged(in: conversation.id)
    }

    public func moderateMessage(serverID: String, inRoomJIDString roomJIDString: String, reason: String?, accountID: UUID) async throws {
        guard let room = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        try await moderateMessage(serverID: serverID, in: room, reason: reason, accountID: accountID)
    }

    public func moderateMessage(serverID: String, in room: BareJID, reason: String?, accountID: UUID) async throws {
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }

        try await mucModule.moderateMessage(room: room, stanzaID: serverID, reason: reason)
        if let conversationID = await conversationID(for: .bare(room), accountID: accountID) {
            try await transcripts.appendAmendment(
                TranscriptAmendment(action: .retract, targetServerID: serverID, timestamp: Date()),
                conversationID: conversationID
            )
            await messagesChanged(in: conversationID)
        }
    }

    // MARK: - Replies

    public func sendReply(
        to jid: BareJID,
        body: String,
        replyToStanzaID: String,
        accountID: UUID
    ) async throws {
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let chatModule = await client.module(ofType: ChatModule.self) else { return }

        let filtered = await filterBody(body, direction: .outgoing, accountID: accountID, fallback: jid)

        let stanzaID = client.generateID()

        // Resolve the conversation so the reply runs through `shouldEncrypt`
        // and matches `sendMessage`'s encryption decision for the same peer —
        // bypassing this is a silent-downgrade vector.
        let conversation = try await findOrCreateConversation(for: jid, accountID: accountID)
        try await dispatchReply(ReplyDispatchContext(
            jid: jid, filteredBody: filtered.body, stanzaID: stanzaID,
            replyToStanzaID: replyToStanzaID, accountID: accountID,
            conversation: conversation, chatModule: chatModule
        ))

        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: stanzaID,
            fromJID: jid.description,
            body: filtered.body,
            htmlBody: filtered.htmlBody,
            timestamp: Date(),
            isOutgoing: true,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            replyToID: replyToStanzaID
        )
        try await persistMessage(message, in: conversation, accountID: accountID)
    }

    private struct ReplyDispatchContext {
        let jid: BareJID
        let filteredBody: String
        let stanzaID: String
        let replyToStanzaID: String
        let accountID: UUID
        let conversation: Conversation
        let chatModule: ChatModule
    }

    /// Resolves encryption and dispatches the reply on the chosen path.
    private func dispatchReply(_ context: ReplyDispatchContext) async throws {
        let chatStatesEnabled = ChatPreferences.shared.enableChatStates
        let resolution = await resolveEncryption(
            jid: context.jid, accountID: context.accountID,
            conversationEncryptionEnabled: context.conversation.encryptionEnabled
        )
        switch resolution {
        case let .proceed(trustedDeviceIDs):
            guard let omemoService else {
                throw ChatServiceError.omemoServiceUnavailable(conversationJID: context.jid)
            }
            let elements = try await omemoService.encryptMessage(
                body: context.filteredBody, to: context.jid,
                trustedDeviceIDs: trustedDeviceIDs, accountID: context.accountID
            )
            let replyElement = DuckoXMPP.XMLElement(
                name: "reply", namespace: XMPPNamespaces.messageReply,
                attributes: ["to": context.jid.description, "id": context.replyToStanzaID]
            )
            let storeHint = DuckoXMPP.XMLElement(name: "store", namespace: XMPPNamespaces.processingHints)
            try await context.chatModule.sendMessage(
                to: recipientJID(for: context.jid, accountID: context.accountID), body: elements.fallbackBody, id: context.stanzaID,
                requestReceipt: true, markable: true, includeChatState: chatStatesEnabled,
                additionalElements: [elements.encrypted, elements.encryption, storeHint, replyElement]
            )
        case .userDisabled:
            try await context.chatModule.sendReply(
                to: recipientJID(for: context.jid, accountID: context.accountID),
                body: context.filteredBody, replyToID: context.replyToStanzaID,
                replyToJID: .bare(context.jid), id: context.stanzaID,
                includeChatState: chatStatesEnabled
            )
        case .noLocalDevicesForPeer:
            throw ChatServiceError.omemoNoLocalDevices(conversationJID: context.jid)
        case .noTrustedDevicesForPeer:
            throw ChatServiceError.omemoNoTrustedDevices(conversationJID: context.jid)
        case .serviceUnavailable:
            throw ChatServiceError.omemoServiceUnavailable(conversationJID: context.jid)
        }
    }

    public func sendReply(
        toJIDString jidString: String,
        body: String,
        replyToStanzaID: String,
        accountID: UUID
    ) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await sendReply(to: jid, body: body, replyToStanzaID: replyToStanzaID, accountID: accountID)
    }

    // MARK: - Markers

    public func sendDisplayedMarker(
        to jid: BareJID,
        messageStanzaID: String,
        accountID: UUID,
        messageType: DuckoXMPP.XMPPMessage.MessageType = .chat
    ) async throws {
        guard ChatPreferences.shared.enableDisplayedMarkers else { return }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let module = await client.module(ofType: ReceiptsModule.self) else { return }
        // Resolve the locked full JID only for 1:1 chat markers; groupchat markers stay addressed to the room.
        let recipient: JID = messageType == .chat ? recipientJID(for: jid, accountID: accountID) : .bare(jid)
        try await module.sendDisplayedMarker(to: recipient, messageID: messageStanzaID, messageType: messageType)
    }

    // MARK: - Private: Displayed Markers

    private func sendDisplayedMarkerForLatest(conversationID: UUID, accountID: UUID) async {
        guard let conversation = openConversations.first(where: { $0.id == conversationID }) else { return }

        // `messages` holds whichever conversation was selected last, which is another one by now when a later
        // selection overtook this one.
        let received = messages.filter { $0.conversationID == conversationID && !$0.isOutgoing }
        switch conversation.type {
        case .chat:
            guard let message = received.last(where: { $0.stanzaID != nil }) else { return }
            await sendDisplayedMarkerIfNeeded(for: message, in: conversation, accountID: accountID)
        case .groupchat:
            guard let message = received.last(where: { $0.serverID != nil }) else { return }
            await sendDisplayedMarkerIfNeeded(for: message, in: conversation, accountID: accountID)
        }
    }

    private func sendDisplayedMarkerIfNeeded(for message: ChatMessage, in conversation: Conversation, accountID: UUID) async {
        let markedID: String
        let messageType: XMPPMessage.MessageType
        switch conversation.type {
        case .chat:
            guard let stanzaID = message.stanzaID else { return }
            (markedID, messageType) = (stanzaID, .chat)
        case .groupchat:
            guard let serverID = message.serverID,
                  let client = accountService?.connectedClient(for: accountID),
                  let mucModule = await client.module(ofType: MUCModule.self),
                  mucModule.nickname(in: conversation.jid) != nil else { return }
            (markedID, messageType) = (serverID, .groupchat)
        }
        // A marker says the chat is being looked at, which is decided here, once, after every wait that takes real time.
        // Remembered by the message itself, not by the id the marker names: another client can use that id again for
        // a later message. And remembered before the send, so a second look during it does not send the marker twice.
        guard ChatPreferences.shared.enableDisplayedMarkers, activeConversationID == conversation.id,
              lastDisplayedMarkerSent[conversation.id] != message.id else { return }
        lastDisplayedMarkerSent[conversation.id] = message.id
        do {
            try await sendDisplayedMarker(to: conversation.jid, messageStanzaID: markedID, accountID: accountID, messageType: messageType)
        } catch {
            if lastDisplayedMarkerSent[conversation.id] == message.id {
                lastDisplayedMarkerSent[conversation.id] = nil
            }
        }
    }

    // MARK: - MUC

    public func joinRoom(jid: BareJID, nickname: String, password: String? = nil, accountID: UUID) async throws {
        try await roomService.joinRoom(jid: jid, nickname: nickname, password: password, accountID: accountID)
    }

    /// Joins `jid` and awaits the matching `.roomJoined` self-presence echo. Notifier registers BEFORE join is sent so the echo cannot race ahead.
    /// Throws `.timeout(jid)` if the echo doesn't arrive within `timeout`; rethrows `joinRoom` errors after cleanup.
    /// With `remember`, the room is joined again on later connects. Without it, whether the room is rejoined stays
    /// as it was.
    public func joinRoomAwaitingEcho(
        jid: BareJID,
        nickname: String,
        password: String? = nil,
        accountID: UUID,
        timeout: Duration = .seconds(5),
        remember: Bool = true
    ) async throws {
        try await roomService.joinRoomAwaitingEcho(
            jid: jid, nickname: nickname, password: password, accountID: accountID, timeout: timeout, remember: remember
        )
    }

    /// String overload of `joinRoomAwaitingEcho(jid:…)`. Throws `.invalidJID` on parse failure.
    public func joinRoomAwaitingEcho(
        jidString: String,
        nickname: String,
        password: String? = nil,
        accountID: UUID,
        timeout: Duration = .seconds(5),
        remember: Bool = true
    ) async throws {
        try await roomService.joinRoomAwaitingEcho(
            jidString: jidString, nickname: nickname, password: password, accountID: accountID, timeout: timeout, remember: remember
        )
    }

    /// Atomically registers a one-shot notifier for the next `.roomJoined` matching `(accountID, jid)`. Synchronous + MainActor
    /// so registration lands BEFORE any await — the self-presence echo cannot race ahead.
    func registerRoomJoinNotifier(jid: BareJID, accountID: UUID) -> (id: UUID, stream: AsyncStream<Void>) {
        roomService.registerRoomJoinNotifier(jid: jid, accountID: accountID)
    }

    /// Identity-aware cleanup; no-ops when the slot now holds a different id. Idempotent.
    func clearRoomJoinNotifier(jid: BareJID, accountID: UUID, id: UUID) {
        roomService.clearRoomJoinNotifier(jid: jid, accountID: accountID, id: id)
    }

    /// Returns `true` only on stream yield; timeout / no-yield → `false`.
    func awaitRoomJoinedEcho(stream: AsyncStream<Void>, timeout: Duration) async -> Bool {
        await roomService.awaitRoomJoinedEcho(stream: stream, timeout: timeout)
    }

    /// With `forget`, the room is not joined again on later connects. Without it, whether the room is rejoined stays
    /// as it was.
    public func leaveRoom(jid: BareJID, accountID: UUID, forget: Bool = true) async throws {
        try await roomService.leaveRoom(jid: jid, accountID: accountID, forget: forget)
    }

    func rejoinRooms(accountID: UUID, excluding skipped: Set<BareJID>) async {
        await roomService.rejoinRooms(accountID: accountID, excluding: skipped)
    }

    public func sendGroupMessage(to room: BareJID, body: String, accountID: UUID, attachments: [Attachment] = []) async throws {
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }

        let conversation = try await findOrCreateGroupConversation(for: room, nickname: nil, accountID: accountID)
        let filtered = await filterBody(body, direction: .outgoing, accountID: accountID, fallback: room)

        let stanzaID = client.generateID()
        // Resolve encryption before persisting so a "no trusted devices" throw leaves nothing persisted
        // (mirrors 1:1). Only the transport send sits inside the do/catch rollback below.
        let prepared = try await prepareGroupMessage(
            room: room, body: filtered.body, conversation: conversation, additionalElements: attachments.map(Self.oobElement)
        )

        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: stanzaID,
            fromJID: room.description,
            body: filtered.body,
            htmlBody: filtered.htmlBody,
            timestamp: Date(),
            isOutgoing: true,
            isDelivered: false,
            isEdited: false,
            type: "groupchat",
            isEncrypted: prepared.isEncrypted,
            attachments: attachments
        )
        try await persistMessage(message, in: conversation, accountID: accountID)

        // Persist-before-send: roll back with a local retract if the send fails, so a transport error
        // doesn't leave a ghost message that the server never received. The nickname guard in
        // `handleRoomMessageReceived` already prevents the room's echo from double-counting this row.
        do {
            try await sendPreparedGroupMessage(prepared, room: room, stanzaID: stanzaID, mucModule: mucModule)
        } catch {
            await appendFailedSendRetract(message, stanzaID: stanzaID, conversationID: conversation.id)
            throw error
        }
    }

    public func joinRoom(jidString: String, nickname: String, password: String? = nil, accountID: UUID) async throws {
        try await roomService.joinRoom(jidString: jidString, nickname: nickname, password: password, accountID: accountID)
    }

    public func leaveRoom(jidString: String, accountID: UUID, forget: Bool = true) async throws {
        try await roomService.leaveRoom(jidString: jidString, accountID: accountID, forget: forget)
    }

    public func sendGroupMessage(toJIDString jidString: String, body: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await sendGroupMessage(to: jid, body: body, accountID: accountID)
    }

    public func sendMUCPrivateMessage(roomJIDString: String, nickname: String, body: String, accountID: UUID) async throws {
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        guard let nickname = FullJID.normalizeResourcePart(nickname) else { throw ChatServiceError.invalidJID(nickname) }

        let filtered = await filterBody(body, direction: .outgoing, accountID: accountID, fallback: roomJID)

        let conversation = try await findOrCreateMUCPMConversation(for: roomJID, nickname: nickname, accountID: accountID)
        let stanzaID = client.generateID()

        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: stanzaID,
            fromJID: nickname,
            body: filtered.body,
            htmlBody: filtered.htmlBody,
            timestamp: Date(),
            isOutgoing: true,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
        try await persistMessage(message, in: conversation, accountID: accountID)

        // Persist-before-send + retract-on-failure (MUC PMs aren't echoed back to the sender, so the
        // optimistic row is never doubled).
        do {
            try await mucModule.sendPrivateMessage(to: roomJID, nickname: nickname, body: filtered.body, id: stanzaID)
        } catch {
            await appendFailedSendRetract(message, stanzaID: stanzaID, conversationID: conversation.id)
            throw error
        }
    }

    public func openMUCPMConversation(roomJIDString: String, nickname: String, accountID: UUID) async throws -> Conversation {
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let nickname = FullJID.normalizeResourcePart(nickname) else { throw ChatServiceError.invalidJID(nickname) }
        let conversation = try await findOrCreateMUCPMConversation(for: roomJID, nickname: nickname, accountID: accountID)
        try await setConversations(store.fetchConversations(for: accountID), for: accountID)
        return conversation
    }

    private func roomMemberJIDs(roomJIDString: String, accountID: UUID) async throws -> [BareJID] {
        try await roomService.roomMemberJIDs(roomJIDString: roomJIDString, accountID: accountID)
    }

    // MARK: - MUC Bridge

    public func participantGroups(forRoomJIDString jidString: String, accountID: UUID) -> [RoomParticipantGroup] {
        roomService.participantGroups(forRoomJIDString: jidString, accountID: accountID)
    }

    public func participantCount(forRoomJIDString jidString: String, accountID: UUID) -> Int {
        roomService.participantCount(forRoomJIDString: jidString, accountID: accountID)
    }

    public func participants(forRoomJIDString jidString: String, accountID: UUID) -> [RoomParticipant] {
        roomService.participants(forRoomJIDString: jidString, accountID: accountID)
    }

    /// Active room flags for the room under `accountID`, or an empty set when none are known.
    public func roomFlags(forRoomJIDString jidString: String, accountID: UUID) -> Set<RoomFlag> {
        roomService.roomFlags(forRoomJIDString: jidString, accountID: accountID)
    }

    /// Whether the room under `accountID` was just created (locked, awaiting initial config).
    public func isRoomNewlyCreated(jidString: String, accountID: UUID) -> Bool {
        roomService.isRoomNewlyCreated(jidString: jidString, accountID: accountID)
    }

    /// Domain parts of every room `accountID` currently occupies. Used by
    /// `DuckoCLI.handleSendCommand` to distinguish "unjoined-room" hints from
    /// 1:1 sends.
    public func knownRoomDomains(accountID: UUID) -> Set<String> {
        roomService.knownRoomDomains(accountID: accountID)
    }

    public func discoverMUCService(accountID: UUID) async -> String? {
        await roomService.discoverMUCService(accountID: accountID)
    }

    public func discoverRooms(on service: String, accountID: UUID) async throws -> [DiscoveredRoom] {
        try await roomService.discoverRooms(on: service, accountID: accountID)
    }

    /// Searches for public channels via XEP-0433 Extended Channel Search.
    public func searchChannels(
        keyword: String,
        accountID: UUID,
        after: String? = nil
    ) async throws -> ChannelSearchResult {
        try await roomService.searchChannels(keyword: keyword, accountID: accountID, after: after)
    }

    public func setRoomSubject(jidString: String, subject: String, accountID: UUID) async throws {
        try await roomService.setRoomSubject(jidString: jidString, subject: subject, accountID: accountID)
    }

    public func inviteUser(jidString: String, toRoomJIDString roomJIDString: String, reason: String?, password: String? = nil, accountID: UUID) async throws {
        try await roomService.inviteUser(jidString: jidString, toRoomJIDString: roomJIDString, reason: reason, password: password, accountID: accountID)
    }

    public func kickOccupant(nickname: String, fromRoomJIDString roomJIDString: String, reason: String?, accountID: UUID) async throws {
        try await roomService.kickOccupant(nickname: nickname, fromRoomJIDString: roomJIDString, reason: reason, accountID: accountID)
    }

    public func banUser(jidString: String, fromRoomJIDString roomJIDString: String, reason: String?, accountID: UUID) async throws {
        try await roomService.banUser(jidString: jidString, fromRoomJIDString: roomJIDString, reason: reason, accountID: accountID)
    }

    public func grantVoice(nickname: String, inRoomJIDString roomJIDString: String, accountID: UUID) async throws {
        try await roomService.grantVoice(nickname: nickname, inRoomJIDString: roomJIDString, accountID: accountID)
    }

    public func revokeVoice(nickname: String, inRoomJIDString roomJIDString: String, accountID: UUID) async throws {
        try await roomService.revokeVoice(nickname: nickname, inRoomJIDString: roomJIDString, accountID: accountID)
    }

    public func changeRoomNickname(jidString: String, newNickname: String, accountID: UUID) async throws {
        try await roomService.changeRoomNickname(jidString: jidString, newNickname: newNickname, accountID: accountID)
    }

    public func getRoomConfig(jidString: String, accountID: UUID) async throws -> [RoomConfigField] {
        try await roomService.getRoomConfig(jidString: jidString, accountID: accountID)
    }

    public func submitRoomConfig(jidString: String, fields: [RoomConfigField], accountID: UUID) async throws {
        try await roomService.submitRoomConfig(jidString: jidString, fields: fields, accountID: accountID)
    }

    public func getAffiliationList(
        affiliation: RoomAffiliation,
        inRoomJIDString roomJIDString: String,
        accountID: UUID
    ) async throws -> [RoomAffiliationItem] {
        try await roomService.getAffiliationList(affiliation: affiliation, inRoomJIDString: roomJIDString, accountID: accountID)
    }

    public func setAffiliation(
        jidString: String,
        inRoomJIDString roomJIDString: String,
        to affiliation: RoomAffiliation,
        reason: String? = nil,
        accountID: UUID
    ) async throws {
        try await roomService.setAffiliation(jidString: jidString, inRoomJIDString: roomJIDString, to: affiliation, reason: reason, accountID: accountID)
    }

    public func destroyRoom(jid: BareJID, reason: String? = nil, accountID: UUID) async throws {
        try await roomService.destroyRoom(jid: jid, reason: reason, accountID: accountID)
    }

    public func destroyRoom(jidString: String, reason: String? = nil, accountID: UUID) async throws {
        try await roomService.destroyRoom(jidString: jidString, reason: reason, accountID: accountID)
    }

    public func acceptInvite(_ invite: PendingRoomInvite, nickname: String, accountID: UUID) async throws {
        try await roomService.acceptInvite(invite, nickname: nickname, accountID: accountID)
    }

    public func declineInvite(_ invite: PendingRoomInvite, reason: String? = nil, accountID: UUID) async throws {
        try await roomService.declineInvite(invite, reason: reason, accountID: accountID)
    }

    public func clearNewlyCreatedRoom(_ jidString: String, accountID: UUID) {
        roomService.clearNewlyCreatedRoom(jidString, accountID: accountID)
    }

    // MARK: - Pin/Mute

    public func togglePin(conversationID: UUID, accountID: UUID) async throws {
        try await mutateConversation(conversationID, accountID: accountID) { $0.isPinned.toggle() }
    }

    public func toggleMute(conversationID: UUID, accountID: UUID) async throws {
        try await mutateConversation(conversationID, accountID: accountID) { $0.isMuted.toggle() }
    }

    /// Changes a stored conversation and publishes the result. `mutate` runs on the row as it is stored, so a change
    /// made here never writes back fields that a message arriving at the same moment has just updated.
    private func mutateConversation(
        _ conversationID: UUID,
        accountID: UUID,
        _ mutate: @Sendable (inout Conversation) -> Void
    ) async throws {
        try await store.updateConversation(conversationID, mutate)
        try await setConversations(store.fetchConversations(for: accountID), for: accountID)
    }

    public enum ChatServiceError: Error, LocalizedError {
        case invalidJID(String)
        case notConnected(UUID)
        case encryptionFailed(String)
        case notOutgoingMessage
        case timeout(BareJID)
        /// Conversation has encryption enabled but the local trust store has
        /// no devices for the peer (no `+notify`, peer has no OMEMO, fresh
        /// install). Surfaced to the UI so the composer text is retained
        /// instead of silently downgrading to plaintext.
        case omemoNoLocalDevices(conversationJID: BareJID)
        /// Conversation has encryption enabled and peer devices exist
        /// locally, but none are trusted.
        case omemoNoTrustedDevices(conversationJID: BareJID)
        /// Encryption enabled but OMEMO service unavailable (not connected, module rebuild in progress).
        /// Thrown from both 1:1 and group send paths; the parameter is `conversationJID` (peer or room).
        case omemoServiceUnavailable(conversationJID: BareJID)
        /// Group conversation has encryption enabled but every occupant
        /// resolves to `omemoNoLocalDevices` or `omemoNoTrustedDevices`.
        case omemoNoTrustedDevicesInRoom(roomJID: BareJID, untrustedJIDs: [BareJID])

        public var errorDescription: String? {
            switch self {
            case let .invalidJID(string): "Invalid JID: \(string)"
            case .notConnected: notConnectedDescription
            case let .encryptionFailed(reason): "Encryption failed: \(reason)"
            case .notOutgoingMessage: "Cannot correct a message that was not sent by you"
            case let .timeout(jid): "Timed out waiting for room \(jid) join echo"
            case .omemoNoLocalDevices:
                "Cannot send: no OMEMO devices known for this contact. The contact may not have OMEMO set up, or you have not received their device list yet."
            case .omemoNoTrustedDevices:
                "Cannot send: no trusted devices for this contact. Verify a device fingerprint first."
            case .omemoServiceUnavailable:
                "Cannot send: encryption service unavailable. Try reconnecting."
            case .omemoNoTrustedDevicesInRoom:
                "Cannot send: room has no occupants with trusted devices."
            }
        }
    }

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case let .messageReceived(xmppMessage):
            await handleMessageReceived(xmppMessage, accountID: accountID)
        case let .messageCarbonReceived(forwarded): await handleCarbon(forwarded, accountID: accountID, isOutgoing: false)
        case let .messageCarbonSent(forwarded): await handleCarbon(forwarded, accountID: accountID, isOutgoing: true)
        case let .deliveryReceiptReceived(messageID, from):
            await handleDeliveryReceipt(messageID: messageID, from: from, accountID: accountID)
        case let .chatMarkerReceived(messageID, markerType, from):
            await handleChatMarker(messageID: messageID, type: markerType, from: from, accountID: accountID)
        case let .chatStateChanged(from, chatState):
            handleChatStateChanged(from: from, state: chatState, accountID: accountID)
        case let .messageCorrected(id, body, from): await handleMessageCorrected(originalID: id, newBody: body, from: from, accountID: accountID)
        case let .messageRetracted(id, from): await handleMessageRetracted(originalID: id, from: from, accountID: accountID)
        case let .messageModerated(id, _, room, _): await handleMessageModerated(originalID: id, room: room, accountID: accountID)
        case let .messageError(id, from, error): await handleMessageError(messageID: id, errorText: error.displayText, from: from, accountID: accountID)
        case let .rosterUpdated(update):
            if update.isInitialResponse { startRecentHistorySync(accountID: accountID) }
        case let .presenceUpdated(from, presence):
            handlePresenceForResourceLock(from: from, presence: presence, accountID: accountID)
        case let .roomJoined(room, occupancy, created): await roomService.handleRoomJoined(room: room, occupancy: occupancy, isNewlyCreated: created, accountID: accountID)
        case let .roomOccupantJoined(room, occupant): roomService.handleRoomOccupantJoined(room: room, occupant: occupant, accountID: accountID)
        case let .roomOccupantLeft(room, occupant, reason): await roomService.handleRoomOccupantLeft(room: room, occupant: occupant, reason: reason, accountID: accountID)
        case let .roomOccupantNickChanged(room, old, occupant): roomService.handleRoomOccupantNickChanged(room: room, oldNickname: old, occupant: occupant, accountID: accountID)
        case let .roomSubjectChanged(room, subject, _): await handleRoomSubjectChanged(room: room, subject: subject, accountID: accountID)
        case let .roomInviteReceived(invite): roomService.handleRoomInviteReceived(invite, accountID: accountID)
        case let .roomMessageReceived(message): await handleRoomMessageReceived(message, accountID: accountID)
        case let .mucPrivateMessageReceived(message): await handleMUCPrivateMessageReceived(message, accountID: accountID)
        case let .roomDestroyed(room, _, _): await handleRoomDestroyed(room: room, accountID: accountID)
        case let .mucSelfPingFailed(room, reason): await roomService.handleMUCSelfPingFailed(room: room, reason: reason, accountID: accountID)
        case .connected: roomService.clearPendingLeaves(accountID: accountID)
        case .streamResumed: roomService.handleStreamResumed(accountID: accountID)
        case let .disconnected(reason): handleMUCDisconnect(reason: reason, accountID: accountID)
        case .authenticationFailed,
             .presenceReceived, .iqReceived,
             .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .archivedMessagesLoaded,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .jingleChecksumReceived,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced, .omemoRecipientsPartial,
             .oobIQOfferReceived, .serviceOutageReceived:
            break
        }
    }

    /// Clears the blip-safe live state (locks/typing/rooms) on every disconnect, scoped to the disconnecting
    /// account so a global `removeAll` can't erase other still-connected accounts' rooms. Drops pending invites
    /// and pending leaves only on intentional `.requested` teardown; a `streamError`/`connectionLost`/`redirect`
    /// blip preserves them.
    private func handleMUCDisconnect(reason: DisconnectReason, accountID: UUID) {
        if case .requested = reason {
            purgeAccount(accountID)
        } else {
            clearLiveChatState(for: accountID)
        }
    }

    // MARK: - Private: Event Handlers

    private func handleDeliveryReceipt(messageID: String, from: JID, accountID: UUID) async {
        guard let conversationID = await conversation(forSender: from, accountID: accountID)?.id,
              await amendSentMessage(stanzaID: messageID, in: conversationID, { TranscriptAmendment(action: .delivery, targetMessageID: $0) })
        else { return }
        await messagesChanged(in: conversationID)
    }

    /// Amends the message this account sent under `stanzaID`. Returns `false`, having written nothing, when it sent
    /// none.
    private func amendSentMessage(stanzaID: String, in conversationID: UUID, _ amendment: (UUID) -> TranscriptAmendment) async -> Bool {
        let recent = await (try? transcripts.fetchMessages(for: conversationID, before: nil, limit: Self.sentLookback)) ?? []
        guard let message = await sentMessage(stanzaID: stanzaID, among: recent, in: conversationID) else { return false }
        try? await transcripts.appendAmendment(amendment(message.id), conversationID: conversationID)
        return true
    }

    /// The message this account sent under `stanzaID`: the newest such among `recent`, else the newest in the whole
    /// transcript. Only sent messages match, since every client numbers its own stanzas and a received message can
    /// carry the same stanza id.
    private func sentMessage(stanzaID: String, among recent: [ChatMessage], in conversationID: UUID) async -> ChatMessage? {
        if let message = recent.first(where: { $0.isOutgoing && $0.stanzaID == stanzaID }) { return message }
        let older = try? await transcripts.findMessages(stanzaID: stanzaID, conversationID: conversationID)
        return older?.filter(\.isOutgoing).max { $0.timestamp < $1.timestamp }
    }

    private func handleChatMarker(messageID: String, type: ChatMarkerType, from: JID, accountID: UUID) async {
        guard type == .displayed else { return }
        guard let conversation = await conversation(forSender: from, accountID: accountID) else { return }
        if conversation.isDirectChat {
            guard await markDisplayed(upTo: messageID, in: conversation.id) else { return }
        } else {
            // In a room, one occupant's marker says nothing about the others, so it counts as a delivery there, and so
            // it does in a private chat with one of the room's occupants.
            try? await transcripts.appendAmendment(
                TranscriptAmendment(action: .delivery, targetStanzaID: messageID),
                conversationID: conversation.id
            )
        }
        await messagesChanged(in: conversation.id)
    }

    /// How many of a chat's newest messages, received ones included, a sent message is looked up in, and a displayed
    /// marker is carried back through.
    private static let sentLookback = 200

    /// Marks the sent message a displayed marker names as read, and the ones sent before it: a marker covers every
    /// message up to the one it names (XEP-0333). Messages already read are left alone, which makes a repeated marker
    /// a no-op. Beyond the lookback, only the named message is marked and the rest keep the mark they have. Returns
    /// whether any message was marked.
    private func markDisplayed(upTo stanzaID: String, in conversationID: UUID) async -> Bool {
        guard let recent = try? await transcripts.fetchMessages(for: conversationID, before: nil, limit: Self.sentLookback),
              let named = await sentMessage(stanzaID: stanzaID, among: recent, in: conversationID) else { return false }
        // Newest first, so the messages sent before the named one follow it.
        let covered = recent.firstIndex { $0.id == named.id }.map { Array(recent[$0...]) } ?? [named]
        // A marker speaks only for messages the contact received: one that failed, and a directly sent file, which has
        // no stanza, keep their own outcome. A read message does not end the walk, since an older one can turn up
        // behind it later, when the archive delivers what another of the user's devices sent.
        let unread = covered.filter { $0.isOutgoing && $0.stanzaID != nil && $0.errorText == nil && !$0.isDisplayed }
        for message in unread {
            try? await transcripts.appendAmendment(
                TranscriptAmendment(action: .displayed, targetMessageID: message.id),
                conversationID: conversationID
            )
        }
        return !unread.isEmpty
    }

    /// Returns `true` if the element is a receipt or chat marker. One the contact sent is recorded. One that another of
    /// the user's devices sent acknowledges the contact's message, and says nothing about the user's own.
    private func handleCarbonReceiptOrMarker(
        _ element: DuckoXMPP.XMLElement, from: JID, accountID: UUID, isOutgoing: Bool
    ) async -> Bool {
        if let received = element.child(named: "received", namespace: XMPPNamespaces.receipts),
           let messageID = received.attribute("id") {
            if !isOutgoing {
                await handleDeliveryReceipt(messageID: messageID, from: from, accountID: accountID)
            }
            return true
        }
        for markerType in ChatMarkerType.allCases {
            if let marker = element.child(named: markerType.rawValue, namespace: XMPPNamespaces.chatMarkers),
               let messageID = marker.attribute("id") {
                if !isOutgoing {
                    await handleChatMarker(messageID: messageID, type: markerType, from: from, accountID: accountID)
                }
                return true
            }
        }
        return false
    }

    private func handleChatStateChanged(from: BareJID, state: ChatState, accountID: UUID) {
        typingStates[accountID, default: [:]][from] = state
    }

    private func handleMessageCorrected(originalID: String, newBody: String, from: JID, accountID: UUID) async {
        let conversationID = await conversationID(for: from, accountID: accountID)
        guard let conversationID,
              let original = try? await transcripts.findMessage(stanzaID: originalID, conversationID: conversationID) else { return }
        guard await verifySender(from: from, original: original, action: "correction", accountID: accountID) else { return }

        let filterDirection: FilterDirection = original.isOutgoing ? .outgoing : .incoming
        let filtered = await filterBody(newBody, direction: filterDirection, accountID: accountID, fallback: from.bareJID)

        try? await transcripts.appendAmendment(
            TranscriptAmendment(action: .edit, targetMessageID: original.id, targetStanzaID: originalID, timestamp: Date(), body: filtered.body, htmlBody: filtered.htmlBody),
            conversationID: conversationID
        )
        await messagesChanged(in: conversationID)
    }

    private func handleMessageRetracted(originalID: String, from: JID, accountID: UUID) async {
        let conversationID = await conversationID(for: from, accountID: accountID)
        guard let conversationID,
              let original = try? await transcripts.findMessage(stanzaID: originalID, conversationID: conversationID) else { return }
        guard await verifySender(from: from, original: original, action: "retraction", accountID: accountID) else { return }

        try? await transcripts.appendAmendment(
            TranscriptAmendment(action: .retract, targetMessageID: original.id, targetStanzaID: originalID, timestamp: Date()),
            conversationID: conversationID
        )
        await messagesChanged(in: conversationID)
    }

    private func verifySender(from: JID, original: ChatMessage, action: String, accountID: UUID) async -> Bool {
        if original.type == "groupchat" {
            // MUC: verify sender nickname matches
            guard case let .full(fullJID) = from else {
                log.warning("Rejected MUC \(action) without full JID: \(from)")
                return false
            }
            let senderNickname = fullJID.resourcePart
            if original.isOutgoing {
                // Echo of our own message — verify it's from our nickname
                guard await isOwnRoomMessage(nickname: senderNickname, room: from.bareJID, accountID: accountID) else {
                    log.warning("Rejected MUC \(action) for own message from wrong sender: \(senderNickname)")
                    return false
                }
            } else {
                // Incoming — sender nickname must match original
                guard senderNickname == original.fromJID else {
                    log.warning("Rejected MUC \(action): nickname \(senderNickname) != original \(original.fromJID)")
                    return false
                }
            }
        } else {
            // 1:1 chat: only the original sender can correct/retract their own message.
            // Outgoing messages store the recipient as fromJID — reject any remote
            // correction/retraction targeting our own outgoing messages.
            if original.isOutgoing {
                log.warning("Rejected \(action) targeting outgoing 1:1 message")
                return false
            }
            let senderJID = from.bareJID.description
            guard senderJID == original.fromJID else {
                log.warning("Rejected \(action): sender \(senderJID) doesn't match original \(original.fromJID)")
                return false
            }
        }
        return true
    }

    private func handleMessageModerated(originalID: String, room: BareJID, accountID: UUID) async {
        guard let conversationID = await conversationID(for: .bare(room), accountID: accountID) else { return }
        try? await transcripts.appendAmendment(
            TranscriptAmendment(action: .retract, targetServerID: originalID, timestamp: Date()),
            conversationID: conversationID
        )
        await messagesChanged(in: conversationID)
    }

    private func handleMessageError(messageID: String?, errorText: String, from: JID, accountID: UUID) async {
        guard let messageID,
              let conversationID = await conversation(forSender: from, accountID: accountID)?.id,
              await amendSentMessage(stanzaID: messageID, in: conversationID, {
                  TranscriptAmendment(action: .error, targetMessageID: $0, errorText: errorText)
              })
        else { return }
        await messagesChanged(in: conversationID)
    }

    private func isOwnRoomMessage(nickname: String?, room: BareJID, accountID: UUID) async -> Bool {
        guard let nickname,
              let client = accountService?.connectedClient(for: accountID),
              let mucModule = await client.module(ofType: MUCModule.self) else { return false }
        return nickname == mucModule.nickname(in: room)
    }

    private func handleRoomMessageReceived(_ xmppMessage: XMPPMessage, accountID: UUID) async {
        let metadata = InboundMessageMetadata(xmppMessage)
        guard let from = xmppMessage.from else { return }

        // Accept messages with body or OOB attachments
        let body = xmppMessage.body ?? metadata.attachments.first?.url
        guard let body else { return }

        let roomJID = from.bareJID

        let senderNickname: String? = if case let .full(fullJID) = from {
            fullJID.resourcePart
        } else {
            nil
        }

        // Skip own messages (the server echoes them back)
        if await isOwnRoomMessage(nickname: senderNickname, room: roomJID, accountID: accountID) {
            return
        }

        // Deduplicate replayed stanzas (stream recovery, MAM catchup)
        if await isDuplicate(stanzaID: metadata.stanzaID, from: roomJID, accountID: accountID) {
            return
        }

        let conversation: Conversation
        do {
            conversation = try await findOrCreateGroupConversation(for: roomJID, nickname: nil, accountID: accountID)
        } catch {
            return
        }

        let filtered = await filterBody(body, direction: .incoming, accountID: accountID, fallback: roomJID, isUnstyled: xmppMessage.isUnstyled, attachments: metadata.attachments)

        // Parse XEP-0359 stanza-id assigned by the MUC server
        let serverID = metadata.serverIdentifiers.first { $0.by == roomJID.description }?.id

        let fromLabel = senderNickname ?? roomJID.description
        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: metadata.stanzaID,
            serverID: serverID,
            fromJID: fromLabel,
            body: filtered.body,
            htmlBody: filtered.htmlBody,
            timestamp: Date(),
            isOutgoing: false,
            isDelivered: false,
            isEdited: false,
            type: "groupchat",
            replyToID: metadata.replyToID,
            attachments: metadata.attachments
        )
        await persistAndNotify(message, in: conversation, accountID: accountID)
    }

    private func handleMUCPrivateMessageReceived(_ xmppMessage: XMPPMessage, accountID: UUID) async {
        guard let from = xmppMessage.from,
              case let .full(fullJID) = from else { return }

        let metadata = InboundMessageMetadata(xmppMessage)
        let body = xmppMessage.body ?? metadata.attachments.first?.url
        guard let body else { return }

        let roomJID = fullJID.bareJID
        let nickname = fullJID.resourcePart

        if await isDuplicate(stanzaID: metadata.stanzaID, from: roomJID, occupantNickname: nickname, accountID: accountID) {
            return
        }

        let conversation: Conversation
        do {
            conversation = try await findOrCreateMUCPMConversation(for: roomJID, nickname: nickname, accountID: accountID)
        } catch {
            log.warning("Failed to create MUC PM conversation for \(roomJID)/\(nickname): \(error)")
            return
        }

        let filtered = await filterBody(body, direction: .incoming, accountID: accountID, fallback: roomJID, isUnstyled: xmppMessage.isUnstyled, attachments: metadata.attachments)

        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: metadata.stanzaID,
            fromJID: nickname,
            body: filtered.body,
            htmlBody: filtered.htmlBody,
            timestamp: Date(),
            isOutgoing: false,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            replyToID: metadata.replyToID,
            attachments: metadata.attachments
        )
        await persistAndNotify(message, in: conversation, accountID: accountID)
    }

    private func findOrCreateMUCPMConversation(
        for roomJID: BareJID, nickname: String, accountID: UUID
    ) async throws -> Conversation {
        let conversations = try await store.fetchConversations(for: accountID)
        if let existing = conversations.first(where: {
            $0.jid == roomJID && $0.type == .chat && $0.occupantNickname == nickname
        }) {
            return existing
        }
        let conversation = Conversation(
            id: UUID(),
            accountID: accountID,
            jid: roomJID,
            type: .chat,
            displayName: nickname,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            occupantNickname: nickname,
            createdAt: Date()
        )
        try await store.upsertConversation(conversation)
        return conversation
    }

    /// Records a file `jid` sent directly to this account as an incoming message that carries the saved file as its
    /// attachment.
    func recordReceivedFile(_ attachment: Attachment, from jid: BareJID, accountID: UUID) async throws {
        let conversation = try await findOrCreateConversation(for: jid, accountID: accountID)
        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            fromJID: jid.description,
            body: "",
            timestamp: Date(),
            isOutgoing: false,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            attachments: [attachment]
        )
        await persistAndNotify(message, in: conversation, accountID: accountID)
    }

    /// Adds a file this account is sending directly to its chat, where it shows like any other attachment. Returns the
    /// conversation the row went into.
    func recordSentFile(_ attachment: Attachment, id: UUID, to jid: BareJID, accountID: UUID) async throws -> UUID {
        let conversation = try await findOrCreateConversation(for: jid, accountID: accountID)
        let message = ChatMessage(
            id: id,
            conversationID: conversation.id,
            fromJID: jid.description,
            body: "",
            timestamp: Date(),
            isOutgoing: true,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            attachments: [attachment]
        )
        try await persistMessage(message, in: conversation, accountID: accountID)
        return conversation.id
    }

    /// Records how a directly sent file ended: delivered, or the reason it was not.
    func recordSentFileOutcome(messageID: UUID, in conversationID: UUID, failure: String?) async {
        let amendment = if let failure {
            TranscriptAmendment(action: .error, targetMessageID: messageID, errorText: failure)
        } else {
            TranscriptAmendment(action: .delivery, targetMessageID: messageID)
        }
        try? await transcripts.appendAmendment(amendment, conversationID: conversationID)
        await messagesChanged(in: conversationID)
    }

    private func persistAndNotify(_ message: ChatMessage, in conversation: Conversation, accountID: UUID) async {
        let countsAsUnread = conversation.id != activeConversationID
        let isKept = await (try? persistMessage(message, in: conversation, incrementUnread: countsAsUnread, accountID: accountID))
        guard isKept != false else { return }

        // Storing the message took a while, and the chat can have come into view or gone out of it meanwhile, so
        // whether it is looked at is read again here, for the marker and the read count together. A room's marker
        // checks once more after its nickname lookup.
        if conversation.id == activeConversationID {
            await sendDisplayedMarkerIfNeeded(for: message, in: conversation, accountID: accountID)
            try? await store.markConversationRead(conversation.id)
            if countsAsUnread {
                await republishConversations(for: accountID)
            }
        } else if !countsAsUnread {
            _ = try? await store.updateConversation(conversation.id) { $0.unreadCount += 1 }
            await republishConversations(for: accountID)
        }

        onIncomingMessage?(message, conversation)
    }

    /// Publishes the account's conversations as the store has them. A failed fetch leaves what is published as it is.
    private func republishConversations(for accountID: UUID) async {
        guard let fetched = try? await store.fetchConversations(for: accountID) else { return }
        setConversations(fetched, for: accountID)
    }

    /// Handles a destroyed room: clears live room state and removes the
    /// conversation's transcript, its store record, and the cached
    /// `openConversations` (which the contact list and chat tabs observe), so the
    /// room stops lingering after destruction. `clearRoomState` alone only drops
    /// live occupancy/flags. The transcript is deleted *before* the record so that
    /// a failed transcript delete leaves the record in place — keeping the JSONL
    /// reachable by the account-purge sweep (`deleteTranscriptsForAccount`) for
    /// retry, rather than orphaning it.
    private func handleRoomDestroyed(room: BareJID, accountID: UUID) async {
        clearRoomState(for: room, accountID: accountID)
        let conversations = await (try? store.fetchConversations(for: accountID)) ?? []
        guard let conversation = conversations.first(where: { $0.jid == room && $0.type == .groupchat }) else { return }
        try? await transcripts.deleteTranscripts(for: conversation.id)
        try? await store.deleteConversation(conversation.id)
        removeCachedConversation(id: conversation.id, accountID: accountID)
    }

    private func handleRoomSubjectChanged(room: BareJID, subject: String?, accountID: UUID) async {
        let conversations = await (try? store.fetchConversations(for: accountID)) ?? []
        guard let conversation = conversations.first(where: { $0.jid == room && $0.type == .groupchat }),
              let updated = try? await store.updateConversation(conversation.id, { $0.roomSubject = subject }) else { return }
        updateCachedConversation(updated)
    }

    /// Clears the room's occupancy state and finishes its pending join waiter without success.
    package func clearRoomState(for jid: BareJID, accountID: UUID) {
        roomService.clearRoomState(for: jid, accountID: accountID)
    }

    /// Per-account disconnect clear. Drops every room-keyed entry belonging to the account, leaving other
    /// accounts' rooms intact. Filters the `(accountID, room)`-keyed maps directly (synchronous) rather than
    /// re-deriving rooms from persisted conversations, so it can run in `disconnect`'s no-await prefix.
    private func clearRoomState(forAccount accountID: UUID) {
        roomService.clearRoomState(forAccount: accountID)
    }

    // MARK: - Lifecycle

    /// Drops one account's live chat state — peer resource locks, incoming typing indicators, and room-keyed
    /// state. Shared by the `.disconnected` handler and `purgeAccount` so the two stay in lockstep. Clears only
    /// state that must reset on a blip: locks, typing, and room occupancy are rebuilt on reconnect/rejoin.
    private func clearLiveChatState(for accountID: UUID) {
        clearLocks(accountID: accountID)
        typingStates.removeValue(forKey: accountID)
        clearRoomState(forAccount: accountID)
    }

    /// Drops one account's chat state when the user ends its session, which a stream blip never does. Pending
    /// invites are discarded only here, because the server never re-delivers them on a reconnect. Pending leaves are
    /// discarded because they belong to the session a resume would continue, and this teardown ends it. Persisted
    /// conversations survive offline.
    func purgeAccount(_ accountID: UUID) {
        clearLiveChatState(for: accountID)
        roomService.clearInvites(accountID: accountID)
        roomService.clearPendingLeaves(accountID: accountID)
    }

    // MARK: - Private: Group OMEMO

    /// Resolved group-message payload: whether OMEMO applied, the body to put on the wire (plaintext, or the
    /// OMEMO fallback when encrypted), and the elements to attach. Built before persist so an encryption
    /// failure throws with nothing persisted (mirrors how 1:1 resolves `trustedDeviceIDsForSend` first).
    private struct PreparedGroupMessage {
        let isEncrypted: Bool
        let body: String
        let additionalElements: [DuckoXMPP.XMLElement]
    }

    /// Resolves OMEMO for a group message and prepares the wire payload without sending. Fail-closed when the
    /// service is unwired or every occupant resolves to no-local/no-trusted. Partial trust → encrypt to the
    /// trusted subset (OMEMOService emits `.omemoRecipientsPartial` for the dropped occupants).
    private func prepareGroupMessage(
        room: BareJID, body: String,
        conversation: Conversation, additionalElements: [DuckoXMPP.XMLElement]
    ) async throws -> PreparedGroupMessage {
        guard conversation.encryptionEnabled, let accountID = conversation.accountID else {
            return PreparedGroupMessage(isEncrypted: false, body: body, additionalElements: additionalElements)
        }
        guard let omemoService else {
            throw ChatServiceError.omemoServiceUnavailable(conversationJID: room)
        }

        let memberJIDs = try await roomMemberJIDs(roomJIDString: room.description, accountID: accountID)
        guard !memberJIDs.isEmpty else {
            throw ChatServiceError.encryptionFailed("Cannot encrypt: no room members with known JIDs")
        }

        // Pre-check per occupant: if every member resolves to no-local or
        // no-trusted devices, throw before the encryptGroupMessage call
        // (which would otherwise throw OMEMOServiceError.noTrustedRecipients
        // — surface a more specific error so the UI can react).
        var untrustedJIDs: [BareJID] = []
        var anyEncryptable = false
        for member in memberJIDs {
            let resolution = await omemoService.shouldEncrypt(
                jid: member, accountID: accountID, conversationEncryptionEnabled: true
            )
            switch resolution {
            case .proceed:
                anyEncryptable = true
            case .noLocalDevicesForPeer, .noTrustedDevicesForPeer:
                untrustedJIDs.append(member)
            case .userDisabled, .serviceUnavailable:
                // `userDisabled` is unreachable here (we already gated on
                // `conversation.encryptionEnabled`). `serviceUnavailable` is
                // unreachable too because `omemoService` is non-nil at this
                // point (guarded above before entering the loop). Bucket
                // both into the encryptable side for the gate decision.
                anyEncryptable = true
            }
        }
        guard anyEncryptable else {
            throw ChatServiceError.omemoNoTrustedDevicesInRoom(
                roomJID: room, untrustedJIDs: untrustedJIDs
            )
        }

        let elements = try await omemoService.encryptGroupMessage(
            body: body, roomJID: room, memberJIDs: memberJIDs, accountID: accountID
        )
        let storeHint = DuckoXMPP.XMLElement(name: "store", namespace: XMPPNamespaces.processingHints)
        return PreparedGroupMessage(
            isEncrypted: true,
            body: elements.fallbackBody,
            additionalElements: [elements.encrypted, elements.encryption, storeHint] + additionalElements
        )
    }

    /// Sends a prepared group payload. The only step that touches the transport — kept separate so callers
    /// can persist the optimistic message before this runs and roll it back when it throws.
    private func sendPreparedGroupMessage(
        _ prepared: PreparedGroupMessage, room: BareJID, stanzaID: String, mucModule: MUCModule
    ) async throws {
        try await mucModule.sendMessage(
            to: room, body: prepared.body, id: stanzaID, markable: true,
            additionalElements: prepared.additionalElements
        )
    }

    /// Prepares and sends a group message in one step, returning whether it was encrypted. Used by the
    /// correction/retraction flows, which persist their amendment after a successful send (success-path
    /// amendment, not persist-before-send rollback).
    private func encryptAndSendGroupMessage(
        room: BareJID, body: String, stanzaID: String,
        conversation: Conversation, mucModule: MUCModule,
        additionalElements: [DuckoXMPP.XMLElement] = []
    ) async throws -> Bool {
        let prepared = try await prepareGroupMessage(
            room: room, body: body, conversation: conversation, additionalElements: additionalElements
        )
        try await sendPreparedGroupMessage(prepared, room: room, stanzaID: stanzaID, mucModule: mucModule)
        return prepared.isEncrypted
    }

    /// Bumps the revision (so the open chat view refreshes) and reloads `messages` only when `conversationID` matches the active one.
    private func messagesChanged(in conversationID: UUID) async {
        bumpRevision(for: conversationID)
        if conversationID == activeConversationID {
            messages = await loadMessages(for: conversationID)
        }
    }

    private func bumpRevision(for conversationID: UUID) {
        messagesRevisions[conversationID, default: 0] &+= 1
    }

    private func accountJID(for accountID: UUID, fallback: BareJID) -> BareJID {
        accountService?.accounts.first { $0.id == accountID }?.jid ?? fallback
    }

    /// Single entry point for running a body through the filter pipeline, so every send/receive/correction/archive
    /// path shares one place to set direction, account JID, `isUnstyled`, and the archive safety flags (rather than
    /// each site rebuilding `MessageContent`/`FilterContext` and risking a forgotten flag).
    private func filterBody(
        _ body: String,
        direction: FilterDirection,
        accountID: UUID,
        fallback: BareJID,
        isUnstyled: Bool = false,
        attachments: [Attachment] = []
    ) async -> MessageContent {
        // A body that only repeats an attachment's link is shown as the attachment, which decides for itself when
        // the link is fetched, so no preview is fetched for it.
        await filterBody(
            body, direction: direction, accountJID: accountJID(for: accountID, fallback: fallback), isUnstyled: isUnstyled,
            allowLinkPreviewFetches: !attachments.areLinked(by: body)
        )
    }

    private func filterBody(
        _ body: String,
        direction: FilterDirection,
        accountJID: BareJID,
        isUnstyled: Bool = false,
        allowLinkPreviewFetches: Bool = true,
        allowBodyMutation: Bool = true
    ) async -> MessageContent {
        let content = MessageContent(body: body, isUnstyled: isUnstyled)
        let context = FilterContext(
            accountJID: accountJID,
            allowLinkPreviewFetches: allowLinkPreviewFetches,
            allowBodyMutation: allowBodyMutation
        )
        return await filterPipeline.process(content, direction: direction, context: context)
    }

    /// Bridges optional `OMEMOService` to `EncryptionResolution`. Fail-closed: nil service → `.serviceUnavailable`
    /// (every dispatch throws). Collapsing nil-service into `.userDisabled` or `.proceed([])` would silently
    /// downgrade an encryption-required send to plaintext.
    private func resolveEncryption(
        jid: BareJID, accountID: UUID, conversationEncryptionEnabled: Bool
    ) async -> OMEMOService.EncryptionResolution {
        guard conversationEncryptionEnabled else { return .userDisabled }
        guard let omemoService else { return .serviceUnavailable }
        return await omemoService.shouldEncrypt(
            jid: jid, accountID: accountID,
            conversationEncryptionEnabled: conversationEncryptionEnabled
        )
    }

    /// Canonical home for the XEP-0359 §3 `by`-filter contract.
    ///
    /// Returns the archive-stamped stanza id only when its `by` attribute parses to a `BareJID` equal to `trustedBy`
    /// (the user's own bare JID, or the room's bare JID for groupchat). Without the filter, a remote peer can stamp
    /// their own `<stanza-id>` and use the dedup key to silently suppress legitimate later messages.
    ///
    /// `BareJID`-aware comparison (not raw string equality) — a server may stamp `by="Alice@Example.COM"` while our
    /// canonicalized `accountJID.description` is `"alice@example.com"`; `BareJID.init` normalizes both sides.
    ///
    /// Fail-closed: returns nil when `trustedBy` is nil (e.g., weakly-held `accountService` deallocated). Falling back
    /// to the peer JID would let a peer's own `<stanza-id by=...>` pass the filter.
    private func trustedServerID(in metadata: InboundMessageMetadata, trustedBy: BareJID?) -> String? {
        guard let trustedBy else { return nil }
        return metadata.serverIdentifiers.first { identifier in
            guard let by = identifier.by, let parsed = BareJID.parse(by) else { return false }
            return parsed == trustedBy
        }?.id
    }

    /// Strict variant of `accountJID(for:)`: returns nil when the account
    /// can't be resolved, instead of falling back to a (potentially attacker-
    /// controlled) peer JID. Use this for trust-filter inputs.
    private func resolvedAccountJID(for accountID: UUID) -> BareJID? {
        accountService?.accounts.first { $0.id == accountID }?.jid
    }

    private func handleMessageReceived(_ xmppMessage: XMPPMessage, accountID: UUID) async {
        if shouldSkipRawMessage(xmppMessage, accountID: accountID) { return }

        // Headline messages are transient (RFC 6121 §5.2.2) — surface but don't persist
        if xmppMessage.messageType == .headline {
            if xmppMessage.body != nil, xmppMessage.from != nil {
                onHeadlineMessage?(xmppMessage)
            }
            return
        }

        // Parse OOB attachments before body check — OOB-only messages have no body
        let metadata = InboundMessageMetadata(xmppMessage)

        guard xmppMessage.messageType == .chat || xmppMessage.messageType == .normal,
              let from = xmppMessage.from else { return }
        let fromJID = from.bareJID

        // Accept messages with body or OOB attachments
        let body = xmppMessage.body ?? metadata.attachments.first?.url
        guard let body else { return }

        // Capture the arrival tick now, before the first await, so the resource lock learned below advances in
        // arrival order even if this handler interleaves with another inbound's handler on the MainActor.
        let lockSequence = nextLockSequence()

        let stanzaID = metadata.stanzaID
        // XEP-0359 mod_mam stanza-id — preferred dedup key (globally unique within the user's archive,
        // unlike per-sender `stanzaID`). See `trustedServerID` for the §3 `by`-filter trust contract.
        let serverID = trustedServerID(
            in: metadata, trustedBy: resolvedAccountJID(for: accountID)
        )
        if await isDuplicateIncoming(serverID: serverID, stanzaID: stanzaID, from: fromJID, accountID: accountID) {
            return
        }

        let conversation: Conversation
        do {
            conversation = try await findOrCreateConversation(for: fromJID, accountID: accountID)
        } catch {
            return
        }

        let filtered = await filterBody(body, direction: .incoming, accountID: accountID, fallback: fromJID, isUnstyled: xmppMessage.isUnstyled, attachments: metadata.attachments)

        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: stanzaID,
            serverID: serverID,
            fromJID: fromJID.description,
            body: filtered.body,
            htmlBody: filtered.htmlBody,
            timestamp: Date(),
            isOutgoing: false,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            replyToID: metadata.replyToID,
            attachments: metadata.attachments
        )
        // RFC 6121 §5.1: lock the conversation to the peer's most recent full resource. Placed after every
        // accept guard so bodyless chat-state-only, duplicate, or stream-replayed stanzas can't move the lock.
        // Only accepted live 1:1 inbound moves the lock — MAM ingest, carbons, and MUC PMs are deliberately excluded.
        learnResourceLock(from: from, accountID: accountID, sequence: lockSequence)
        await persistAndNotify(message, in: conversation, accountID: accountID)
    }

    private func handleCarbon(_ forwarded: ForwardedMessage, accountID: UUID, isOutgoing: Bool) async {
        let jid = isOutgoing ? forwarded.message.to?.bareJID : forwarded.message.from?.bareJID
        let metadata = InboundMessageMetadata(forwarded.message)

        guard forwarded.message.messageType != .groupchat,
              let jid else { return }

        // Handle receipt/marker carbons (bodyless) before the body guard.
        // Carbon-forwarded stanzas bypass ReceiptsModule dispatch, so parse XML directly.
        if await handleCarbonReceiptOrMarker(forwarded.message.element, from: .bare(jid), accountID: accountID, isOutgoing: isOutgoing) {
            return
        }

        // Skip retractions — handled by .messageRetracted event
        if forwarded.message.element.child(named: "retract", namespace: XMPPNamespaces.messageRetract) != nil {
            return
        }

        // Skip corrections — handled by .messageCorrected event
        if forwarded.message.element.child(named: "replace", namespace: XMPPNamespaces.messageCorrect) != nil {
            return
        }

        // Skip encrypted messages — handled by .omemoEncryptedMessageReceived event
        if forwarded.message.element.child(named: "encryption", namespace: XMPPNamespaces.eme) != nil {
            return
        }

        await ingestCarbonBody(
            forwarded, metadata: metadata, jid: jid, accountID: accountID, isOutgoing: isOutgoing
        )
    }

    /// Persists a carbon after classification, keeping direction-specific filtering and trust here.
    private func ingestCarbonBody(
        _ forwarded: ForwardedMessage,
        metadata: InboundMessageMetadata,
        jid: BareJID,
        accountID: UUID,
        isOutgoing: Bool
    ) async {
        guard let body = forwarded.message.body ?? metadata.attachments.first?.url else { return }
        // XEP-0359 trust-filtered (see `trustedServerID`). Inbound carbons key on `serverID` — without it, a carbon
        // insert followed by a MAM replay would double-persist (MAM keys on serverID, older carbons keyed only on
        // stanzaID). Outgoing carbons reuse the simpler `(stanzaID, fromJID)` path since the message persisted before send.
        let serverID = trustedServerID(
            in: metadata, trustedBy: resolvedAccountJID(for: accountID)
        )

        let isDup: Bool = if isOutgoing {
            await isDuplicate(stanzaID: metadata.stanzaID, from: jid, accountID: accountID)
        } else {
            await isDuplicateIncoming(
                serverID: serverID, stanzaID: metadata.stanzaID, from: jid, accountID: accountID
            )
        }
        if isDup { return }

        let conversation: Conversation
        do {
            conversation = try await findOrCreateConversation(for: jid, accountID: accountID)
        } catch {
            return
        }

        let filterDirection: FilterDirection = isOutgoing ? .outgoing : .incoming
        let filtered = await filterBody(body, direction: filterDirection, accountID: accountID, fallback: jid, isUnstyled: forwarded.message.isUnstyled, attachments: metadata.attachments)

        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: metadata.stanzaID,
            serverID: serverID,
            fromJID: jid.description,
            body: filtered.body,
            htmlBody: filtered.htmlBody,
            timestamp: parseISO8601Timestamp(forwarded.timestamp),
            isOutgoing: isOutgoing,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            replyToID: metadata.replyToID,
            attachments: metadata.attachments
        )
        try? await persistMessage(message, in: conversation, accountID: accountID)
    }

    private func parseISO8601Timestamp(_ stamp: String?) -> Date {
        guard let stamp else { return Date() }
        let isoStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let basicStyle = Date.ISO8601FormatStyle()
        return (try? isoStyle.parse(stamp)) ?? (try? basicStyle.parse(stamp)) ?? Date()
    }

    /// Returns `true` if the raw `.messageReceived` stanza should be skipped because a classified event handles it.
    private func shouldSkipRawMessage(_ message: XMPPMessage, accountID: UUID) -> Bool {
        // Retractions, corrections, encrypted — handled by classified events
        if message.element.child(named: "retract", namespace: XMPPNamespaces.messageRetract) != nil { return true }
        if message.element.child(named: "replace", namespace: XMPPNamespaces.messageCorrect) != nil { return true }
        if message.element.child(named: "encryption", namespace: XMPPNamespaces.eme) != nil { return true }
        // MUC invites — handled by .roomInviteReceived
        if message.element.child(named: "x", namespace: XMPPNamespaces.mucDirectInvite) != nil { return true }
        if let mucUser = message.element.child(named: "x", namespace: XMPPNamespaces.mucUser),
           mucUser.child(named: "invite") != nil { return true }
        // MUC private messages — handled by .mucPrivateMessageReceived
        if message.messageType == .chat || message.messageType == .normal, let from = message.from, case .full = from {
            let roomJID = from.bareJID
            if openConversations.contains(where: { $0.jid == roomJID && $0.type == .groupchat && $0.accountID == accountID })
                || message.element.child(named: "x", namespace: XMPPNamespaces.mucUser) != nil {
                return true
            }
        }
        return false
    }

    /// Returns `false` when the message was not kept because its room is gone.
    @discardableResult
    private func persistMessage(
        _ message: ChatMessage,
        in conversation: Conversation,
        incrementUnread: Bool = false,
        accountID: UUID
    ) async throws -> Bool {
        try await transcripts.appendMessage(message)

        // Only what this message changes is written to the conversation's row. The caller's copy was taken before its
        // own awaits, and writing all of it back would undo what another handler stored meanwhile, such as encryption
        // that the contact's previous message switched on.
        let (date, preview) = (message.timestamp, String(message.previewText.prefix(100)))
        let record: @Sendable (inout Conversation) -> Void = {
            $0.lastMessageDate = date
            $0.lastMessagePreview = preview
            if incrementUnread {
                $0.unreadCount += 1
            }
        }
        if try await store.updateConversation(conversation.id, record) == nil {
            // The row went away while this message was on its way. A chat the user deleted starts again with it. A
            // room that was destroyed does not come back for a straggler, and what was just written for it goes too:
            // without its row, no later cleanup would find it.
            guard conversation.type == .chat else {
                try? await transcripts.deleteTranscripts(for: conversation.id)
                return false
            }
            var created = conversation
            record(&created)
            try await store.upsertConversation(created)
        }

        try await setConversations(store.fetchConversations(for: accountID), for: accountID)

        await messagesChanged(in: conversation.id)
        return true
    }

    private func isDuplicate(stanzaID: String?, from jid: BareJID, occupantNickname: String? = nil, accountID: UUID) async -> Bool {
        guard let stanzaID,
              let conversationID = await conversationID(for: .bare(jid), accountID: accountID, occupantNickname: occupantNickname)
        else { return false }
        return await (try? transcripts.messageExists(stanzaID: stanzaID, conversationID: conversationID)) ?? false
    }

    /// Inbound 1:1 dedup. When a `serverID` is present it is the *only* key — falling through to `(stanzaID, fromJID)`
    /// would mis-dedup against a stale archive entry whose `stanzaID` collides (e.g. a CLI peer that restarted and
    /// reset its sequential id counter). Fallback path only when no XEP-0359 stamp is present.
    private func isDuplicateIncoming(serverID: String?, stanzaID: String?, from jid: BareJID, accountID: UUID) async -> Bool {
        guard let conversationID = await conversationID(for: .bare(jid), accountID: accountID) else { return false }
        if let serverID {
            return await (try? transcripts.messageExists(serverID: serverID, conversationID: conversationID)) ?? false
        }
        guard let stanzaID else { return false }
        return await (try? transcripts.messageExists(stanzaID: stanzaID, fromJID: jid.description, conversationID: conversationID)) ?? false
    }

    public func loadMessages(for conversationID: UUID) async -> [ChatMessage] {
        await (try? fetchMessageHistory(for: conversationID, before: nil, limit: 50)) ?? []
    }

    public func fetchMessageHistory(
        for conversationID: UUID,
        before: Date?,
        limit: Int
    ) async throws -> [ChatMessage] {
        let messages = try await transcripts.fetchMessages(for: conversationID, before: before, limit: limit)
        return messages.reversed()
    }

    // MARK: - Transcript Lifecycle

    public func deleteTranscriptsForAccount(_ accountID: UUID) async throws {
        let conversations = try await store.fetchConversations(for: accountID)
        for conversation in conversations {
            try await transcripts.deleteTranscripts(for: conversation.id)
        }
    }

    // MARK: - Transcript Queries

    public func fetchAllConversations() async throws -> [Conversation] {
        try await store.fetchAllConversations()
    }

    /// Every stored day of the given conversations, newest first, equal dates in the order the conversations were
    /// given.
    public func transcriptDays(for conversationIDs: [UUID]) async throws -> [TranscriptDay] {
        var days: [(day: TranscriptDay, order: Int)] = []
        for (order, conversationID) in conversationIDs.enumerated() {
            for date in try await transcripts.transcriptDays(for: conversationID) {
                days.append((TranscriptDay(conversationID: conversationID, date: date), order))
            }
        }
        return days
            .sorted { $0.day.date == $1.day.date ? $0.order < $1.order : $0.day.date > $1.day.date }
            .map(\.day)
    }

    /// The messages of one day that a search for `query` finds, in the order the day shows them. Each call reads one
    /// day's file, so messages can be stored between the calls of a search over many days.
    public func matchingMessages(_ query: String, on day: TranscriptDay) async throws -> [ChatMessage] {
        try await transcripts.matchingMessages(query, in: day.conversationID, on: day.date)
    }

    /// The newest `limit` messages of the given conversations that a search for `query` finds. They are grouped by
    /// conversation and day, newest day first, each day's messages in the order the day shows them. Days are read from
    /// the newest on, and no day older than the last one needed is read.
    public func searchTranscriptMessages(
        query: String, in conversationIDs: [UUID], limit: Int
    ) async throws -> [(day: TranscriptDay, messages: [ChatMessage])] {
        let days = try await transcriptDays(for: conversationIDs)
        var results: [(day: TranscriptDay, messages: [ChatMessage])] = []
        var remaining = limit
        var index = days.startIndex
        while remaining > 0, index < days.endIndex {
            // Conversations sharing a date are read together: which of their matches are the newest is only known
            // once all of them are in.
            let date = days[index].date
            var found: [(day: TranscriptDay, messages: [ChatMessage])] = []
            while index < days.endIndex, days[index].date == date {
                let matches = try await matchingMessages(query, on: days[index])
                if !matches.isEmpty {
                    found.append((days[index], matches))
                }
                index += 1
            }
            let count = found.reduce(0) { $0 + $1.messages.count }
            results += count > remaining ? Self.newest(remaining, of: found) : found
            remaining -= min(count, remaining)
        }
        return results
    }

    /// The `count` newest messages of one date's matches, each day keeping its order. Of two messages with one
    /// timestamp in a day, the one shown later is the newer.
    private static func newest(
        _ count: Int, of found: [(day: TranscriptDay, messages: [ChatMessage])]
    ) -> [(day: TranscriptDay, messages: [ChatMessage])] {
        let positions = found.enumerated().flatMap { dayIndex, entry in
            entry.messages.enumerated().map { (day: dayIndex, offset: $0.offset, timestamp: $0.element.timestamp) }
        }
        let newestFirst = positions.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.day == rhs.day ? lhs.offset > rhs.offset : lhs.day < rhs.day
        }
        var kept: [Int: Set<Int>] = [:]
        for position in newestFirst.prefix(count) {
            kept[position.day, default: []].insert(position.offset)
        }
        return found.enumerated().compactMap { dayIndex, entry in
            guard let offsets = kept[dayIndex] else { return nil }
            return (entry.day, entry.messages.enumerated().filter { offsets.contains($0.offset) }.map(\.element))
        }
    }

    public func fetchMessageHistory(for conversationID: UUID, on date: Date) async throws -> [ChatMessage] {
        try await transcripts.fetchMessages(for: conversationID, on: date)
    }

    /// The timeline notes stamped at or after `since` and before `before`. A nil bound is open.
    public func fetchNotes(for conversationID: UUID, since: Date?, before: Date? = nil) async -> [TimelineNote] {
        await (try? transcripts.fetchNotes(for: conversationID, since: since, before: before)) ?? []
    }

    // MARK: - Server History

    public func fetchServerHistory(
        jid: BareJID,
        accountID: UUID,
        before: Date?,
        limit: Int
    ) async throws -> (messages: [ChatMessage], hasMore: Bool) {
        guard let client = accountService?.connectedClient(for: accountID) else {
            throw ChatServiceError.notConnected(accountID)
        }
        guard let mamModule = await client.module(ofType: MAMModule.self) else {
            return ([], false)
        }

        let conversation = try await findOrCreateConversation(for: jid, accountID: accountID)
        let accountJID = accountJID(for: accountID, fallback: jid)
        let endISO = before.map { $0.formatted(.iso8601) }

        let to: BareJID? = conversation.type == .groupchat ? conversation.jid : nil
        let with: BareJID? = conversation.type == .groupchat ? nil : jid
        // The last page of the range is the one adjacent to `before`. A page can hold nothing to add, only duplicates
        // and entries without a body, while the archive goes on before it.
        var page = MAMModule.RSMBefore.lastPage
        for _ in 0 ..< Self.maxServerHistoryPages {
            let (archived, fin) = try await mamModule.queryMessages(
                MAMModule.Query(to: to, with: with, end: endISO, before: page, max: limit)
            )
            let newMessages = try await convertAndDedup(
                archived: archived, conversation: conversation, accountJID: accountJID
            )
            guard newMessages.isEmpty, !fin.complete, let first = fin.first else {
                return (newMessages, !fin.complete)
            }
            page = .id(first)
        }
        return ([], true)
    }

    /// How many archive pages one history fetch reads before it gives up finding anything to add.
    private static let maxServerHistoryPages = 10

    public func fetchServerHistory(
        jidString: String,
        accountID: UUID,
        before: Date?,
        limit: Int
    ) async throws -> (messages: [ChatMessage], hasMore: Bool) {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        return try await fetchServerHistory(jid: jid, accountID: accountID, before: before, limit: limit)
    }

    private func startRecentHistorySync(accountID: UUID) {
        let taskID = UUID()
        pendingTasks[taskID] = Task { [weak self] in
            defer { self?.pendingTasks[taskID] = nil }
            await self?.syncRecentHistory(accountID: accountID)
        }
    }

    private func syncRecentHistory(accountID: UUID) async {
        guard let client = accountService?.connectedClient(for: accountID) else { return }
        guard let mamModule = await client.module(ofType: MAMModule.self) else { return }
        guard let account = accountService?.accounts.first(where: { $0.id == accountID }) else { return }
        let accountJID = account.jid

        do {
            let conversations = try await store.fetchConversations(for: accountID)
            for conversation in conversations {
                if Task.isCancelled { return }
                let lastMessages = try await transcripts.fetchMessages(for: conversation.id, before: nil, limit: 1)
                let startISO = lastMessages.first.map { $0.timestamp.formatted(.iso8601) }

                let to: BareJID? = conversation.type == .groupchat ? conversation.jid : nil
                let with: BareJID? = conversation.type == .groupchat ? nil : conversation.jid
                let (archived, _) = try await mamModule.queryMessages(
                    to: to, with: with, start: startISO, max: 50
                )
                let newMessages = try await convertAndDedup(
                    archived: archived, conversation: conversation, accountJID: accountJID
                )
                // `convertAndDedup` appended the archived rows to the transcript across
                // several awaits. If the room was destroyed during the MAM round-trip or
                // those appends, delete the transcript it recreated rather than leave an
                // orphaned JSONL the account-purge sweep can no longer reach. Checked
                // after the appends so no transcript write can follow it; the metadata
                // write below is guarded separately by `updateConversation`.
                guard try await store.fetchConversations(for: accountID).contains(where: { $0.id == conversation.id }) else {
                    try? await transcripts.deleteTranscripts(for: conversation.id)
                    continue
                }
                if let lastMessage = newMessages.last {
                    // Updates an existing row only, since the conversation may have been destroyed during this MAM
                    // round-trip. It writes only the last message's date and preview, because `conversation` was read
                    // before the round-trip and the rest of it may have changed since.
                    let (date, preview) = (lastMessage.timestamp, String(lastMessage.previewText.prefix(100)))
                    try await store.updateConversation(conversation.id) {
                        $0.lastMessageDate = date
                        $0.lastMessagePreview = preview
                    }
                }
            }
            try await setConversations(store.fetchConversations(for: accountID), for: accountID)
        } catch {
            let desc = error.localizedDescription
            log.warning("MAM sync failed: \(desc)")
        }
    }

    private func convertAndDedup(
        archived: [ArchivedMessage],
        conversation: Conversation,
        accountJID: BareJID
    ) async throws -> [ChatMessage] {
        var newMessages: [ChatMessage] = []

        // Trust anchor for XEP-0359 `<stanza-id>`: 1:1 archives are stamped by
        // the user's bare JID; groupchat archives are stamped by the room.
        let trustedBy: BareJID = conversation.type == .groupchat ? conversation.jid : accountJID

        for entry in archived {
            let forwarded = entry.forwarded
            let metadata = InboundMessageMetadata(forwarded.message)
            let body = forwarded.message.body ?? metadata.attachments.first?.url
            guard let body else { continue }

            let meta = resolveMessageMeta(forwarded: forwarded, conversation: conversation, accountJID: accountJID)

            // Re-derive serverID with the trust filter — `entry.serverID` is
            // raw, before XEP-0359 §3 `by`-validation.
            let trustedServerID = trustedServerID(in: metadata, trustedBy: trustedBy)

            if let trustedServerID {
                if try await transcripts.messageExists(serverID: trustedServerID, conversationID: conversation.id) {
                    continue
                }
                // Our own MUC echo is dropped by nickname in `handleRoomMessageReceived` before any
                // serverID is recorded, so the optimistically-persisted row keeps `serverID == nil` and
                // the serverID check above can't see it. Without this guard, the MAM copy (which carries a
                // trusted serverID) re-imports as a second row. Match the un-reconciled optimistic row by
                // stanzaID so the replay dedups against it.
                if conversation.type == .groupchat, meta.isOutgoing, let stanzaID = metadata.stanzaID,
                   try await ownOptimisticGroupRowExists(
                       stanzaID: stanzaID, archived: forwarded.message, body: body, conversation: conversation
                   ) {
                    continue
                }
            } else if let stanzaID = metadata.stanzaID {
                // No trusted serverID — fall back to stanza-id-scoped dedup.
                // Direction matters: outgoing archived rows would compare
                // against locally-persisted outgoing rows whose `fromJID` is
                // the recipient (so the inbound-only overload couldn't match
                // them). Use the stanzaID-only path for outgoing and the
                // sender-scoped path for inbound.
                let isDup: Bool = if meta.isOutgoing {
                    try await transcripts.messageExists(stanzaID: stanzaID, conversationID: conversation.id)
                } else if let senderJID = forwarded.message.from?.bareJID {
                    try await transcripts.messageExists(
                        stanzaID: stanzaID, fromJID: senderJID.description, conversationID: conversation.id
                    )
                } else {
                    try await transcripts.messageExists(stanzaID: stanzaID, conversationID: conversation.id)
                }
                if isDup { continue }
            } else if try await transcripts.messageExists(serverID: entry.messageID, conversationID: conversation.id) {
                continue
            }

            // An entry that carries no id of its own is known by the archive's id for it, or it would be added again
            // each time its range is read.
            let serverID = trustedServerID ?? (metadata.stanzaID == nil ? entry.messageID : nil)
            let entry = ArchivedEntry(
                forwarded: forwarded, body: body, meta: meta,
                serverID: serverID, metadata: metadata
            )
            let message = await makeArchivedMessage(entry, in: conversation, accountJID: accountJID)
            try await transcripts.appendMessage(message)
            newMessages.append(message)
        }

        return newMessages.sorted { $0.timestamp < $1.timestamp }
    }

    /// Per-entry inputs for building an archived `ChatMessage`.
    private struct ArchivedEntry {
        let forwarded: ForwardedMessage
        let body: String
        let meta: MessageMeta
        let serverID: String?
        let metadata: InboundMessageMetadata
    }

    /// Builds the persisted `ChatMessage` for an archived entry, deriving display-only `htmlBody` through the same
    /// styling/mention filters as the live paths so a MAM-backfilled message renders identically to its
    /// live-received counterpart. The archive-path flags keep `filtered.body == body`, which matters because this
    /// runs after `convertAndDedup`'s dedup checks (they compare the raw archived `body`), so the derived
    /// `htmlBody` can't perturb dedup.
    private func makeArchivedMessage(_ entry: ArchivedEntry, in conversation: Conversation, accountJID: BareJID) async -> ChatMessage {
        let filterDirection: FilterDirection = entry.meta.isOutgoing ? .outgoing : .incoming
        let filtered = await filterBody(
            entry.body, direction: filterDirection, accountJID: accountJID,
            isUnstyled: entry.forwarded.message.isUnstyled,
            allowLinkPreviewFetches: false, allowBodyMutation: false
        )

        return ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: entry.metadata.stanzaID,
            serverID: entry.serverID,
            fromJID: entry.meta.fromJID,
            body: filtered.body,
            htmlBody: filtered.htmlBody,
            timestamp: parseISO8601Timestamp(entry.forwarded.timestamp),
            isOutgoing: entry.meta.isOutgoing,
            isDelivered: false,
            isEdited: false,
            type: entry.meta.messageType,
            replyToID: entry.metadata.replyToID,
            attachments: entry.metadata.attachments
        )
    }

    /// Returns true when an un-reconciled optimistic own-MUC row (`serverID == nil`) matches the archived
    /// stanza, so a MAM replay of our own group message isn't double-imported. The sub-branch is keyed on
    /// the *archive's* OMEMO-ness, not the candidate's: a plaintext archive matches on body equality; an
    /// OMEMO archive matches on stanzaID + `isEncrypted`, because the optimistic row stores plaintext while
    /// the archive carries the undecryptable fallback body. Uses the all-candidates `findMessages` query so a
    /// `ducko-N` collision can't make `findMessage`'s first-match return an older, wrong row.
    private func ownOptimisticGroupRowExists(
        stanzaID: String, archived: DuckoXMPP.XMPPMessage, body: String, conversation: Conversation
    ) async throws -> Bool {
        let isOMEMOArchive = archived.element.child(named: "encrypted", namespace: XMPPNamespaces.omemo) != nil
            || archived.body == omemoFallbackBody
        let candidates = try await transcripts.findMessages(stanzaID: stanzaID, conversationID: conversation.id)
        return candidates.contains { candidate in
            guard candidate.isOutgoing, candidate.serverID == nil else { return false }
            // A retracted optimistic row has its body cleared, so the body/isEncrypted disambiguation
            // below can't recognize it. Suppress the MAM replay anyway: a stanza we retracted must stay
            // gone, not re-import as a fresh unretracted row.
            if candidate.isRetracted { return true }
            return isOMEMOArchive ? candidate.isEncrypted : candidate.body == body
        }
    }

    private struct MessageMeta {
        let fromJID: String
        let isOutgoing: Bool
        let messageType: String
    }

    private func resolveMessageMeta(
        forwarded: ForwardedMessage,
        conversation: Conversation,
        accountJID: BareJID
    ) -> MessageMeta {
        switch conversation.type {
        case .groupchat:
            // MUC: extract nickname from resource part
            let senderNickname: String? = if case let .full(fullJID) = forwarded.message.from {
                fullJID.resourcePart
            } else {
                nil
            }
            return MessageMeta(
                fromJID: senderNickname ?? conversation.jid.description,
                isOutgoing: senderNickname != nil && senderNickname == conversation.roomNickname,
                messageType: conversation.type.rawValue
            )
        case .chat:
            // 1:1 chat: compare bare JIDs
            return MessageMeta(
                fromJID: forwarded.message.from?.bareJID.description ?? accountJID.description,
                isOutgoing: forwarded.message.from?.bareJID == accountJID,
                messageType: forwarded.message.messageType?.rawValue ?? "chat"
            )
        }
    }

    private func findOrCreateConversation(for jid: BareJID, accountID: UUID) async throws -> Conversation {
        let conversations = try await store.fetchConversations(for: accountID)
        if let existing = conversations.first(where: { $0.jid == jid && $0.occupantNickname == nil }) {
            return existing
        }

        let conversation = Conversation(
            id: UUID(),
            accountID: accountID,
            jid: jid,
            type: .chat,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            encryptionEnabled: OMEMOPreferences.shared.encryptByDefault,
            createdAt: Date()
        )
        try await store.upsertConversation(conversation)
        return conversation
    }

    private func findOrCreateGroupConversation(
        for room: BareJID,
        nickname: String?,
        accountID: UUID
    ) async throws -> Conversation {
        let conversations = try await store.fetchConversations(for: accountID)
        if let existing = conversations.first(where: { $0.jid == room && $0.type == .groupchat }) {
            guard let nickname, existing.roomNickname != nickname else { return existing }
            return try await store.updateConversation(existing.id) { $0.roomNickname = nickname } ?? existing
        }

        let conversation = Conversation(
            id: UUID(),
            accountID: accountID,
            jid: room,
            type: .groupchat,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            roomNickname: nickname,
            encryptionEnabled: OMEMOPreferences.shared.encryptByDefault,
            createdAt: Date()
        )
        try await store.upsertConversation(conversation)
        return conversation
    }

    private func conversationID(for from: JID, accountID: UUID, occupantNickname: String? = nil) async -> UUID? {
        await conversation(for: from, accountID: accountID, occupantNickname: occupantNickname)?.id
    }

    /// The conversation a receipt, marker or error from `from` speaks about. A room's occupant writes from the room's
    /// address with their nickname as the resource, so what they send belongs to the private chat with them when there
    /// is one, and never to the private chat with another occupant.
    private func conversation(forSender from: JID, accountID: UUID) async -> Conversation? {
        let bareJID = from.bareJID
        var candidates = openConversations.filter { $0.jid == bareJID && $0.accountID == accountID }
        if candidates.isEmpty {
            candidates = await ((try? store.fetchConversations(for: accountID)) ?? []).filter { $0.jid == bareJID }
        }
        if case let .full(sender) = from, let privateChat = candidates.first(where: { $0.occupantNickname == sender.resourcePart }) {
            return privateChat
        }
        return candidates.first { $0.occupantNickname == nil }
    }

    /// Resolves the conversation for a JID, checking in-memory list first then the store.
    private func conversation(for from: JID, accountID: UUID, occupantNickname: String? = nil) async -> Conversation? {
        let bareJID = from.bareJID
        let predicate: (Conversation) -> Bool = {
            $0.jid == bareJID && $0.accountID == accountID &&
                (occupantNickname == nil || $0.occupantNickname == occupantNickname)
        }
        if let cached = openConversations.first(where: predicate) {
            return cached
        }
        if let chatConv = try? await store.fetchConversation(jid: bareJID.description, type: .chat, accountID: accountID, importSourceJID: nil),
           occupantNickname == nil || chatConv.occupantNickname == occupantNickname {
            return chatConv
        }
        if let groupConv = try? await store.fetchConversation(jid: bareJID.description, type: .groupchat, accountID: accountID, importSourceJID: nil),
           occupantNickname == nil || groupConv.occupantNickname == occupantNickname {
            return groupConv
        }
        return nil
    }
}
