import DuckoXMPP
import Foundation

@MainActor @Observable
public final class AppEnvironment {
    public nonisolated let store: any PersistenceStore
    public nonisolated let transcripts: any TranscriptStore
    public nonisolated let credentialStore: any CredentialStore
    public let accountService: AccountService
    public let chatService: ChatService
    public let presenceService: PresenceService
    public let rosterService: RosterService
    public let fileTransferService: FileTransferService
    public let bookmarksService: BookmarksService
    public let avatarService: AvatarService
    public let profileService: ProfileService
    public let linkPreviewService: LinkPreviewService
    public let omemoService: OMEMOService

    private let filterPipeline: MessageFilterPipeline
    private let onExternalEvent: (@Sendable (XMPPEvent, UUID) -> Void)?
    /// One-shot tasks not tied to an account (filter registration, test seam), each keyed by a UUID and
    /// self-removing on completion. Drained by `shutdown(within:)` so they can't race teardown.
    private var pendingTasks: [UUID: Task<Void, Never>] = [:]
    /// Per-event dispatch fan-out tasks, keyed by account so a user-initiated disconnect can cancel just that
    /// account's in-flight events (`cancelDispatchTasks(for:)`) before purging its state. Each self-removes on
    /// completion; all are drained by `shutdown(within:)`.
    private var dispatchTasksByAccount: [UUID: [UUID: Task<Void, Never>]] = [:]

    public init(
        store: any PersistenceStore,
        transcripts: any TranscriptStore,
        credentialStore: (any CredentialStore)? = nil,
        omemoStore: (any OMEMOStore)? = nil,
        linkPreviewFetcher: any LinkPreviewFetcher = NoOpLinkPreviewFetcher(),
        downloadsDirectory: URL = .downloadsDirectory,
        clientFactory: any XMPPClientFactory = DefaultXMPPClientFactory(),
        onExternalEvent: (@Sendable (XMPPEvent, UUID) -> Void)? = nil
    ) {
        let resolvedCredentialStore = credentialStore ?? CredentialStoreFactory.makeDefault()

        let pipeline = MessageFilterPipeline()
        let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: pipeline)
        let presenceService = PresenceService()
        let rosterService = RosterService(store: store)
        let accountService = AccountService(store: store, credentialStore: resolvedCredentialStore, clientFactory: clientFactory)
        let bookmarksService = BookmarksService()
        bookmarksService.autoJoinEnabled = true
        let avatarService = AvatarService(store: store)
        let profileService = ProfileService()
        let fileTransferService = FileTransferService(downloadsDirectory: downloadsDirectory)
        let linkPreviewService = LinkPreviewService(fetcher: linkPreviewFetcher, store: store)
        let omemoService = OMEMOService(omemoStore: omemoStore ?? NoOpOMEMOStore())

        self.store = store
        self.transcripts = transcripts
        self.credentialStore = resolvedCredentialStore
        self.accountService = accountService
        self.chatService = chatService
        self.presenceService = presenceService
        self.rosterService = rosterService
        self.bookmarksService = bookmarksService
        self.avatarService = avatarService
        self.profileService = profileService
        self.fileTransferService = fileTransferService
        self.linkPreviewService = linkPreviewService
        self.omemoService = omemoService
        self.filterPipeline = pipeline
        self.onExternalEvent = onExternalEvent

        wireServices()
        wireEventDispatch()
        registerFilters()
    }

    private func wireServices() {
        chatService.setAccountService(accountService)
        chatService.setOMEMOService(omemoService)
        presenceService.setAccountService(accountService)
        rosterService.setAccountService(accountService)
        rosterService.setPresenceService(presenceService)
        presenceService.onContactWentOffline = { [weak rosterService] jid, accountID in
            await rosterService?.updateLastSeen(jid: jid, date: Date(), accountID: accountID)
        }
        bookmarksService.setAccountService(accountService)
        bookmarksService.setChatService(chatService)
        avatarService.setAccountService(accountService)
        avatarService.setRosterService(rosterService)
        avatarService.setPresenceService(presenceService)
        profileService.setAccountService(accountService)
        fileTransferService.setAccountService(accountService)
        fileTransferService.setChatService(chatService)
        omemoService.setAccountService(accountService)
        omemoService.setChatService(chatService)
        accountService.setOMEMOService(omemoService)
        accountService.onRosterSessionStarted = { [weak rosterService] accountID, sessionID, client in
            rosterService?.beginSession(accountID: accountID, sessionID: sessionID, client: client)
        }
        accountService.onRosterSessionEnded = { [weak rosterService] accountID, sessionID in
            rosterService?.endSession(accountID: accountID, sessionID: sessionID)
        }
        accountService.onRequestedDisconnect = { [weak self] accountID in
            guard let self else { return }
            cancelDispatchTasks(for: accountID)
            rosterService.purgeAccount(accountID)
            presenceService.purgeAccount(accountID)
            chatService.purgeAccount(accountID)
            bookmarksService.purgeAccount(accountID)
            avatarService.purgeAccount(accountID)
            profileService.purgeAccount(accountID)
            fileTransferService.purgeAccount(accountID)
        }
    }

    /// Fans each account event out to the consuming services on a stored, self-removing task so the
    /// per-event dispatch can be drained on shutdown. Assigned after stored-property initialization so the
    /// closure reaches the services through `self`.
    private func wireEventDispatch() {
        accountService.onEvent = { [weak self] event, accountID in
            guard let self else { return }
            rosterService.receiveRosterEvent(event, accountID: accountID)
            let taskID = UUID()
            dispatchTasksByAccount[accountID, default: [:]][taskID] = Task { @MainActor [weak self] in
                defer { self?.dispatchTasksByAccount[accountID]?[taskID] = nil }
                guard let self else { return }
                // Shutdown and user-initiated disconnect both cancel this task. Re-check between every handler:
                // bailing before fan-out stops a cancelled dispatch from spawning child work after a `shutdown`
                // drain snapshot, and re-checking between awaits stops a task that was suspended inside one
                // handler from resuming into later handlers and repopulating per-account state a
                // `disconnect`/`deleteAccount` purge just cleared.
                if Task.isCancelled { return }
                await chatService.handleEvent(event, accountID: accountID)
                if Task.isCancelled { return }
                await presenceService.handleEvent(event, accountID: accountID)
                if Task.isCancelled { return }
                await rosterService.handleEvent(event, accountID: accountID)
                if Task.isCancelled { return }
                fileTransferService.handleJingleEvent(event, accountID: accountID)
                if Task.isCancelled { return }
                await bookmarksService.handleEvent(event, accountID: accountID)
                if Task.isCancelled { return }
                await avatarService.handleEvent(event, accountID: accountID)
                if Task.isCancelled { return }
                await omemoService.handleEvent(event, accountID: accountID)
            }
            onExternalEvent?(event, accountID)
        }
    }

    // MARK: - Shutdown

    /// Cancels and bounded-awaits the fire-and-forget service tasks spawned outside the account-teardown
    /// path (per-event dispatch, filter registration, ChatService MAM/nick/typing-debounce tasks,
    /// FileTransferService Jingle tasks). Does not disconnect accounts — that stays with
    /// `AccountService.disconnectAll`.
    public func shutdown(within deadline: Duration) async {
        let tasks = takePendingTasks()
            + chatService.takePendingTasks()
            + fileTransferService.takePendingTasks()
            + rosterService.takePendingTasks()
        for task in tasks {
            task.cancel()
        }
        await runBounded(within: deadline) {
            for task in tasks {
                _ = await task.value
            }
        }
    }

    /// Returns this environment's in-flight event/filter task handles and clears the stores, so
    /// `shutdown(within:)` operates on a captured snapshot rather than the live stores.
    private func takePendingTasks() -> [Task<Void, Never>] {
        var tasks = Array(pendingTasks.values)
        pendingTasks.removeAll()
        for perAccount in dispatchTasksByAccount.values {
            tasks.append(contentsOf: perAccount.values)
        }
        dispatchTasksByAccount.removeAll()
        return tasks
    }

    /// Cancels and drops every in-flight event-dispatch task for `accountID`. Called from
    /// `AccountService.onRequestedDisconnect` so a queued/in-flight stale event can't repopulate per-account
    /// state that the user-initiated disconnect is about to purge. A not-yet-started task bails at its
    /// top-level `Task.isCancelled` check; an already-suspended roster handler is additionally caught by the
    /// per-account load-generation guard.
    private func cancelDispatchTasks(for accountID: UUID) {
        guard let tasks = dispatchTasksByAccount.removeValue(forKey: accountID) else { return }
        for task in tasks.values {
            task.cancel()
        }
    }

    #if DEBUG
        /// Test seam: lets `shutdown` draining run against a task of controlled duration.
        func registerPendingTaskForTesting(_ task: Task<Void, Never>) {
            pendingTasks[UUID()] = task
        }
    #endif

    // MARK: - Account Teardown

    /// Removes a local account: disconnect, optionally delete transcripts, delete account data.
    /// All steps are fail-safe — errors are suppressed since this is cleanup.
    public func removeAccount(_ id: UUID, includeHistory: Bool) async {
        let accountJID = accountService.accounts.first(where: { $0.id == id })?.jid.description
        await accountService.disconnect(accountID: id)
        if includeHistory {
            try? await chatService.deleteTranscriptsForAccount(id)
            try? await store.deleteConversations(for: id)
        } else if let accountJID {
            try? await store.unlinkConversations(for: id, restoreImportSourceJID: accountJID)
        }
        try? await store.deleteContacts(for: id)
        try? await accountService.deleteAccount(id)
    }

    /// Cancels server-side registration (XEP-0077), then removes the account locally.
    /// Throws only if server-side cancellation fails. Local cleanup is fail-safe.
    public func cancelAccount(_ id: UUID, includeHistory: Bool) async throws {
        try await accountService.cancelRegistration(accountID: id)
        await removeAccount(id, includeHistory: includeHistory)
    }

    // MARK: - Filters

    private func registerFilters() {
        let taskID = UUID()
        pendingTasks[taskID] = Task { [weak self] in
            defer { self?.pendingTasks[taskID] = nil }
            guard let self else { return }
            await filterPipeline.register(StylingFilter())
            await filterPipeline.register(LinkDetectionFilter())
            await filterPipeline.register(EmojiFilter())
            await filterPipeline.register(MentionFilter())
            await filterPipeline.register(LinkPreviewFilter(previewService: linkPreviewService))
        }
    }
}
