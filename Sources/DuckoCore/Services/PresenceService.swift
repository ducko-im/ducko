import CoreGraphics
import DuckoXMPP
import Foundation

@MainActor @Observable
public final class PresenceService {
    public var myPresence: PresenceStatus = .available
    public var myStatusMessage: String?
    private var contactPresencesByAccount: [UUID: [BareJID: PresenceStatus]] = [:]
    private var contactStatusMessagesByAccount: [UUID: [BareJID: String]] = [:]
    private var pendingRequestsByAccount: [UUID: [BareJID]] = [:]

    /// One of a contact's sessions, as its latest presence described it.
    private struct ContactSession {
        var status: PresenceStatus
        var message: String?
        var priority: Int
    }

    /// Every online session of each contact, keyed by resource. A contact running several clients sends presence for
    /// each, so the contact is offline only once the last of them has gone. Presence from a bare JID is kept under the
    /// empty resource.
    private var contactSessionsByAccount: [UUID: [BareJID: [String: ContactSession]]] = [:]
    /// Accounts whose stream dropped and may yet resume. Their contacts' sessions are kept but not shown: a resumed
    /// stream carries on where it left off, so the server replays what was missed rather than sending every presence
    /// again.
    private var suspendedAccounts: Set<UUID> = []

    /// Called when the last of a contact's sessions goes offline.
    var onContactWentOffline: (@MainActor (BareJID, UUID) async -> Void)?

    /// Sparse per-account pins layered over the global `myPresence`/`myStatusMessage`. An account with
    /// an entry broadcasts its own status; any global change wipes the whole map (Adium's "reset everyone").
    private var presenceOverridesByAccount: [UUID: OwnPresenceOverride] = [:]

    private struct OwnPresenceOverride {
        var status: PresenceStatus
        var message: String?
    }

    /// Cross-account merge of every account's peer presences (last-account-wins on JID collision).
    /// Stored (not computed) so `@Observable` tracks it and the merge runs once per mutation, not per read;
    /// the per-account fast path stays `presence(for:accountID:)`. Maintained by the rebuild helpers below.
    public private(set) var contactPresences: [BareJID: PresenceStatus] = [:]

    /// Cross-account merge of every account's peer status messages, the structural twin of `contactPresences`.
    /// Stored for the same reason; the per-account fast path stays `statusMessage(for:accountID:)`.
    public private(set) var contactStatusMessages: [BareJID: String] = [:]

    public func statusMessage(for jid: BareJID) -> String? {
        // Search per-account directly rather than materializing the merged dictionary
        // for a single-key read — this runs per contact row on every roster render.
        for messages in contactStatusMessagesByAccount.values {
            if let message = messages[jid] { return message }
        }
        return nil
    }

    /// Account-scoped presence lookup. Prefer this when the account is known: the merged
    /// `contactPresences` collapses every account's map last-account-wins on JID collision,
    /// so it resolves the wrong account when the same peer JID is on two.
    public func presence(for jid: BareJID, accountID: UUID) -> PresenceStatus? {
        contactPresencesByAccount[accountID]?[jid]
    }

    /// Account-scoped status-message lookup. Mirror of `presence(for:accountID:)`.
    public func statusMessage(for jid: BareJID, accountID: UUID) -> String? {
        contactStatusMessagesByAccount[accountID]?[jid]
    }

    /// Read from the kept sessions rather than from what is shown, so it holds while the account's stream is suspended.
    private func hasOnlineSession(_ jid: BareJID, accountID: UUID) -> Bool {
        contactSessionsByAccount[accountID]?[jid] != nil
    }

    public var pendingSubscriptionRequests: [BareJID] {
        pendingRequestsByAccount.values.flatMap(\.self)
    }

    public enum PresenceStatus: String, Sendable, CaseIterable {
        case available, away, xa, dnd, offline

        /// User-selectable presences in canonical `allCases` order, excluding
        /// `offline` (a disconnected state rather than a status picked alongside
        /// a custom message). Menus that can also go offline iterate the full
        /// `allCases` instead.
        public static let selectableCases: [PresenceStatus] = allCases.filter { $0 != .offline }

        public var displayName: String {
            switch self {
            case .available: "Available"
            case .away: "Away"
            case .xa: "Extended Away"
            case .dnd: "Do Not Disturb"
            case .offline: "Offline"
            }
        }
    }

    private weak var accountService: AccountService?
    private var idleMonitorTask: Task<Void, Never>?
    private var autoAwayActive: Bool = false
    private var previousPresence: PresenceStatus?
    /// Bumped by every global pick. A pick's per-account connects and teardowns start only while it is the latest, so
    /// an older pick still working through its accounts can't undo a newer one.
    private var globalPickGeneration = 0
    private let idleTimeSource: any IdleTimeSource

    public init(idleTimeSource: any IdleTimeSource = SystemIdleTimeSource()) {
        self.idleTimeSource = idleTimeSource
    }

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    public enum PresenceServiceError: Error, LocalizedError {
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

    /// Broadcasts on an already-connected account. Use `applyPresence` when reconnect may be needed.
    public func setPresence(_ status: PresenceStatus, message: String?, accountID: UUID) async {
        cancelAutoAway()
        myPresence = status
        myStatusMessage = message
        await sendPresence(accountID: accountID)
    }

    /// Sends directed presence to a specific JID, using the account's effective show/status so a directed
    /// presence from an overridden account matches its broadcast status.
    public func sendDirectedPresence(to jidString: String, accountID: UUID) async throws {
        guard let jid = JID.parse(jidString) else { throw PresenceServiceError.invalidJID(jidString) }
        guard let client = accountService?.connectedClient(for: accountID) else { throw PresenceServiceError.notConnected(accountID) }
        guard let presenceModule = await client.module(ofType: PresenceModule.self) else { return }

        try await presenceModule.sendDirectedPresence(to: jid, show: effectiveShow(for: accountID), status: effectivePresence(for: accountID).message)
    }

    /// Updates `myPresence` / `myStatusMessage` synchronously (views see the change before any await). Reads
    /// `AccountService.connectionStates` rather than `myPresence` to decide reconnect — a `Picker` binding may have
    /// already mutated `myPresence`.
    public func applyPresence(
        _ status: PresenceStatus,
        message: String?,
        accountID: UUID,
        connect: @escaping @MainActor (UUID) async throws -> Void,
        disconnect: @escaping @MainActor (UUID) async -> Void
    ) async {
        if status == .offline {
            goOffline(accountID: accountID)
            await disconnect(accountID)
        } else {
            cancelAutoAway()
            let isDisconnected = isAccountDisconnected(accountID: accountID)
            myPresence = status
            myStatusMessage = message
            if isDisconnected {
                try? await connect(accountID)
            }
            await sendPresence(accountID: accountID)
        }
    }

    /// Sets the global status and broadcasts it to every online account, clearing any per-account overrides
    /// first. Going online connects every disconnected enabled account, including one taken offline on its own, since
    /// `connectOnLaunch` governs only startup. Going offline tears down every account that isn't already disconnected,
    /// including `.connecting` and reconnecting (`.error`) ones.
    public func applyGlobalPresence(
        _ status: PresenceStatus,
        message: String?,
        connect: @escaping @MainActor (UUID) async throws -> Void,
        disconnect: @escaping @MainActor (UUID) async -> Void
    ) async {
        cancelAutoAway()
        presenceOverridesByAccount.removeAll()
        myPresence = status
        myStatusMessage = status == .offline ? nil : message
        globalPickGeneration += 1
        let generation = globalPickGeneration

        if status == .offline {
            // Concurrent, so one stalled server can't keep the accounts after it online.
            let live = (accountService?.accounts ?? []).filter { Self.needsTeardown(state: accountService?.connectionStates[$0.id]) }
            await withTaskGroup(of: Void.self) { group in
                for account in live {
                    group.addTask {
                        await self.performIfLatest(generation) { await disconnect(account.id) }
                    }
                }
            }
        } else {
            // The broadcast runs alongside the connects, so a stalled server can't hold back the accounts already
            // online; a newly connected account picks up the held presence in `reapplyHeldPresenceAfterReconnect`.
            // Skip accounts already connecting, so an in-flight connect isn't torn down and restarted.
            let disconnected = (accountService?.enabledAccounts ?? []).filter { isAccountDisconnected(accountID: $0.id) }
            await withTaskGroup(of: Void.self) { group in
                for account in disconnected {
                    group.addTask {
                        await self.performIfLatest(generation) { try? await connect(account.id) }
                    }
                }
                await broadcastPresenceToConnectedAccounts()
            }
        }
    }

    /// Runs a global pick's per-account `action` only if `generation` is still the latest pick. The check and the
    /// action's synchronous start (which publishes `.connecting` or `.disconnected`) share one main-actor turn, so a
    /// newer pick either skips this action or sees its effect.
    private func performIfLatest(_ generation: Int, _ action: @MainActor () async -> Void) async {
        guard generation == globalPickGeneration else { return }
        await action()
    }

    /// Pins `accountID` to its own status, layered over the global value. Offline is not modeled as an override:
    /// it disconnects the account (the submenu derives Offline from connection state), and any prior override is
    /// dropped so a later reconnect doesn't resurface it.
    public func applyAccountPresence(
        _ status: PresenceStatus,
        message: String?,
        accountID: UUID,
        connect: @escaping @MainActor (UUID) async throws -> Void,
        disconnect: @escaping @MainActor (UUID) async -> Void
    ) async {
        if status == .offline {
            presenceOverridesByAccount.removeValue(forKey: accountID)
            await disconnect(accountID)
        } else {
            presenceOverridesByAccount[accountID] = OwnPresenceOverride(status: status, message: message)
            if isAccountDisconnected(accountID: accountID) {
                try? await connect(accountID)
            }
            await sendPresence(accountID: accountID)
        }
    }

    /// Drops the pending subscription request from `jid` after the user has
    /// acted on it (approved, denied, or dismissed).
    public func removeSubscriptionRequest(_ jid: BareJID, accountID: UUID) {
        pendingRequestsByAccount[accountID]?.removeAll { $0 == jid }
    }

    /// Marks local presence offline only. Caller must invoke `AccountService.disconnect` so the server sees the unavailable stanza.
    public func goOffline(accountID _: UUID) {
        cancelAutoAway()
        myPresence = .offline
        myStatusMessage = nil
    }

    /// Cancels a pending auto-away restore. Any deliberate presence change (offline, away, a custom status)
    /// supersedes the held auto-away state, so a later idle-return must not flip back to it and broadcast
    /// that stale presence to the still-connected accounts.
    private func cancelAutoAway() {
        autoAwayActive = false
        previousPresence = nil
    }

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case .connected:
            // A fresh stream is sent every contact's presence anew, so nothing kept from the last one applies.
            dropContactSessions(for: accountID)
            await reapplyHeldPresenceAfterReconnect(accountID: accountID)
        case .streamResumed:
            resumeContactSessions(for: accountID)
        case let .presenceUpdated(from, presence):
            if handlePresenceUpdated(from: from, presence: presence, accountID: accountID) {
                await onContactWentOffline?(from.bareJID, accountID)
            }
        case let .presenceSubscriptionRequest(from):
            handleSubscriptionRequest(from: from, accountID: accountID)
        case let .disconnected(reason):
            // An intentional teardown drops the kept sessions and the per-account override. A stream blip keeps
            // both, so a resumed stream shows its contacts again and a pinned status isn't silently lost.
            if case .requested = reason {
                dropContactSessions(for: accountID)
                presenceOverridesByAccount.removeValue(forKey: accountID)
            } else {
                suspendedAccounts.insert(accountID)
            }
            clearContactState(for: accountID)
        case .presenceSubscriptionApproved, .presenceSubscriptionRevoked:
            break
        case .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterUpdated,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived, .roomDestroyed,
             .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .jingleChecksumReceived,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced, .omemoRecipientsPartial,
             .oobIQOfferReceived, .serviceOutageReceived:
            break
        }
    }

    /// Re-broadcasts a non-default held presence after an automatic reconnect. `PresenceModule.handleConnect()`
    /// sends a blank available presence on every fresh connect, which would otherwise silently revert a chosen
    /// away/dnd/available-with-message back to plain available for peers mid-session. Skips plain
    /// default-available (already covered by `handleConnect`) and `.offline` (short-circuits in `sendPresence`).
    /// `.streamResumed` does not reapply the held presence — a resumed session skips `handleConnect()`, so presence
    /// is never reset.
    private func reapplyHeldPresenceAfterReconnect(accountID: UUID) async {
        guard shouldReapplyHeldPresence(accountID: accountID) else { return }
        guard let client = accountService?.connectedClient(for: accountID) else { return }
        // `.connected` is yielded before `PresenceModule.handleConnect()` sends its blank-available stanza, so
        // gate on the initial presence before re-broadcasting or it would just be overwritten.
        await client.awaitInitialPresenceSent()
        // Across the await the original client can disconnect and a replacement enter `.connected`; re-verify the
        // same instance and re-check the guard so a stale reapply can't clobber the new client's presence.
        guard accountService?.connectedClient(for: accountID) === client, shouldReapplyHeldPresence(accountID: accountID) else { return }
        await sendPresence(accountID: accountID)
    }

    /// Reads the account's *effective* presence so an account whose global is plain available but which carries a
    /// non-offline override still re-broadcasts (and replaces the blank-available stanza) after reconnect.
    private func shouldReapplyHeldPresence(accountID: UUID) -> Bool {
        let effective = effectivePresence(for: accountID)
        return effective.status != .offline && (effective.status != .available || effective.message != nil)
    }

    // MARK: - Idle Monitoring

    /// Opt-in idle monitoring (GUI calls this, CLI doesn't). A single global
    /// monitor that, on each transition, broadcasts to every connected account.
    public func startIdleMonitoring(timeout: TimeInterval = 300) {
        stopIdleMonitoring()

        idleMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                await applyIdleTransition(idleTime: idleTimeSource.secondsSinceLastUserInput(), timeout: timeout)
            }
        }
    }

    public func stopIdleMonitoring() {
        idleMonitorTask?.cancel()
        idleMonitorTask = nil
    }

    /// Applies one idle poll's state transition. Activates auto-away once idle past `timeout` — but never for
    /// a user who is deliberately `.offline` — and restores the held presence on the return to activity. Both
    /// transitions broadcast to every connected account.
    func applyIdleTransition(idleTime: TimeInterval, timeout: TimeInterval) async {
        if idleTime >= timeout, !autoAwayActive, myPresence != .offline {
            previousPresence = myPresence
            autoAwayActive = true
            myPresence = .away
            await broadcastPresenceToConnectedAccounts()
        } else if idleTime < timeout, autoAwayActive {
            autoAwayActive = false
            myPresence = previousPresence ?? .available
            previousPresence = nil
            await broadcastPresenceToConnectedAccounts()
        }
    }

    /// Broadcasts the current `myPresence` to every connected account, so idle
    /// auto-away/return moves all accounts together. Reuses the per-account
    /// `sendPresence`, which short-circuits on `.offline` or a missing client.
    func broadcastPresenceToConnectedAccounts() async {
        guard let accountService else { return }
        for account in accountService.accounts where accountService.connectedClient(for: account.id) != nil {
            await sendPresence(accountID: account.id)
        }
    }

    private func isAccountDisconnected(accountID: UUID) -> Bool {
        Self.isDisconnected(state: accountService?.connectionStates[accountID])
    }

    /// Classifies a connection state for reconnect. `nil` (no service wired) and `.error` both count as disconnected
    /// so test harnesses without `AccountService` and error-state retries exercise the connect path.
    nonisolated static func isDisconnected(state: AccountService.ConnectionState?) -> Bool {
        guard let state else { return true }
        return switch state {
        case .disconnected, .error: true
        case .connecting, .connected: false
        }
    }

    /// Classifies a connection state for going offline: a live, in-flight, or reconnecting (`.error`) connection has
    /// something to tear down.
    nonisolated static func needsTeardown(state: AccountService.ConnectionState?) -> Bool {
        guard let state else { return false }
        return switch state {
        case .connected, .connecting, .error: true
        case .disconnected: false
        }
    }

    /// Applies one presence stanza to the contact's sessions. Returns whether it took the contact's last session offline.
    private func handlePresenceUpdated(from: JID, presence: XMPPPresence, accountID: UUID) -> Bool {
        let bareJID = from.bareJID
        let wasOnline = hasOnlineSession(bareJID, accountID: accountID)
        let status = mapPresence(presence)
        let resource: String? = switch from {
        case let .full(fullJID): fullJID.resourcePart
        case .bare: nil
        }
        if status != .offline {
            // Whitespace-only text counts as no status.
            let trimmedStatus = presence.status?.trimmingCharacters(in: .whitespacesAndNewlines)
            contactSessionsByAccount[accountID, default: [:]][bareJID, default: [:]][resource ?? ""] = ContactSession(
                status: status,
                message: trimmedStatus?.isEmpty == false ? trimmedStatus : nil,
                priority: presence.priority
            )
        } else if let resource {
            contactSessionsByAccount[accountID]?[bareJID]?.removeValue(forKey: resource)
            if contactSessionsByAccount[accountID]?[bareJID]?.isEmpty == true {
                contactSessionsByAccount[accountID]?.removeValue(forKey: bareJID)
            }
        } else {
            // Unavailable from the bare JID speaks for every session the contact had.
            contactSessionsByAccount[accountID]?.removeValue(forKey: bareJID)
        }

        // Synchronous handler (no store await to bracket), so the caches are recomputed inline — no
        // load-generation guard is needed here, unlike the suspending roster-load handlers.
        if !suspendedAccounts.contains(accountID), publishPresence(of: bareJID, accountID: accountID) {
            rebuildMergedContactCaches()
        }
        return wasOnline && !hasOnlineSession(bareJID, accountID: accountID)
    }

    /// The resources of a contact's online sessions, in the order the contact shows them.
    func onlineResources(of jid: BareJID, accountID: UUID) -> [String] {
        (contactSessionsByAccount[accountID]?[jid] ?? [:]).sorted(by: Self.isShownBefore).map(\.key).filter { !$0.isEmpty }
    }

    public func onlineResources(ofJIDString jidString: String, accountID: UUID) -> [String] {
        guard let jid = BareJID.parse(jidString) else { return [] }
        return onlineResources(of: jid, accountID: accountID)
    }

    /// Sets what one contact shows from its sessions and reports whether that changed, so a stanza from a session that
    /// is not the one shown costs no republish.
    private func publishPresence(of jid: BareJID, accountID: UUID) -> Bool {
        let shown = contactSessionsByAccount[accountID]?[jid]?.min(by: Self.isShownBefore)?.value
        guard contactPresencesByAccount[accountID]?[jid] != shown?.status
            || contactStatusMessagesByAccount[accountID]?[jid] != shown?.message else { return false }
        contactPresencesByAccount[accountID, default: [:]][jid] = shown?.status
        contactStatusMessagesByAccount[accountID, default: [:]][jid] = shown?.message
        return true
    }

    /// The session a contact shows is its highest-priority one, ties going to the most available. The resource name
    /// settles what is still equal, so the choice does not depend on dictionary order.
    private static func isShownBefore(
        _ lhs: (key: String, value: ContactSession), _ rhs: (key: String, value: ContactSession)
    ) -> Bool {
        (-lhs.value.priority, availabilityRank(of: lhs.value.status), lhs.key)
            < (-rhs.value.priority, availabilityRank(of: rhs.value.status), rhs.key)
    }

    private static func availabilityRank(of status: PresenceStatus) -> Int {
        switch status {
        case .available: 0
        case .away: 1
        case .xa: 2
        case .dnd: 3
        case .offline: 4
        }
    }

    /// Shows a resumed account's contacts again, as their kept sessions and any presence replayed since describe them.
    private func resumeContactSessions(for accountID: UUID) {
        guard suspendedAccounts.remove(accountID) != nil else { return }
        for jid in (contactSessionsByAccount[accountID] ?? [:]).keys {
            _ = publishPresence(of: jid, accountID: accountID)
        }
        rebuildMergedContactCaches()
    }

    private func dropContactSessions(for accountID: UUID) {
        contactSessionsByAccount.removeValue(forKey: accountID)
        suspendedAccounts.remove(accountID)
    }

    // MARK: - Lifecycle

    /// Drops one account's presence state — including any per-account override — on a lifecycle teardown
    /// that bypasses the `.disconnected` event handler (user-initiated `AccountService.disconnect`, account
    /// delete). A stream-blip reconnect goes through `handleDisconnect` and never calls this, so a pinned
    /// override survives a blip.
    func purgeAccount(_ accountID: UUID) {
        dropContactSessions(for: accountID)
        clearContactState(for: accountID)
        presenceOverridesByAccount.removeValue(forKey: accountID)
    }

    // MARK: - Presence Cache

    /// Drops what one account shows of its peers (presence, status, subscription requests) and republishes the merged
    /// caches. Shared by the `.disconnected` handler and `purgeAccount` so the two stay in lockstep.
    private func clearContactState(for accountID: UUID) {
        contactPresencesByAccount.removeValue(forKey: accountID)
        contactStatusMessagesByAccount.removeValue(forKey: accountID)
        pendingRequestsByAccount.removeValue(forKey: accountID)
        rebuildMergedContactCaches()
    }

    private func rebuildMergedContactCaches() {
        rebuildContactPresences()
        rebuildContactStatusMessages()
    }

    private func rebuildContactPresences() {
        contactPresences = contactPresencesByAccount.values.reduce(into: [:]) { result, dict in
            result.merge(dict) { _, new in new }
        }
    }

    private func rebuildContactStatusMessages() {
        contactStatusMessages = contactStatusMessagesByAccount.values.reduce(into: [:]) { result, dict in
            result.merge(dict) { _, new in new }
        }
    }

    private func handleSubscriptionRequest(from: BareJID, accountID: UUID) {
        let requests = pendingRequestsByAccount[accountID] ?? []
        if !requests.contains(from) {
            pendingRequestsByAccount[accountID, default: []].append(from)
        }
    }

    private func mapPresence(_ presence: XMPPPresence) -> PresenceStatus {
        if presence.presenceType == .unavailable {
            return .offline
        }
        guard let show = presence.show else {
            return .available
        }
        return switch show {
        case .chat: .available
        case .away: .away
        case .xa: .xa
        case .dnd: .dnd
        }
    }

    public var currentShow: XMPPPresence.Show? {
        Self.show(for: myPresence)
    }

    /// The presence pinned for `accountID`, falling back to the global values when no override is set.
    /// Every outbound presence path reads this so an overridden account never reverts to global.
    /// `displayedPresence(for:)` builds on it for what the UI shows.
    public func effectivePresence(for accountID: UUID) -> (status: PresenceStatus, message: String?) {
        if let override = presenceOverridesByAccount[accountID] {
            return (override.status, override.message)
        }
        return (myPresence, myStatusMessage)
    }

    /// The status to show for `accountID`: its effective status while that account is connected, and `.offline`
    /// otherwise, so a header can't claim a presence the server never saw. Display-only — what an account broadcasts
    /// still comes from `effectivePresence(for:)`.
    public func displayedPresence(for accountID: UUID?) -> (status: PresenceStatus, message: String?) {
        guard let accountID, case .connected? = accountService?.connectionStates[accountID] else {
            return (.offline, nil)
        }
        return effectivePresence(for: accountID)
    }

    /// Every enabled account's displayed presence, in `accounts` order.
    public func displayedPresences() -> [(status: PresenceStatus, message: String?)] {
        (accountService?.enabledAccounts ?? []).map { displayedPresence(for: $0.id) }
    }

    /// The effective `Show` for an account, mirroring `currentShow` over `effectivePresence(for:)`.
    func effectiveShow(for accountID: UUID) -> XMPPPresence.Show? {
        Self.show(for: effectivePresence(for: accountID).status)
    }

    private static func show(for status: PresenceStatus) -> XMPPPresence.Show? {
        switch status {
        case .available, .offline: nil
        case .away: .away
        case .xa: .xa
        case .dnd: .dnd
        }
    }

    /// Re-broadcasts an account's effective presence. `AvatarService` routes its re-broadcasts through this so
    /// an avatar/vCard/MUC update never clobbers an overridden account back to the global status.
    func resendEffectivePresence(accountID: UUID) async {
        await sendPresence(accountID: accountID)
    }

    private func sendPresence(accountID: UUID) async {
        let effective = effectivePresence(for: accountID)
        guard effective.status != .offline else { return }
        guard let client = accountService?.connectedClient(for: accountID) else { return }
        guard let presenceModule = await client.module(ofType: PresenceModule.self) else { return }

        try? await presenceModule.broadcastPresence(show: effectiveShow(for: accountID), status: effective.message)
    }
}

// MARK: - Idle Time Source

public protocol IdleTimeSource: Sendable {
    func secondsSinceLastUserInput() -> TimeInterval
}

public struct SystemIdleTimeSource: IdleTimeSource {
    public init() {}

    public func secondsSinceLastUserInput() -> TimeInterval {
        // Check both mouse and keyboard activity; return the shorter idle time.
        let mouse = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
        let keyboard = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        return min(mouse, keyboard)
    }
}
