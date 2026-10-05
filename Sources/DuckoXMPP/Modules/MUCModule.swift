import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.muc")

/// The rooms a `MUCModule` tracks, for the module that takes over when the stream is resumed.
public struct MUCResumeState: Sendable {
    fileprivate let rooms: [BareJID: MUCModule.RoomState]
    fileprivate let pendingNickChanges: [BareJID: [String: RoomOccupant]]
}

/// Implements XEP-0045 Multi-User Chat — room join/leave, occupant tracking, group messaging, and invitations.
public final class MUCModule: XMPPModule, Sendable {
    /// Errors from the MUC module.
    public enum MUCError: Error {
        case invalidNickname(String)
    }

    /// Normalizes a user-supplied nickname via PRECIS OpaqueString, throwing on failure so every
    /// nickname-bearing entry point rejects an invalid nick consistently.
    private static func normalizedNickname(_ nickname: String) throws -> String {
        guard let normalized = FullJID.normalizeResourcePart(nickname) else {
            throw MUCError.invalidNickname(nickname)
        }
        return normalized
    }

    // MARK: - State

    /// Self-ping interval for detecting silent MUC disconnections (XEP-0410).
    private let selfPingInterval: Duration

    fileprivate struct RoomState {
        var nickname: String
        var password: String?
        var occupants: [String: RoomOccupant] = [:]
        var subject: String?
        var flags: Set<RoomFlag> = []
        var lastActivity: ContinuousClock.Instant = .now

        var occupancy: RoomOccupancy {
            RoomOccupancy(nickname: nickname, occupants: Array(occupants.values), subject: subject, flags: flags)
        }
    }

    private struct State {
        var context: ModuleContext?
        var rooms: [BareJID: RoomState] = [:]
        var pendingNickChanges: [BareJID: [String: RoomOccupant]] = [:]
        var selfPingTasks: [BareJID: Task<Void, Never>] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        [XMPPNamespaces.muc, XMPPNamespaces.mucDirectInvite, XMPPNamespaces.messageCorrect]
    }

    public init(selfPingInterval: Duration = .seconds(900), resuming: MUCResumeState? = nil) {
        self.selfPingInterval = selfPingInterval
        var initial = State()
        if let resuming {
            initial.rooms = resuming.rooms
            initial.pendingNickChanges = resuming.pendingNickChanges
        }
        self.state = OSAllocatedUnfairLock(initialState: initial)
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleSessionEstablished(resumed: Bool) {
        // A fresh session is in no room, so the rooms carried for a resume no longer apply.
        guard !resumed else { return }
        state.withLock { state in
            state.rooms.removeAll()
            state.pendingNickChanges.removeAll()
        }
    }

    public func handleResume() async throws {
        for room in state.withLock({ Array($0.rooms.keys) }) {
            startSelfPing(for: room)
        }
    }

    /// Keeps the rooms and their occupants, so `resumeState` still describes them after the teardown.
    public func handleDisconnect() async {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            defer { state.selfPingTasks.removeAll() }
            return Array(state.selfPingTasks.values)
        }
        for task in tasks {
            task.cancel()
        }
    }

    // MARK: - Presence Handling

    /// Groups parsed presence info passed between presence-handling methods.
    private struct PresenceInfo {
        let roomJID: BareJID
        let nickname: String
        let occupant: RoomOccupant
        let item: XMLElement?
        let mucUser: XMLElement?
        let statusCodes: Set<Int>
        var isSelfPresence: Bool {
            statusCodes.contains(110)
        }
    }

    public func handlePresence(_ presence: XMPPPresence) throws {
        guard let from = presence.from,
              case let .full(fullJID) = from else { return }

        let roomJID = fullJID.bareJID
        let nickname = fullJID.resourcePart

        let (isTracked, context) = state.withLock { ($0.rooms[roomJID] != nil, $0.context) }
        guard isTracked else { return }

        let mucUser = presence.element.child(named: "x", namespace: XMPPNamespaces.mucUser)
        let item = mucUser?.child(named: "item")
        let occupant: RoomOccupant = if let item, let parsed = RoomOccupant.parse(item, nickname: nickname) {
            parsed
        } else {
            RoomOccupant(nickname: nickname, affiliation: .none, role: .participant)
        }

        let info = PresenceInfo(
            roomJID: roomJID, nickname: nickname, occupant: occupant,
            item: item, mucUser: mucUser, statusCodes: parseStatusCodes(mucUser)
        )

        if presence.presenceType == .unavailable {
            handleUnavailablePresence(info, context: context)
        } else {
            handleAvailablePresence(info, context: context)
        }
    }

    private func handleUnavailablePresence(_ info: PresenceInfo, context: ModuleContext?) {
        // Nick change (status 303): store old occupant under new nick, don't emit leave
        if info.statusCodes.contains(303), let newNick = info.item?.attribute("nick") {
            state.withLock { state in
                var pending = state.pendingNickChanges[info.roomJID] ?? [:]
                pending[newNick] = info.occupant
                state.pendingNickChanges[info.roomJID] = pending
            }
            return
        }

        // Room destruction: check for <destroy> in muc#user
        if info.isSelfPresence, let destroy = info.mucUser?.child(named: "destroy") {
            let reason = destroy.child(named: "reason")?.textContent
            let alternateVenue = destroy.attribute("jid").flatMap { BareJID.parse($0) }
            let pingTask = state.withLock { state -> Task<Void, Never>? in
                state.rooms.removeValue(forKey: info.roomJID)
                state.pendingNickChanges.removeValue(forKey: info.roomJID)
                return state.selfPingTasks.removeValue(forKey: info.roomJID)
            }
            pingTask?.cancel()
            log.info("Room \(info.roomJID) was destroyed")
            context?.emitEvent(.roomDestroyed(room: info.roomJID, reason: reason, alternateVenue: alternateVenue))
            return
        }

        // Parse leave reason from MUC status codes
        let itemReason = info.item?.child(named: "reason")?.textContent
        let leaveReason: OccupantLeaveReason? = if info.statusCodes.contains(301) {
            .banned(reason: itemReason)
        } else if info.statusCodes.contains(307) {
            .kicked(reason: itemReason)
        } else if info.statusCodes.contains(321) {
            .affiliationChanged(reason: itemReason)
        } else if info.statusCodes.contains(332) {
            .serviceShutdown
        } else {
            nil
        }

        handleOccupantLeft(roomJID: info.roomJID, nickname: info.nickname, occupant: info.occupant, leaveReason: leaveReason, context: context)
    }

    private func handleAvailablePresence(_ info: PresenceInfo, context: ModuleContext?) {
        // Check if this is the second half of a nick change
        let pendingOccupant = state.withLock { state -> RoomOccupant? in
            state.pendingNickChanges[info.roomJID]?.removeValue(forKey: info.nickname)
        }

        if let pendingOccupant {
            let oldNickname = pendingOccupant.nickname
            state.withLock { state in
                state.rooms[info.roomJID]?.occupants.removeValue(forKey: oldNickname)
                state.rooms[info.roomJID]?.occupants[info.nickname] = info.occupant
                if info.isSelfPresence {
                    state.rooms[info.roomJID]?.nickname = info.nickname
                }
            }
            log.info("Occupant \(oldNickname) changed nick to \(info.nickname) in \(info.roomJID)")
            context?.emitEvent(.roomOccupantNickChanged(room: info.roomJID, oldNickname: oldNickname, occupant: info.occupant))
        } else if info.isSelfPresence {
            handleSelfJoined(roomJID: info.roomJID, nickname: info.nickname, occupant: info.occupant, statusCodes: info.statusCodes, context: context)
        } else {
            handleOccupantJoined(roomJID: info.roomJID, nickname: info.nickname, occupant: info.occupant, context: context)
        }
    }

    private func handleSelfJoined(
        roomJID: BareJID,
        nickname: String,
        occupant: RoomOccupant,
        statusCodes: Set<Int>,
        context: ModuleContext?
    ) {
        let flags: Set<RoomFlag> = {
            var result = Set<RoomFlag>()
            if statusCodes.contains(100) { result.insert(.nonAnonymous) }
            if statusCodes.contains(170) { result.insert(.logged) }
            return result
        }()

        let occupancy = state.withLock { state -> RoomOccupancy in
            state.rooms[roomJID]?.occupants[nickname] = occupant
            state.rooms[roomJID]?.flags = flags
            state.rooms[roomJID]?.lastActivity = .now
            guard let room = state.rooms[roomJID] else {
                return RoomOccupancy(nickname: nickname, occupants: [occupant], subject: nil, flags: flags)
            }
            return RoomOccupancy(
                nickname: nickname,
                occupants: Array(room.occupants.values),
                subject: room.subject,
                flags: flags
            )
        }
        let isNewlyCreated = statusCodes.contains(201)
        log.info("Joined room \(roomJID) as \(nickname)\(isNewlyCreated ? " [new room]" : "")")
        context?.emitEvent(.roomJoined(room: roomJID, occupancy: occupancy, isNewlyCreated: isNewlyCreated))
        startSelfPing(for: roomJID)
    }

    private func handleOccupantJoined(roomJID: BareJID, nickname: String, occupant: RoomOccupant, context: ModuleContext?) {
        state.withLock {
            $0.rooms[roomJID]?.occupants[nickname] = occupant
            $0.rooms[roomJID]?.lastActivity = .now
        }
        log.info("Occupant \(nickname) joined \(roomJID)")
        context?.emitEvent(.roomOccupantJoined(room: roomJID, occupant: occupant))
    }

    private func handleOccupantLeft(
        roomJID: BareJID,
        nickname: String,
        occupant: RoomOccupant,
        leaveReason: OccupantLeaveReason? = nil,
        context: ModuleContext?
    ) {
        let (isSelf, pingTask) = state.withLock { state -> (Bool, Task<Void, Never>?) in
            state.rooms[roomJID]?.occupants.removeValue(forKey: nickname)
            let selfLeft = state.rooms[roomJID]?.nickname == nickname
            var task: Task<Void, Never>?
            if selfLeft {
                task = state.selfPingTasks.removeValue(forKey: roomJID)
                state.rooms.removeValue(forKey: roomJID)
            }
            return (selfLeft, task)
        }
        pingTask?.cancel()

        if isSelf {
            log.info("Left room \(roomJID)")
        } else {
            log.info("Occupant \(nickname) left \(roomJID)")
        }

        context?.emitEvent(.roomOccupantLeft(room: roomJID, occupant: occupant, reason: leaveReason))
    }

    // MARK: - Message Handling

    public func handleMessage(_ message: XMPPMessage) throws {
        // Handle mediated invites (in normal or no-type messages)
        if let mucUser = message.element.child(named: "x", namespace: XMPPNamespaces.mucUser),
           let invite = mucUser.child(named: "invite") {
            handleMediatedInvite(message: message, invite: invite, mucUser: mucUser)
            return
        }

        // Handle direct invites (XEP-0249)
        if let conference = message.element.child(named: "x", namespace: XMPPNamespaces.mucDirectInvite) {
            handleDirectInvite(message: message, conference: conference)
            return
        }

        // MUC Private Message (XEP-0045 §7.5): type="chat" from a tracked room occupant
        if handlePrivateMessage(message) { return }

        // Only handle groupchat messages for tracked rooms
        guard message.messageType == .groupchat,
              let from = message.from else { return }

        let roomJID = from.bareJID
        let isTracked = state.withLock { $0.rooms[roomJID] != nil }
        guard isTracked else { return }

        // Subject change
        if let subject = message.subject {
            state.withLock { $0.rooms[roomJID]?.subject = subject }
            let context = state.withLock { $0.context }
            context?.emitEvent(.roomSubjectChanged(room: roomJID, subject: subject.isEmpty ? nil : subject, setter: from))
            return
        }

        // Encrypted corrections/retractions are classified by OMEMOModule after decryption
        if message.element.child(named: "encrypted", namespace: XMPPNamespaces.omemo) != nil {
            return
        }

        // XEP-0424/0425: Message retraction or moderation
        if let retract = message.element.child(named: "retract", namespace: XMPPNamespaces.messageRetract) {
            handleRetraction(retract: retract, from: from, roomJID: roomJID)
            return
        }

        // XEP-0308: Message correction in groupchat
        if let replace = message.element.child(named: "replace", namespace: XMPPNamespaces.messageCorrect),
           let originalID = replace.attribute("id"),
           let newBody = message.body {
            let context = state.withLock { state -> ModuleContext? in
                state.rooms[roomJID]?.lastActivity = .now
                return state.context
            }
            context?.emitEvent(.messageCorrected(originalID: originalID, newBody: newBody, from: from))
            return
        }

        // Group message
        guard message.body != nil else { return }

        let context = state.withLock { state -> ModuleContext? in
            state.rooms[roomJID]?.lastActivity = .now
            return state.context
        }
        context?.emitEvent(.roomMessageReceived(message))
    }

    private func handleMediatedInvite(message: XMPPMessage, invite: XMLElement, mucUser: XMLElement) {
        guard let roomJID = message.from?.bareJID,
              let fromString = invite.attribute("from"),
              let from = JID.parse(fromString) else { return }

        let reason = invite.child(named: "reason")?.textContent
        let password = mucUser.child(named: "password")?.textContent
        let roomInvite = RoomInvite(room: roomJID, from: from, reason: reason, password: password)

        let context = state.withLock { $0.context }
        log.info("Received mediated invite to \(roomJID) from \(from)")
        context?.emitEvent(.roomInviteReceived(roomInvite))
    }

    private func handleDirectInvite(message: XMPPMessage, conference: XMLElement) {
        guard let jidString = conference.attribute("jid"),
              let roomJID = BareJID.parse(jidString),
              let from = message.from else { return }

        let reason = conference.attribute("reason")
        let password = conference.attribute("password")
        let isContinuation = conference.attribute("continue") == "true"
        let thread = conference.attribute("thread")
        let roomInvite = RoomInvite(room: roomJID, from: from, reason: reason, password: password, isDirect: true, isContinuation: isContinuation, thread: thread)

        let context = state.withLock { $0.context }
        log.info("Received direct invite to \(roomJID) from \(from)")
        context?.emitEvent(.roomInviteReceived(roomInvite))
    }

    /// Returns `true` if the message was a MUC PM from a tracked room and was emitted.
    private func handlePrivateMessage(_ message: XMPPMessage) -> Bool {
        guard message.messageType == .chat,
              let from = message.from,
              case let .full(fullJID) = from else { return false }
        let roomJID = fullJID.bareJID
        let context: ModuleContext? = state.withLock { state in
            guard state.rooms[roomJID] != nil else { return nil }
            return state.context
        }
        guard let context else { return false }
        context.emitEvent(.mucPrivateMessageReceived(message))
        return true
    }

    private func handleRetraction(retract: XMLElement, from: JID, roomJID: BareJID) {
        let context = state.withLock { $0.context }
        if let moderated = retract.child(named: "moderated", namespace: XMPPNamespaces.messageModerate),
           let originalID = retract.attribute("id") {
            // XEP-0425: moderation messages come from bare room JID only
            guard case .bare = from else {
                log.warning("Rejected moderation from non-bare JID: \(from)")
                return
            }
            let moderator = moderated.attribute("by") ?? from.description
            let reason = retract.child(named: "reason")?.textContent
            context?.emitEvent(.messageModerated(originalID: originalID, moderator: moderator, room: roomJID, reason: reason))
        } else if let originalID = retract.attribute("id") {
            context?.emitEvent(.messageRetracted(originalID: originalID, from: from))
        }
    }

    // MARK: - Public API

    /// Joins a MUC room with the given nickname.
    public func joinRoom(_ room: BareJID, nickname: String, password: String? = nil, history: RoomHistoryFetch = .initial) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        // Normalize once at the room-state boundary so the stored nickname matches the
        // OpaqueString-normalized form that incoming presence (parsed via FullJID) carries.
        let nickname = try Self.normalizedNickname(nickname)
        let password = password ?? state.withLock { $0.rooms[room]?.password }

        let presence = buildJoinPresence(room: room, nickname: nickname, password: password, history: history, context: context)
        // The room is tracked from the moment the client takes the join: stream management re-sends it on a resume
        // even when the write fails, so it has to be carried. A join the client refuses leaves the room as it was.
        try await context.sendStanza(presence) { [state] in
            let existingPingTask = state.withLock { state -> Task<Void, Never>? in
                state.rooms[room] = RoomState(nickname: nickname, password: password)
                return state.selfPingTasks.removeValue(forKey: room)
            }
            existingPingTask?.cancel()
        }
        log.info("Joining room \(room) as \(nickname)")
    }

    /// Leaves a MUC room.
    public func leaveRoom(_ room: BareJID) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        guard let nickname = state.withLock({ $0.rooms[room]?.nickname }),
              let fullJID = FullJID(bareJID: room, resourcePart: nickname) else { return }

        let presence = XMPPPresence(type: .unavailable, to: .full(fullJID))
        // A leave the client refuses keeps the room tracked: a resumed stream is still in it.
        try await context.sendStanza(presence) { [state] in
            let pingTask = state.withLock { state -> Task<Void, Never>? in
                state.rooms.removeValue(forKey: room)
                state.pendingNickChanges.removeValue(forKey: room)
                return state.selfPingTasks.removeValue(forKey: room)
            }
            pingTask?.cancel()
        }
        log.info("Leaving room \(room)")
    }

    /// Sends a groupchat message to a room.
    public func sendMessage(
        to room: BareJID, body: String, id: String? = nil,
        markable: Bool = false, additionalElements: [XMLElement] = []
    ) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        let stanzaID = id ?? context.generateID()
        var message = XMPPMessage(type: .groupchat, to: .bare(room), id: stanzaID)
        message.body = body
        if markable {
            let markableElement = XMLElement(name: "markable", namespace: XMPPNamespaces.chatMarkers)
            message.element.addChild(markableElement)
        }
        for element in additionalElements {
            message.element.addChild(element)
        }
        try await context.sendStanza(message)
    }

    /// Sends a private message to a room occupant (XEP-0045 §7.5).
    public func sendPrivateMessage(
        to room: BareJID, nickname: String, body: String, id: String? = nil
    ) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        let nickname = try Self.normalizedNickname(nickname)
        guard let fullJID = FullJID(bareJID: room, resourcePart: nickname) else { return }
        let stanzaID = id ?? context.generateID()
        var message = XMPPMessage(type: .chat, to: .full(fullJID), id: stanzaID)
        message.body = body
        let mucUser = XMLElement(name: "x", namespace: XMPPNamespaces.mucUser)
        message.element.addChild(mucUser)
        try await context.sendStanza(message)
    }

    /// Sends a message correction (XEP-0308) for a previously sent groupchat message.
    public func sendCorrection(to room: BareJID, body: String, replacingID: String) async throws {
        let replace = XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": replacingID])
        try await sendMessage(to: room, body: body, additionalElements: [replace])
    }

    /// Sends a moderation request (XEP-0425) to retract a message by stanza-id.
    public func moderateMessage(room: BareJID, stanzaID: String, reason: String? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var iq = XMPPIQ(type: .set, to: .bare(room), id: context.generateID())
        var moderate = XMLElement(
            name: "moderate",
            namespace: XMPPNamespaces.messageModerate,
            attributes: ["id": stanzaID]
        )
        let retract = XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract)
        moderate.addChild(retract)
        if let reason {
            var reasonElement = XMLElement(name: "reason")
            reasonElement.addText(reason)
            moderate.addChild(reasonElement)
        }
        iq.element.addChild(moderate)
        _ = try await context.sendIQ(iq)
    }

    public func setSubject(in room: BareJID, subject: String) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var message = XMPPMessage(type: .groupchat, to: .bare(room))
        message.subject = subject
        try await context.sendStanza(message)
    }

    /// Sends a direct invitation (XEP-0249) to a user.
    public func inviteUser(
        _ jid: BareJID,
        to room: BareJID,
        reason: String? = nil,
        password: String? = nil,
        isContinuation: Bool = false,
        thread: String? = nil
    ) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var message = XMPPMessage(type: .normal, to: .bare(jid))
        var conference = XMLElement(name: "x", namespace: XMPPNamespaces.mucDirectInvite, attributes: ["jid": room.description])
        if let reason { conference.setAttribute("reason", value: reason) }
        if let password { conference.setAttribute("password", value: password) }
        if isContinuation { conference.setAttribute("continue", value: "true") }
        if let thread { conference.setAttribute("thread", value: thread) }
        message.element.addChild(conference)
        try await context.sendStanza(message)
    }

    /// Declines a MUC room invitation (XEP-0045 §7.8).
    public func declineInvite(room: BareJID, inviter: JID, reason: String? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var decline = XMLElement(name: "decline", attributes: ["to": inviter.description])
        appendReason(reason, to: &decline)
        var mucUser = XMLElement(name: "x", namespace: XMPPNamespaces.mucUser)
        mucUser.addChild(decline)
        var message = XMPPMessage(type: .normal, to: .bare(room))
        message.element.addChild(mucUser)
        try await context.sendStanza(message)
    }

    /// Kicks an occupant from the room by nickname.
    public func kickOccupant(nickname: String, from room: BareJID, reason: String? = nil) async throws {
        try await setRole(nickname: nickname, in: room, to: .none, reason: reason)
    }

    /// Bans a user from the room by JID.
    public func banUser(jid: BareJID, from room: BareJID, reason: String? = nil) async throws {
        try await setAffiliation(jid: jid, in: room, to: .outcast, reason: reason)
    }

    /// Discovers rooms on a MUC service using disco#items.
    public func discoverRooms(on service: String) async throws -> [(jid: BareJID, name: String?)] {
        guard let context = state.withLock({ $0.context }) else { return [] }
        guard let serviceJID = BareJID.parse(service) else { return [] }
        var iq = XMPPIQ(type: .get, to: .bare(serviceJID), id: context.generateID())
        let query = XMLElement(name: "query", namespace: XMPPNamespaces.discoItems)
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else { return [] }

        return result.children(named: "item").compactMap { item in
            guard let jidString = item.attribute("jid"),
                  let jid = BareJID.parse(jidString) else { return nil }
            return (jid: jid, name: item.attribute("name"))
        }
    }

    public func nickname(in room: BareJID) -> String? {
        state.withLock { $0.rooms[room]?.nickname }
    }

    /// The occupancy of every tracked room, including one whose join has not completed yet.
    public var roomOccupancies: [BareJID: RoomOccupancy] {
        state.withLock { $0.rooms.mapValues(\.occupancy) }
    }

    /// A snapshot of the tracked rooms, seeding the module of the client that resumes this one's stream.
    public var resumeState: MUCResumeState {
        state.withLock { MUCResumeState(rooms: $0.rooms, pendingNickChanges: $0.pendingNickChanges) }
    }

    /// Full JIDs (room + nickname) for all currently joined rooms.
    public var joinedRoomFullJIDs: [JID] {
        state.withLock { state in
            state.rooms.compactMap { room, roomState in
                guard let fullJID = FullJID(bareJID: room, resourcePart: roomState.nickname) else { return nil }
                return JID.full(fullJID)
            }
        }
    }

    /// Changes the user's nickname in a room.
    public func changeNickname(in room: BareJID, to newNickname: String) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        let newNickname = try Self.normalizedNickname(newNickname)
        guard let fullJID = FullJID(bareJID: room, resourcePart: newNickname) else { return }
        let presence = XMPPPresence(to: .full(fullJID), id: context.generateID())
        try await context.sendStanza(presence)
    }

    // MARK: - Room Configuration (muc#owner)

    /// Retrieves the room configuration form.
    public func getRoomConfig(_ room: BareJID) async throws -> [DataFormField] {
        guard let context = state.withLock({ $0.context }) else { return [] }
        var iq = XMPPIQ(type: .get, to: .bare(room), id: context.generateID())
        let query = XMLElement(name: "query", namespace: XMPPNamespaces.mucOwner)
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else { return [] }
        guard let form = result.child(named: "x", namespace: XMPPNamespaces.dataForms) else { return [] }
        return parseDataForm(form)
    }

    /// Submits a room configuration form.
    public func submitRoomConfig(_ room: BareJID, fields: [DataFormField]) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var iq = XMPPIQ(type: .set, to: .bare(room), id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.mucOwner)
        let form = buildSubmitForm(fields)
        query.addChild(form)
        iq.element.addChild(query)
        _ = try await context.sendIQ(iq)
    }

    /// Accepts the default room configuration (instant room).
    public func acceptDefaultConfig(_ room: BareJID) async throws {
        try await submitRoomConfig(room, fields: [])
    }

    // MARK: - Voice Management

    public func setRole(nickname: String, in room: BareJID, to role: MUCRole, reason: String? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        // Normalize so the targeted `nick` matches the occupant's stored OpaqueString form (kick,
        // grantVoice, and revokeVoice all route through here).
        let nickname = try Self.normalizedNickname(nickname)
        var iq = XMPPIQ(type: .set, to: .bare(room), id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.mucAdmin)
        var item = XMLElement(name: "item", attributes: ["nick": nickname, "role": role.rawValue])
        appendReason(reason, to: &item)
        query.addChild(item)
        iq.element.addChild(query)
        _ = try await context.sendIQ(iq)
    }

    /// Grants voice (participant role) to a visitor.
    public func grantVoice(nickname: String, in room: BareJID) async throws {
        try await setRole(nickname: nickname, in: room, to: .participant)
    }

    /// Revokes voice (visitor role) from a participant.
    public func revokeVoice(nickname: String, in room: BareJID) async throws {
        try await setRole(nickname: nickname, in: room, to: .visitor)
    }

    // MARK: - Affiliation Management

    /// Retrieves the affiliation list for a given affiliation.
    public func getAffiliationList(_ affiliation: MUCAffiliation, in room: BareJID) async throws -> [MUCAffiliationItem] {
        guard let context = state.withLock({ $0.context }) else { return [] }
        var iq = XMPPIQ(type: .get, to: .bare(room), id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.mucAdmin)
        let item = XMLElement(name: "item", attributes: ["affiliation": affiliation.rawValue])
        query.addChild(item)
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else { return [] }
        return result.children(named: "item").compactMap { MUCAffiliationItem.parse($0) }
    }

    public func setAffiliation(jid: BareJID, in room: BareJID, to affiliation: MUCAffiliation, reason: String? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var iq = XMPPIQ(type: .set, to: .bare(room), id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.mucAdmin)
        var item = XMLElement(name: "item", attributes: ["jid": jid.description, "affiliation": affiliation.rawValue])
        appendReason(reason, to: &item)
        query.addChild(item)
        iq.element.addChild(query)
        _ = try await context.sendIQ(iq)
    }

    // MARK: - Room Destruction

    /// Destroys a room (owner-only).
    public func destroyRoom(_ room: BareJID, reason: String? = nil, alternateVenue: BareJID? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { return }
        var iq = XMPPIQ(type: .set, to: .bare(room), id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.mucOwner)
        var destroy = XMLElement(name: "destroy")
        if let alternateVenue {
            destroy.setAttribute("jid", value: alternateVenue.description)
        }
        appendReason(reason, to: &destroy)
        query.addChild(destroy)
        iq.element.addChild(query)
        _ = try await context.sendIQ(iq)
    }

    // MARK: - Self-Ping (XEP-0410)

    private func startSelfPing(for room: BareJID) {
        let interval = selfPingInterval
        let task = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                await performSelfPing(for: room)
            }
        }
        // Cancels the task this one replaces, or this one when the room is gone.
        let obsolete = state.withLock { state -> Task<Void, Never>? in
            guard state.rooms[room] != nil else { return task }
            return state.selfPingTasks.updateValue(task, forKey: room)
        }
        obsolete?.cancel()
    }

    private func performSelfPing(for room: BareJID) async {
        let (nickname, context, lastActivity) = state.withLock { state in
            (state.rooms[room]?.nickname, state.context, state.rooms[room]?.lastActivity)
        }
        guard let nickname, let context, let lastActivity else { return }

        let elapsed = ContinuousClock.now - lastActivity
        if elapsed < selfPingInterval {
            return
        }

        guard let fullJID = FullJID(bareJID: room, resourcePart: nickname) else { return }

        var pingIQ = XMPPIQ(type: .get, to: .full(fullJID), id: context.generateID())
        let pingChild = XMLElement(name: "ping", namespace: XMPPNamespaces.ping)
        pingIQ.element.addChild(pingChild)

        do {
            _ = try await context.sendIQ(pingIQ)
            // Success — still joined
            state.withLock { $0.rooms[room]?.lastActivity = .now }
        } catch let error as XMPPStanzaError {
            handleSelfPingError(error, room: room, nickname: nickname, context: context)
        } catch {
            // Timeout or network error — retry on next interval
            log.debug("Self-ping timeout for \(room): \(error)")
        }
    }

    private func handleSelfPingError(_ error: XMPPStanzaError, room: BareJID, nickname: String, context: ModuleContext) {
        switch error.condition {
        case .serviceUnavailable, .featureNotImplemented:
            // Server doesn't support ping but we're still joined
            state.withLock { $0.rooms[room]?.lastActivity = .now }
        case .itemNotFound:
            // Nickname changed or room configuration issue
            log.warning("Self-ping answered with item-not-found")
            log.debug("The room whose self-ping was answered with item-not-found is \(room)")
            context.emitEvent(.mucSelfPingFailed(room: room, reason: .nickChanged(nickname)))
        case .remoteServerNotFound, .remoteServerTimeout:
            // Transient — retry on next interval
            log.debug("Self-ping remote error for \(room): \(error.condition.rawValue)")
        case .notAcceptable,
             .badRequest, .conflict, .forbidden, .gone, .internalServerError,
             .jidMalformed, .notAllowed, .notAuthorized, .policyViolation,
             .recipientUnavailable, .redirect, .registrationRequired,
             .resourceConstraint, .subscriptionRequired, .undefinedCondition,
             .unexpectedRequest:
            // XEP-0410 §3.2: not-acceptable means not joined, and any other error probably does too.
            log.warning("Self-ping answered with \(error.condition.rawValue), so the room is no longer joined")
            log.debug("The room that is no longer joined is \(room)")
            context.emitEvent(.mucSelfPingFailed(room: room, reason: .notJoined))
        }
    }

    private func buildJoinPresence(
        room: BareJID,
        nickname: String,
        password: String?,
        history: RoomHistoryFetch = .initial,
        context: ModuleContext
    ) -> XMPPPresence {
        guard let fullJID = FullJID(bareJID: room, resourcePart: nickname) else {
            // Fallback: this shouldn't happen with valid nickname
            return XMPPPresence(to: .bare(room))
        }
        var presence = XMPPPresence(to: .full(fullJID), id: context.generateID())
        var mucElement = XMLElement(name: "x", namespace: XMPPNamespaces.muc)
        if let password {
            var passwordElement = XMLElement(name: "password")
            passwordElement.addText(password)
            mucElement.addChild(passwordElement)
        }
        switch history {
        case .initial:
            break
        case let .since(timestamp):
            let historyElement = XMLElement(name: "history", attributes: ["since": timestamp])
            mucElement.addChild(historyElement)
        case .skip:
            let historyElement = XMLElement(name: "history", attributes: ["maxchars": "0", "maxstanzas": "0"])
            mucElement.addChild(historyElement)
        }
        presence.element.addChild(mucElement)
        return presence
    }

    private func appendReason(_ reason: String?, to item: inout XMLElement) {
        guard let reason else { return }
        var reasonElement = XMLElement(name: "reason")
        reasonElement.addText(reason)
        item.addChild(reasonElement)
    }

    private func parseStatusCodes(_ mucUser: XMLElement?) -> Set<Int> {
        guard let mucUser else { return [] }
        var codes = Set<Int>()
        for status in mucUser.children(named: "status") {
            if let codeStr = status.attribute("code"), let code = Int(codeStr) {
                codes.insert(code)
            }
        }
        return codes
    }
}
