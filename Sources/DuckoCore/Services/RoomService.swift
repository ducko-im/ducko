import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.rooms")

/// Composite key for the room-join notifier registry.
/// `hash(into:)` is spelled out explicitly so Periphery sees concrete reads of both fields (synthesized `Hashable` was flagged non-deterministically as assign-only).
struct RoomJoinKey: Hashable {
    let accountID: UUID
    let room: BareJID

    func hash(into hasher: inout Hasher) {
        hasher.combine(accountID)
        hasher.combine(room)
    }
}

/// Identity-bearing notifier; cleanup-by-key no-ops when the key now holds a different id.
struct RoomJoinNotifier {
    let id: UUID
    let continuation: AsyncStream<Void>.Continuation
}

@MainActor @Observable
final class RoomService {
    private typealias ChatServiceError = ChatService.ChatServiceError
    private var roomParticipants: [RoomJoinKey: [RoomParticipant]] = [:]
    private(set) var pendingInvites: [PendingRoomInvite] = []
    private var newlyCreatedRoomKeys: Set<RoomJoinKey> = []
    private var roomFlags: [RoomJoinKey: Set<RoomFlag>] = [:]
    private(set) var roomJoinNotifiers: [RoomJoinKey: RoomJoinNotifier] = [:]
    /// Rooms whose leave the client did not take for lack of a connection. A resumed stream is still in them.
    private var pendingLeaves: Set<RoomJoinKey> = []
    private let store: any PersistenceStore
    private weak var accountService: AccountService?
    private let ensureConversation: (BareJID, String?, UUID) async throws -> Void
    private let conversation: (BareJID, UUID) -> Conversation?
    private let didUpdateConversation: (Conversation) -> Void
    private var pendingTasks: [UUID: Task<Void, Never>] = [:]

    init(
        store: any PersistenceStore,
        ensureConversation: @escaping (BareJID, String?, UUID) async throws -> Void,
        conversation: @escaping (BareJID, UUID) -> Conversation?,
        didUpdateConversation: @escaping (Conversation) -> Void
    ) {
        self.store = store
        self.ensureConversation = ensureConversation
        self.conversation = conversation
        self.didUpdateConversation = didUpdateConversation
    }

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    func takePendingTasks() -> [Task<Void, Never>] {
        let tasks = Array(pendingTasks.values)
        pendingTasks.removeAll()
        return tasks
    }

    func clearInvites(accountID: UUID) {
        pendingInvites.removeAll { $0.accountID == accountID }
    }

    func clearPendingLeaves(accountID: UUID) {
        pendingLeaves = pendingLeaves.filter { $0.accountID != accountID }
    }

    func joinRoom(jid: BareJID, nickname: String, password: String? = nil, accountID: UUID) async throws {
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        guard let nickname = FullJID.normalizeResourcePart(nickname) else { throw ChatServiceError.invalidJID(nickname) }

        try await mucModule.joinRoom(jid, nickname: nickname, password: password)
        try await ensureConversation(jid, nickname, accountID)
    }

    func joinRoomAwaitingEcho(
        jid: BareJID,
        nickname: String,
        password: String? = nil,
        accountID: UUID,
        timeout: Duration = .seconds(5),
        remember: Bool = true
    ) async throws {
        let (notifierID, stream) = registerRoomJoinNotifier(jid: jid, accountID: accountID)
        // `clearRoomJoinNotifier` is identity-aware and idempotent, so running
        // it here covers every exit path (joinRoom throws, echo arrives, echo
        // times out) without duplicating cleanup at each return site.
        defer { clearRoomJoinNotifier(jid: jid, accountID: accountID, id: notifierID) }

        try await joinRoom(jid: jid, nickname: nickname, password: password, accountID: accountID)

        let yielded = await awaitRoomJoinedEcho(stream: stream, timeout: timeout)
        if !yielded {
            throw ChatServiceError.timeout(jid)
        }
        if remember {
            await setRejoinsOnConnect(true, room: jid, accountID: accountID)
        }
    }

    func joinRoomAwaitingEcho(
        jidString: String,
        nickname: String,
        password: String? = nil,
        accountID: UUID,
        timeout: Duration = .seconds(5),
        remember: Bool = true
    ) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await joinRoomAwaitingEcho(
            jid: jid, nickname: nickname, password: password,
            accountID: accountID, timeout: timeout, remember: remember
        )
    }

    func registerRoomJoinNotifier(jid: BareJID, accountID: UUID) -> (id: UUID, stream: AsyncStream<Void>) {
        let key = RoomJoinKey(accountID: accountID, room: jid)
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        // Replace any prior registration for the same key. The prior
        // continuation is finished without yield so its consumer's
        // for-await loop exits and reports failure.
        if let prior = roomJoinNotifiers.removeValue(forKey: key) {
            prior.continuation.finish()
        }
        roomJoinNotifiers[key] = RoomJoinNotifier(id: id, continuation: continuation)
        return (id, stream)
    }

    func clearRoomJoinNotifier(jid: BareJID, accountID: UUID, id: UUID) {
        let key = RoomJoinKey(accountID: accountID, room: jid)
        guard roomJoinNotifiers[key]?.id == id else { return }
        roomJoinNotifiers.removeValue(forKey: key)?.continuation.finish()
    }

    func awaitRoomJoinedEcho(stream: AsyncStream<Void>, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                for await _ in stream {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let firstResult = await group.next() ?? false
            group.cancelAll()
            return firstResult
        }
    }

    func leaveRoom(jid: BareJID, accountID: UUID, forget: Bool = true) async throws {
        // Before the connection check, so leaving while offline still keeps the room from being joined again.
        if forget {
            await setRejoinsOnConnect(false, room: jid, accountID: accountID)
        }
        guard let client = accountService?.connectedClient(for: accountID) else {
            pendingLeaves.insert(RoomJoinKey(accountID: accountID, room: jid))
            throw ChatServiceError.notConnected(accountID)
        }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        do {
            try await mucModule.leaveRoom(jid)
        } catch {
            // The client can go down ahead of the account's state. The module still tracks a room whose leave was
            // refused, so a resumed stream would still be in it.
            if mucModule.nickname(in: jid) != nil {
                pendingLeaves.insert(RoomJoinKey(accountID: accountID, room: jid))
            }
            throw error
        }
        clearRoomState(for: jid, accountID: accountID)
    }

    /// A room whose leave fails again stays pending.
    private func completePendingLeaves(accountID: UUID) async {
        for key in pendingLeaves where key.accountID == accountID {
            do {
                try await leaveRoom(jid: key.room, accountID: accountID, forget: false)
                pendingLeaves.remove(key)
            } catch {
                log.warning("Failed to complete a pending room leave: \(error)")
                log.debug("The room that could not be left is \(key.room)")
            }
        }
    }

    /// Rejoins the rooms the user is in. Rooms in `skipped` are left alone: the ones a resumed stream is still in, and
    /// the ones with an auto-join bookmark, whose nickname and password apply.
    func rejoinRooms(accountID: UUID, excluding skipped: Set<BareJID>) async {
        let conversations = await (try? store.fetchConversations(for: accountID)) ?? []
        for conversation in conversations where conversation.rejoinsOnConnect && !skipped.contains(conversation.jid) {
            guard let nickname = conversation.roomNickname else { continue }
            do {
                try await joinRoom(jid: conversation.jid, nickname: nickname, accountID: accountID)
            } catch {
                log.warning("Failed to rejoin a room: \(error)")
                log.debug("The room that could not be rejoined is \(conversation.jid)")
            }
        }
    }

    private func storedRoom(_ room: BareJID, accountID: UUID) async -> Conversation? {
        try? await store.fetchConversation(jid: room.description, type: .groupchat, accountID: accountID, importSourceJID: nil)
    }

    private func setRejoinsOnConnect(_ rejoins: Bool, room: BareJID, accountID: UUID) async {
        guard let conversation = await storedRoom(room, accountID: accountID) else { return }
        await setRejoinsOnConnect(rejoins, for: conversation)
    }

    private func setRejoinsOnConnect(_ rejoins: Bool, for conversation: Conversation) async {
        guard conversation.rejoinsOnConnect != rejoins,
              let updated = try? await store.updateConversation(conversation.id, { $0.rejoinsOnConnect = rejoins }) else { return }
        didUpdateConversation(updated)
    }

    func joinRoom(jidString: String, nickname: String, password: String? = nil, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await joinRoom(jid: jid, nickname: nickname, password: password, accountID: accountID)
    }

    func leaveRoom(jidString: String, accountID: UUID, forget: Bool = true) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await leaveRoom(jid: jid, accountID: accountID, forget: forget)
    }

    func roomMemberJIDs(roomJIDString: String, accountID: UUID) async throws -> [BareJID] {
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return [] }
        guard let roomJID = BareJID.parse(roomJIDString) else { return [] }

        let affiliations: [RoomAffiliation] = [.owner, .admin, .member]
        return await withTaskGroup(of: [BareJID].self) { group in
            for affiliation in affiliations {
                let xmppAffiliation = MUCAffiliation(rawValue: affiliation.rawValue) ?? .none
                group.addTask {
                    let items = await (try? mucModule.getAffiliationList(xmppAffiliation, in: roomJID)) ?? []
                    return items.map(\.jid)
                }
            }
            var result = Set<BareJID>()
            for await jids in group {
                result.formUnion(jids)
            }
            return Array(result)
        }
    }

    func participantGroups(forRoomJIDString jidString: String, accountID: UUID) -> [RoomParticipantGroup] {
        let participants = participants(forRoomJIDString: jidString, accountID: accountID)
        let grouped = Dictionary(grouping: participants, by: \.affiliation)
        return grouped
            .map { RoomParticipantGroup(affiliation: $0.key, participants: $0.value.sorted { $0.nickname.localizedStandardCompare($1.nickname) == .orderedAscending }) }
            .sorted { $0.affiliation.sortPriority < $1.affiliation.sortPriority }
    }

    func participantCount(forRoomJIDString jidString: String, accountID: UUID) -> Int {
        participants(forRoomJIDString: jidString, accountID: accountID).count
    }

    func participants(forRoomJIDString jidString: String, accountID: UUID) -> [RoomParticipant] {
        guard let key = roomKey(jidString, accountID: accountID) else { return [] }
        return roomParticipants[key] ?? []
    }

    func roomFlags(forRoomJIDString jidString: String, accountID: UUID) -> Set<RoomFlag> {
        guard let key = roomKey(jidString, accountID: accountID) else { return [] }
        return roomFlags[key] ?? []
    }

    func isRoomNewlyCreated(jidString: String, accountID: UUID) -> Bool {
        guard let key = roomKey(jidString, accountID: accountID) else { return false }
        return newlyCreatedRoomKeys.contains(key)
    }

    func knownRoomDomains(accountID: UUID) -> Set<String> {
        Set(roomParticipants.keys.filter { $0.accountID == accountID }.map(\.room.domainPart))
    }

    /// Canonicalizes input so mixed-case room names and persisted JIDs address the same state.
    private func roomKey(_ jidString: String, accountID: UUID) -> RoomJoinKey? {
        BareJID.parse(jidString).map { RoomJoinKey(accountID: accountID, room: $0) }
    }

    func discoverMUCService(accountID: UUID) async -> String? {
        guard let client = accountService?.connectedClient(for: accountID) else { return nil }
        guard let disco = await client.module(ofType: ServiceDiscoveryModule.self) else { return nil }

        let account = accountService?.accounts.first { $0.id == accountID }
        guard let domain = account?.jid.domainPart,
              let domainJID = BareJID.parse(domain) else { return nil }
        guard let items = try? await disco.queryItems(for: .bare(domainJID)) else { return nil }

        for item in items {
            guard let info = try? await disco.queryInfo(for: item.jid) else { continue }
            if info.identities.contains(where: { $0.category == "conference" && $0.type == "text" }) {
                return item.jid.description
            }
        }
        return nil
    }

    func discoverRooms(on service: String, accountID: UUID) async throws -> [DiscoveredRoom] {
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return [] }

        let rooms = try await mucModule.discoverRooms(on: service)
        return rooms.map { DiscoveredRoom(jidString: $0.jid.description, name: $0.name) }
    }

    func searchChannels(
        keyword: String,
        accountID: UUID,
        after: String? = nil
    ) async throws -> ChannelSearchResult {
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let searchModule = await client.module(ofType: ChannelSearchModule.self) else { return ChannelSearchResult(channels: [], hasMore: false, lastCursor: nil) }

        let query = ChannelSearchModule.SearchQuery(keyword: keyword, after: after)
        let result = try await searchModule.search(query)

        let channels = result.items.map {
            SearchedChannel(
                jidString: $0.address.description,
                name: $0.name,
                userCount: $0.userCount,
                isOpen: $0.isOpen,
                description: $0.description
            )
        }

        let hasMore = !result.items.isEmpty && result.lastID != nil
        return ChannelSearchResult(channels: channels, hasMore: hasMore, lastCursor: result.lastID)
    }

    func setRoomSubject(jidString: String, subject: String, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.setSubject(in: jid, subject: subject)
    }

    func inviteUser(jidString: String, toRoomJIDString roomJIDString: String, reason: String?, password: String? = nil, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.inviteUser(jid, to: roomJID, reason: reason, password: password)
    }

    func kickOccupant(nickname: String, fromRoomJIDString roomJIDString: String, reason: String?, accountID: UUID) async throws {
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.kickOccupant(nickname: nickname, from: roomJID, reason: reason)
    }

    func banUser(jidString: String, fromRoomJIDString roomJIDString: String, reason: String?, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.banUser(jid: jid, from: roomJID, reason: reason)
    }

    func grantVoice(nickname: String, inRoomJIDString roomJIDString: String, accountID: UUID) async throws {
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.grantVoice(nickname: nickname, in: roomJID)
    }

    func revokeVoice(nickname: String, inRoomJIDString roomJIDString: String, accountID: UUID) async throws {
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.revokeVoice(nickname: nickname, in: roomJID)
    }

    func changeRoomNickname(jidString: String, newNickname: String, accountID: UUID) async throws {
        guard let roomJID = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.changeNickname(in: roomJID, to: newNickname)
    }

    func getRoomConfig(jidString: String, accountID: UUID) async throws -> [RoomConfigField] {
        guard let roomJID = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return [] }
        let fields = try await mucModule.getRoomConfig(roomJID)
        return fields.map { RoomConfigField(from: $0) }
    }

    func submitRoomConfig(jidString: String, fields: [RoomConfigField], accountID: UUID) async throws {
        guard let roomJID = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        let dataFormFields = fields.map { $0.toDataFormField() }
        try await mucModule.submitRoomConfig(roomJID, fields: dataFormFields)
    }

    func getAffiliationList(
        affiliation: RoomAffiliation,
        inRoomJIDString roomJIDString: String,
        accountID: UUID
    ) async throws -> [RoomAffiliationItem] {
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return [] }
        let mucAff = MUCAffiliation(rawValue: affiliation.rawValue) ?? .none
        let items = try await mucModule.getAffiliationList(mucAff, in: roomJID)
        return items.map { RoomAffiliationItem(jidString: $0.jid.description, affiliation: RoomAffiliation(rawValue: $0.affiliation.rawValue) ?? .none, nickname: $0.nickname, reason: $0.reason) }
    }

    func setAffiliation(
        jidString: String,
        inRoomJIDString roomJIDString: String,
        to affiliation: RoomAffiliation,
        reason: String? = nil,
        accountID: UUID
    ) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        guard let roomJID = BareJID.parse(roomJIDString) else {
            throw ChatServiceError.invalidJID(roomJIDString)
        }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        let mucAff = MUCAffiliation(rawValue: affiliation.rawValue) ?? .none
        try await mucModule.setAffiliation(jid: jid, in: roomJID, to: mucAff, reason: reason)
    }

    func destroyRoom(jid: BareJID, reason: String? = nil, accountID: UUID) async throws {
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        try await mucModule.destroyRoom(jid, reason: reason)
    }

    func destroyRoom(jidString: String, reason: String? = nil, accountID: UUID) async throws {
        guard let jid = BareJID.parse(jidString) else {
            throw ChatServiceError.invalidJID(jidString)
        }
        try await destroyRoom(jid: jid, reason: reason, accountID: accountID)
    }

    func acceptInvite(_ invite: PendingRoomInvite, nickname: String, accountID: UUID) async throws {
        try await joinRoomAwaitingEcho(
            jidString: invite.roomJIDString, nickname: nickname,
            password: invite.password, accountID: accountID
        )
        pendingInvites.removeAll { $0.id == invite.id }
    }

    func declineInvite(_ invite: PendingRoomInvite, reason: String? = nil, accountID: UUID) async throws {
        // XEP-0249 direct invites have no decline mechanism — only send decline for mediated invites
        if !invite.isDirect,
           let roomJID = BareJID.parse(invite.roomJIDString),
           let fromString = invite.fromJIDString,
           let inviterJID = JID.parse(fromString),
           let client = accountService?.connectedClient(for: accountID),
           let mucModule = await client.module(ofType: MUCModule.self) {
            try await mucModule.declineInvite(room: roomJID, inviter: inviterJID, reason: reason)
        }
        pendingInvites.removeAll { $0.id == invite.id }
    }

    func clearNewlyCreatedRoom(_ jidString: String, accountID: UUID) {
        guard let key = roomKey(jidString, accountID: accountID) else { return }
        newlyCreatedRoomKeys.remove(key)
    }

    func handleMUCSelfPingFailed(room: BareJID, reason: MUCSelfPingFailure, accountID: UUID) async {
        switch reason {
        case .notJoined:
            log.warning("MUC self-ping: no longer joined, rejoining the room")
            log.debug("The room being rejoined is \(room)")
            let nickname = await storedRoom(room, accountID: accountID)?.roomNickname ?? room.localPart ?? "user"
            do {
                try await joinRoom(jid: room, nickname: nickname, accountID: accountID)
            } catch {
                log.warning("MUC self-ping rejoin failed: \(error)")
                log.debug("The room that could not be rejoined is \(room)")
            }
        case .nickChanged:
            break
        }
    }

    /// Shows a resumed account's rooms again and completes the leaves requested during the drop. It must stay
    /// synchronous, because the services after `ChatService` get `.streamResumed` only once this returns. A suspension
    /// here would let a later `.disconnected` be handled first, and the stale resume would then show contacts and
    /// bookmarks while disconnected.
    func handleStreamResumed(accountID: UUID) {
        restoreRooms(accountID: accountID)
        guard pendingLeaves.contains(where: { $0.accountID == accountID }) else { return }
        let taskID = UUID()
        pendingTasks[taskID] = Task { [weak self] in
            defer { self?.pendingTasks[taskID] = nil }
            await self?.completePendingLeaves(accountID: accountID)
        }
    }

    /// Replaces the account's participants and flags with the room module's. The module carries its rooms across a
    /// resumed stream and applies every replayed change before it announces it. Its state is therefore the complete
    /// one, whether a replayed occupant event is handled before or after this replacement.
    private func restoreRooms(accountID: UUID) {
        guard let occupancies = accountService?.roomModule(for: accountID)?.roomOccupancies else { return }
        roomParticipants = roomParticipants.filter { $0.key.accountID != accountID }
        roomFlags = roomFlags.filter { $0.key.accountID != accountID }
        for (room, occupancy) in occupancies {
            setOccupancy(occupancy, for: RoomJoinKey(accountID: accountID, room: room))
        }
    }

    private func setOccupancy(_ occupancy: RoomOccupancy, for key: RoomJoinKey) {
        roomParticipants[key] = occupancy.occupants.map { mapOccupant($0) }
        roomFlags[key] = occupancy.flags.isEmpty ? nil : occupancy.flags
    }

    func handleRoomJoined(room: BareJID, occupancy: RoomOccupancy, isNewlyCreated: Bool, accountID: UUID) async {
        let key = RoomJoinKey(accountID: accountID, room: room)
        setOccupancy(occupancy, for: key)
        if isNewlyCreated {
            newlyCreatedRoomKeys.insert(key)
        }

        let notifierID = roomJoinNotifiers[key]?.id
        try? await ensureConversation(room, occupancy.nickname, accountID)
        guard !Task.isCancelled else {
            if let notifierID { clearRoomJoinNotifier(jid: room, accountID: accountID, id: notifierID) }
            return
        }
        guard roomJoinNotifiers[key]?.id == notifierID else { return }

        // Atomic registry-removal-first + yield-then-finish: yield is what
        // signals success to `awaitRoomJoinedEcho`; finish closes the stream
        // so the consume task exits. The post-await `clearRoomJoinNotifier`
        // call is a no-op on the same key after this (the slot is gone).
        let waiterKey = RoomJoinKey(accountID: accountID, room: room)
        if let notifier = roomJoinNotifiers.removeValue(forKey: waiterKey) {
            notifier.continuation.yield()
            notifier.continuation.finish()
        }
    }

    func handleRoomOccupantJoined(room: BareJID, occupant: RoomOccupant, accountID: UUID) {
        let key = RoomJoinKey(accountID: accountID, room: room)
        let participant = mapOccupant(occupant)
        var list = roomParticipants[key] ?? []
        list.removeAll { $0.nickname == participant.nickname }
        list.append(participant)
        roomParticipants[key] = list
    }

    func handleRoomOccupantLeft(room: BareJID, occupant: RoomOccupant, reason: OccupantLeaveReason?, accountID: UUID) async {
        let key = RoomJoinKey(accountID: accountID, room: room)
        roomParticipants[key]?.removeAll { $0.nickname == occupant.nickname }

        switch reason {
        case .kicked, .banned, .affiliationChanged:
            // The stored room, not the cached one: the cache is only filled where conversations are listed.
            guard let stored = await storedRoom(room, accountID: accountID), stored.roomNickname == occupant.nickname else { return }
            await setRejoinsOnConnect(false, for: stored)
        case .serviceShutdown, nil:
            // Only being thrown out ends the user's stay. A service that shuts down comes back.
            break
        }
    }

    func handleRoomInviteReceived(_ invite: RoomInvite, accountID: UUID) {
        let pending = PendingRoomInvite(
            accountID: accountID,
            roomJIDString: invite.room.description,
            fromJIDString: invite.from.description,
            reason: invite.reason,
            password: invite.password,
            isDirect: invite.isDirect
        )
        // Deduplicate by account+room+from so the same invite arriving on two accounts stays two rows.
        guard !pendingInvites.contains(where: { $0.id == pending.id }) else {
            return
        }
        pendingInvites.append(pending)
    }

    func handleRoomOccupantNickChanged(room: BareJID, oldNickname: String, occupant: RoomOccupant, accountID: UUID) {
        let key = RoomJoinKey(accountID: accountID, room: room)
        var list = roomParticipants[key] ?? []
        let participant = mapOccupant(occupant)
        list.removeAll { $0.nickname == oldNickname || $0.nickname == participant.nickname }
        list.append(participant)
        roomParticipants[key] = list

        // If self-nick changed, update conversation
        if let conversation = conversation(room, accountID),
           conversation.roomNickname == oldNickname {
            let taskID = UUID()
            pendingTasks[taskID] = Task { [weak self] in
                defer { self?.pendingTasks[taskID] = nil }
                guard let self else { return }
                let nickname = occupant.nickname
                // Conditional update, not upsert: a `.roomDestroyed` could have
                // deleted this room while we awaited — never resurrect it.
                guard let updated = try? await store.updateConversation(conversation.id, { $0.roomNickname = nickname }) else { return }
                // Mirror the store guard in the cache: `updateCachedConversation`
                // no-ops when the slot is already gone, so a wholesale republish
                // can't re-insert a concurrently destroyed room into `openConversations`.
                didUpdateConversation(updated)
            }
        }
    }

    func clearRoomState(for jid: BareJID, accountID: UUID) {
        let key = RoomJoinKey(accountID: accountID, room: jid)
        roomParticipants.removeValue(forKey: key)
        roomFlags.removeValue(forKey: key)
        newlyCreatedRoomKeys.remove(key)
        roomJoinNotifiers.removeValue(forKey: key)?.continuation.finish()
    }

    func clearRoomState(forAccount accountID: UUID) {
        roomParticipants = roomParticipants.filter { $0.key.accountID != accountID }
        roomFlags = roomFlags.filter { $0.key.accountID != accountID }
        newlyCreatedRoomKeys = newlyCreatedRoomKeys.filter { $0.accountID != accountID }
        for key in roomJoinNotifiers.keys where key.accountID == accountID {
            roomJoinNotifiers.removeValue(forKey: key)?.continuation.finish()
        }
    }

    private func mapOccupant(_ occupant: RoomOccupant) -> RoomParticipant {
        let affiliation = RoomAffiliation(rawValue: occupant.affiliation.rawValue) ?? .none
        let role = RoomRole(rawValue: occupant.role.rawValue) ?? .none
        return RoomParticipant(
            nickname: occupant.nickname,
            jidString: occupant.jid?.description,
            affiliation: affiliation,
            role: role
        )
    }
}
