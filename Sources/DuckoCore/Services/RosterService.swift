import DuckoXMPP
import Foundation

@MainActor @Observable
public final class RosterService {
    /// Per-account groups. `groups` is the rebuilt merge of every slot, so a roster load on one
    /// account never drops another's. Source of truth behind the published merge — mutate slots
    /// through `setGroups`/`clearGroups` so the cache stays current.
    private var groupsByAccount: [UUID: [ContactGroup]] = [:]
    /// Load-generation counter, bumped whenever an account's session ends. A suspended roster-load handler
    /// captures the generation before its store read and re-checks it before writing or publishing, so an ended
    /// session's handler can't write after it. Mirrors `OMEMOService.seenDeviceLoadGeneration`.
    private var groupsLoadGeneration: [UUID: UInt64] = [:]
    /// Each account's groups as the contact list showed them before the account left it, disabled or deleted. An open
    /// chat still names the contact and shows their photo from here until the roster loads again.
    private var groupsBeforeRemoval: [UUID: [ContactGroup]] = [:]
    /// Each connected account's block list (XEP-0191), as the server last announced it.
    private var blockListByAccount: [UUID: [JID]] = [:]

    /// Per-account groups merged into one section per name (Adium-style), so a
    /// multi-account setup doesn't show duplicate same-named sections. Each row
    /// keeps its account-scoped selection identity via `Contact.accountID`, and the
    /// name is a safe `ForEach`/`onlineCounts` id because names are unique post-merge.
    /// Stored (not computed) so `@Observable` tracks it and the merge runs once per mutation, not per read.
    public private(set) var groups: [ContactGroup] = []

    private var synchronization: [UUID: RosterSynchronization] = [:]
    private var loadRevisions: [UUID: UInt64] = [:]
    private var retiredTasks: [UUID: Task<Void, Never>] = [:]
    private let synchronizationSleep: @Sendable (Duration) async throws -> Void
    private let synchronizationNow: @Sendable () -> ContinuousClock.Instant
    private let store: any PersistenceStore
    private weak var accountService: AccountService?
    private weak var presenceService: PresenceService?

    public convenience init(store: any PersistenceStore) {
        self.init(store: store, synchronizationSleep: { try await Task.sleep(for: $0) }, synchronizationNow: { .now })
    }

    init(store: any PersistenceStore, synchronizationSleep: @Sendable @escaping (Duration) async throws -> Void,
         synchronizationNow: @Sendable @escaping () -> ContinuousClock.Instant) {
        self.store = store
        self.synchronizationSleep = synchronizationSleep
        self.synchronizationNow = synchronizationNow
    }

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    func setPresenceService(_ service: PresenceService) {
        presenceService = service
    }

    public enum RosterServiceError: Error, LocalizedError {
        case notConnected(UUID)
        case invalidJID(String)

        public var errorDescription: String? {
            switch self {
            case .notConnected: notConnectedDescription
            case let .invalidJID(string): "Invalid JID: \(string)"
            }
        }
    }

    // MARK: - Public API

    public func contact(jidString: String) -> Contact? {
        Self.contact(jidString: jidString, in: groups)
    }

    /// Account-scoped lookup. Prefer this when the account is known: `contact(jidString:)`
    /// returns the first match across all accounts, so it resolves the wrong account when
    /// the same JID is on two.
    public func contact(jidString: String, accountID: UUID) -> Contact? {
        groupsByAccount[accountID].flatMap { Self.contact(jidString: jidString, in: $0) }
    }

    /// The contact as the roster holds them, or once the account left the contact list, as the list last showed them.
    /// Read only their name and photo from it, since the rest may be out of date.
    public func knownContact(jidString: String, accountID: UUID) -> Contact? {
        contact(jidString: jidString, accountID: accountID)
            ?? groupsBeforeRemoval[accountID].flatMap { Self.contact(jidString: jidString, in: $0) }
    }

    /// The known contact's name for an address that may name one of their devices.
    public func knownContactName(jidString: String, accountID: UUID) -> String? {
        let bareJIDString = JID.parse(jidString)?.bareJID.description ?? jidString
        return knownContact(jidString: bareJIDString, accountID: accountID)?.displayName
    }

    private static func contact(jidString: String, in groups: [ContactGroup]) -> Contact? {
        groups.lazy.flatMap(\.contacts).first { $0.jid.description == jidString }
    }

    /// Accounts whose roster contains `jidString` (a bare JID), deduped so a contact appearing in
    /// multiple groups under one account is counted once. A duplicated JID — `count > 1` — drives
    /// the account indicator shown on roster rows and chat tabs.
    public func accountIDs(forBareJID jidString: String) -> Set<UUID> {
        var result: Set<UUID> = []
        for (accountID, groups) in groupsByAccount
            where groups.contains(where: { $0.contacts.contains { $0.jid.description == jidString } }) {
            result.insert(accountID)
        }
        return result
    }

    /// The account's contacts as the store has them, photos included, whether or not the account is enabled. Unlike
    /// `loadContacts(for:)` it publishes nothing to the contact list.
    public func storedContacts(for accountID: UUID) async -> [Contact] {
        await (try? store.fetchContacts(for: accountID)) ?? []
    }

    public func loadContacts(for accountID: UUID) async throws {
        let generationBeforeAwait = groupsLoadGeneration[accountID, default: 0]
        loadRevisions[accountID, default: 0] &+= 1
        let revision = loadRevisions[accountID]
        let contacts = try await store.fetchContacts(for: accountID)
        guard generationUnchanged(generationBeforeAwait, for: accountID), loadRevisions[accountID] == revision, isListed(accountID) else { return }
        setGroups(ContactGroup.grouping(contacts), for: accountID)
    }

    /// The current content generation for `accountID`. An external caller that mutates a contact and then
    /// refreshes the roster captures this before its first `await`, re-checks it before its own store write, and
    /// reloads via `loadContacts(for:ifGenerationUnchangedSince:)`. A session that ended during the await then has
    /// its change neither written nor republished. Plain `loadContacts` captures a fresh generation of its own, so it
    /// cannot guard a reload after an await.
    public func contentGeneration(for accountID: UUID) -> UInt64 {
        groupsLoadGeneration[accountID, default: 0]
    }

    /// Reloads `accountID`'s contacts only if its content generation is unchanged since `captured`.
    public func loadContacts(for accountID: UUID, ifGenerationUnchangedSince captured: UInt64) async throws {
        guard generationUnchanged(captured, for: accountID) else { return }
        try await loadContacts(for: accountID)
    }

    public func addContact(jid: BareJID, name: String?, groups: [String], accountID: UUID) async throws -> RosterCommandOutcome {
        try await changeContact(operation: .add, jid: jid, name: name, groups: groups, accountID: accountID)
    }

    public func removeContact(_ contact: Contact, accountID: UUID) async throws -> RosterCommandOutcome {
        try await changeContact(operation: .remove, jid: contact.jid, name: nil, groups: [], accountID: accountID)
    }

    public func addContact(jidString: String, name: String?, groups: [String], accountID: UUID) async throws -> RosterCommandOutcome {
        guard let jid = BareJID.parse(jidString) else { throw RosterServiceError.invalidJID(jidString) }
        return try await addContact(jid: jid, name: name, groups: groups, accountID: accountID)
    }

    public func removeContact(jidString: String, accountID: UUID) async throws -> RosterCommandOutcome {
        guard let jid = BareJID.parse(jidString) else { throw RosterServiceError.invalidJID(jidString) }
        return try await changeContact(operation: .remove, jid: jid, name: nil, groups: [], accountID: accountID)
    }

    private func changeContact(operation: RosterCommandOutcome.Operation, jid: BareJID, name: String?, groups: [String], accountID: UUID) async throws -> RosterCommandOutcome {
        guard let client = accountService?.connectedClient(for: accountID), let owner = synchronization[accountID],
              let module = await client.module(ofType: RosterModule.self), synchronization[accountID] === owner else {
            throw RosterCommandError(operation: operation, accountID: accountID, jid: jid.description, status: .notSent, detail: "The account is not connected")
        }
        do {
            try Task.checkCancellation()
        } catch {
            throw RosterCommandError(operation: operation, accountID: accountID, jid: jid.description, status: .notSent, detail: "The action was cancelled")
        }
        let acknowledgedAt: ContinuousClock.Instant
        do {
            acknowledgedAt = switch operation {
            case .add: try await module.addContact(jid: jid, name: name, groups: groups)
            case .remove: try await module.removeContact(jid: jid)
            }
        } catch {
            let stanzaError = error as? XMPPStanzaError
            throw RosterCommandError(operation: operation, accountID: accountID, jid: jid.description, status: stanzaError == nil ? .unconfirmed : .rejected, detail: stanzaError?.displayText ?? error.localizedDescription)
        }
        return await owner.completeMutation(operation: operation, jid: jid, name: name, groups: groups, module: module, acknowledgedAt: acknowledgedAt)
    }

    /// Sends a presence subscription request without touching the roster item. Use for a
    /// contact already in the roster (e.g. subscription `none`/`from`): `addContact` would
    /// send a roster set that overwrites the server-side name and groups.
    public func requestSubscription(jidString: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else { throw RosterServiceError.invalidJID(jidString) }
        guard let client = accountService?.connectedClient(for: accountID) else { throw RosterServiceError.notConnected(accountID) }
        guard let rosterModule = await client.module(ofType: RosterModule.self) else { return }
        try await rosterModule.subscribe(to: jid)
    }

    public func approveSubscription(jidString: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else { throw RosterServiceError.invalidJID(jidString) }
        guard let client = accountService?.connectedClient(for: accountID) else { throw RosterServiceError.notConnected(accountID) }
        guard let rosterModule = await client.module(ofType: RosterModule.self) else { return }
        try await rosterModule.approveSubscription(from: jid)
        presenceService?.removeSubscriptionRequest(jid, accountID: accountID)
    }

    public func denySubscription(jidString: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else { throw RosterServiceError.invalidJID(jidString) }
        guard let client = accountService?.connectedClient(for: accountID) else { throw RosterServiceError.notConnected(accountID) }
        guard let rosterModule = await client.module(ofType: RosterModule.self) else { return }
        try await rosterModule.denySubscription(from: jid)
        presenceService?.removeSubscriptionRequest(jid, accountID: accountID)
    }

    public func renameContact(_ contact: Contact, newAlias: String, accountID: UUID) async throws {
        let generationBeforeAwait = groupsLoadGeneration[accountID, default: 0]
        try await store.updateContactIfExists(contact.id, accountID: accountID, update: .alias(newAlias.isEmpty ? nil : newAlias))
        // A purge during the metadata update would otherwise let the follow-up loadContacts (fresh generation) republish.
        guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
        try await loadContacts(for: accountID)
    }

    func updateLastSeen(jid: BareJID, date: Date, accountID: UUID) async {
        let generationBeforeAwait = groupsLoadGeneration[accountID, default: 0]
        let contacts = await (try? store.fetchContacts(for: accountID)) ?? []
        guard let contact = contacts.first(where: { $0.jid == jid }), generationUnchanged(generationBeforeAwait, for: accountID) else { return }
        try? await store.updateContactIfExists(contact.id, accountID: accountID, update: .lastSeen(date))
        // A purge during the metadata update would otherwise let the follow-up loadContacts (fresh generation) republish.
        guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
        try? await loadContacts(for: accountID)
    }

    // MARK: - Blocking (XEP-0191)

    /// The account's blocked addresses, sorted. A contact reads as blocked only through the entry naming their bare JID.
    public func blockList(for accountID: UUID) -> [BlockListEntry] {
        (blockListByAccount[accountID] ?? []).map(BlockListEntry.init).sorted { $0.jidString < $1.jidString }
    }

    /// Asks the server for the account's block list again.
    @discardableResult
    public func loadBlockList(accountID: UUID) async throws -> [BlockListEntry] {
        let (client, blockingModule) = try await blockingModule(for: accountID)
        let jids = try await blockingModule.loadBlockList()
        if accountService?.connectedClient(for: accountID) === client {
            blockListByAccount[accountID] = jids
        }
        return blockList(for: accountID)
    }

    /// Blocks an address, which may name one device of a contact.
    public func blockContact(jidString: String, accountID: UUID) async throws {
        guard let jid = JID.parse(jidString) else { throw RosterServiceError.invalidJID(jidString) }
        try await blockingModule(for: accountID).module.blockContact(jid: jid)
    }

    /// Unblocks exactly the entry `jidString` names: a contact's bare JID leaves entries for their devices in place.
    public func unblockContact(jidString: String, accountID: UUID) async throws {
        guard let jid = JID.parse(jidString) else { throw RosterServiceError.invalidJID(jidString) }
        try await blockingModule(for: accountID).module.unblockContact(jid: jid)
    }

    private func blockingModule(for accountID: UUID) async throws -> (client: XMPPClient, module: BlockingModule) {
        guard let client = accountService?.connectedClient(for: accountID),
              let module = await client.module(ofType: BlockingModule.self) else { throw RosterServiceError.notConnected(accountID) }
        return (client, module)
    }

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case .rosterUpdated:
            break
        case let .blockListLoaded(jids):
            await handleBlockListLoaded(jids, accountID: accountID)
        case let .contactBlocked(jid):
            await handleBlockStateChanged(jid, isBlocked: true, accountID: accountID)
        case let .contactUnblocked(jid):
            await handleBlockStateChanged(jid, isBlocked: false, accountID: accountID)
        case .disconnected:
            break
        case .connected, .streamResumed, .authenticationFailed, .plainSignInRefused,
             .messageReceived, .presenceReceived, .iqReceived,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived,
             .roomDestroyed, .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .jingleChecksumReceived,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced, .omemoRecipientsPartial, .omemoSetupChanged,
             .oobIQOfferReceived:
            break
        }
    }

    private func handleBlockListLoaded(_ jids: [JID], accountID: UUID) async {
        blockListByAccount[accountID] = jids
        let generationBeforeAwait = groupsLoadGeneration[accountID, default: 0]
        let contacts = await (try? store.fetchContacts(for: accountID)) ?? []
        let blockedSet = Set(jids)
        for contact in contacts {
            let shouldBeBlocked = blockedSet.contains(.bare(contact.jid))
            if contact.isBlocked != shouldBeBlocked {
                // Re-check before each write: the session may have ended during an earlier await.
                guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
                try? await store.updateContactIfExists(contact.id, accountID: accountID, update: .blocked(shouldBeBlocked))
            }
        }
        // Re-check before the republish so a purge during the writes leaves the list as the ended session left it.
        guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
        try? await loadContacts(for: accountID)
    }

    private func handleBlockStateChanged(_ jid: JID, isBlocked: Bool, accountID: UUID) async {
        var blockList = blockListByAccount[accountID] ?? []
        blockList.removeAll { $0 == jid }
        if isBlocked { blockList.append(jid) }
        blockListByAccount[accountID] = blockList
        // An entry naming one device of a contact leaves the contact itself unblocked.
        guard case let .bare(bareJID) = jid else { return }
        let generationBeforeAwait = groupsLoadGeneration[accountID, default: 0]
        let contacts = await (try? store.fetchContacts(for: accountID)) ?? []
        guard let contact = contacts.first(where: { $0.jid == bareJID }), generationUnchanged(generationBeforeAwait, for: accountID) else { return }
        try? await store.updateContactIfExists(contact.id, accountID: accountID, update: .blocked(isBlocked))
        // Re-check before the republish so a purge during the metadata update leaves the list as the ended session left it.
        guard generationUnchanged(generationBeforeAwait, for: accountID) else { return }
        try? await loadContacts(for: accountID)
    }

    // MARK: - Lifecycle

    func beginSession(accountID: UUID, sessionID: UUID, client: XMPPClient) {
        purgeAccount(accountID)
        synchronization[accountID] = RosterSynchronization(accountID: accountID, sessionID: sessionID, store: store, client: client, sleep: synchronizationSleep, now: synchronizationNow) { [weak self] contacts in
            guard let self, synchronization[accountID]?.sessionID == sessionID else { return }
            loadRevisions[accountID, default: 0] &+= 1
            setGroups(ContactGroup.grouping(contacts), for: accountID)
        }
    }

    func endSession(accountID: UUID, sessionID: UUID) {
        guard synchronization[accountID]?.sessionID == sessionID else { return }
        purgeAccount(accountID)
    }

    @discardableResult
    func receiveRosterEvent(_ event: XMPPEvent, accountID: UUID) -> Task<Void, Never>? {
        if case let .rosterUpdated(update) = event {
            return synchronization[accountID]?.receive(update)
        } else if case .streamResumed = event {
            synchronization[accountID]?.resume()
        } else if case .disconnected = event {
            purgeAccount(accountID)
        }
        return nil
    }

    public func synchronizeRoster(accountID: UUID, within duration: Duration = .seconds(15)) async throws -> [Contact] {
        guard let owner = synchronization[accountID] else { throw RosterServiceError.notConnected(accountID) }
        return try await owner.synchronize(within: duration)
    }

    func purgeAccount(_ accountID: UUID) {
        let tasks = synchronization.removeValue(forKey: accountID)?.end() ?? []
        if !tasks.isEmpty {
            let id = UUID()
            retiredTasks[id] = Task { [weak self] in
                for task in tasks {
                    await task.value
                }
                self?.retiredTasks[id] = nil
            }
        }
        blockListByAccount.removeValue(forKey: accountID)
        invalidateLoads(for: accountID)
        // A disabled account connected by hand shows its contacts only while its session lasts.
        if !isListed(accountID) {
            clearGroups(for: accountID)
        }
    }

    /// Takes a disabled or deleted account's contacts off the contact list. A session of an enabled account that merely
    /// ended leaves them listed, shown offline.
    func removeFromContactList(_ accountID: UUID) {
        purgeAccount(accountID)
        clearGroups(for: accountID)
    }

    /// Forgets what the contact list last showed for a deleted account.
    func forgetAccount(_ accountID: UUID) {
        groupsBeforeRemoval.removeValue(forKey: accountID)
    }

    func takePendingTasks() -> [Task<Void, Never>] {
        for accountID in synchronization.keys {
            purgeAccount(accountID)
        }
        let tasks = Array(retiredTasks.values)
        retiredTasks.removeAll()
        return tasks
    }

    // MARK: - Group Cache

    /// Replaces one account's groups slot and republishes the merge. The single landing point for a
    /// per-account roster result so cross-account derived reads stay current.
    private func setGroups(_ groups: [ContactGroup], for accountID: UUID) {
        groupsByAccount[accountID] = groups
        groupsBeforeRemoval.removeValue(forKey: accountID)
        rebuildGroups()
    }

    /// Moves one account's groups slot aside for `knownContact` and republishes the merge.
    private func clearGroups(for accountID: UUID) {
        // A second removal of an account already removed keeps what the list showed before the first.
        guard let groups = groupsByAccount.removeValue(forKey: accountID) else { return }
        groupsBeforeRemoval[accountID] = groups
        rebuildGroups()
    }

    /// Bumps the load generation, so every handler of the ended session that is suspended in a store await bails.
    private func invalidateLoads(for accountID: UUID) {
        groupsLoadGeneration[accountID, default: 0] &+= 1
    }

    /// False for an account known to be disabled, so a store load never lists its contacts.
    private func isListed(_ accountID: UUID) -> Bool {
        accountService?.accounts.first { $0.id == accountID }?.isEnabled != false
    }

    /// True when no `purgeAccount` ran for `accountID` since `captured` was read, so the account's session did not
    /// end during an intervening `store` await.
    private func generationUnchanged(_ captured: UInt64, for accountID: UUID) -> Bool {
        groupsLoadGeneration[accountID, default: 0] == captured
    }

    private func rebuildGroups() {
        var contactsByID: [UUID: Contact] = [:]
        for group in groupsByAccount.values.joined() {
            for contact in group.contacts {
                contactsByID[contact.id] = contact
            }
        }
        groups = ContactGroup.grouping(Array(contactsByID.values))
    }
}
