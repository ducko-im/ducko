/// MUC affiliation per XEP-0045 §5.2.
public enum MUCAffiliation: String, Sendable, Hashable {
    case owner, admin, member, outcast, none
}

/// Controls history retrieval when joining a MUC room per XEP-0045 §7.1.16.
public enum RoomHistoryFetch: Sendable {
    /// Omit `<history>`, let the server decide.
    case initial
    /// Request messages since the given ISO 8601 timestamp.
    case since(String)
    /// Skip all history.
    case skip
}

/// What a join asked of a room, so a caller waiting on it knows which confirmation to wait for.
public enum RoomJoinOutcome: Sendable, Equatable {
    /// The join presence went out; the room confirms it with `.roomJoined`.
    case joining
    /// The user is in the room under that nickname already, so nothing was sent.
    case alreadyJoined
    /// The user is in the room under another nickname, so a nickname change went out; the room confirms it with the
    /// user's own `.roomOccupantNickChanged`.
    case changingNickname
}

/// An item from an affiliation list query (muc#admin).
public struct MUCAffiliationItem: Sendable {
    public let jid: BareJID
    public let affiliation: MUCAffiliation
    public let nickname: String?
    public let reason: String?

    public init(jid: BareJID, affiliation: MUCAffiliation, nickname: String? = nil, reason: String? = nil) {
        self.jid = jid
        self.affiliation = affiliation
        self.nickname = nickname
        self.reason = reason
    }

    /// Parses a `MUCAffiliationItem` from an `<item>` element in a muc#admin query result.
    public static func parse(_ item: XMLElement) -> MUCAffiliationItem? {
        guard let jidString = item.attribute("jid"),
              let jid = BareJID.parse(jidString),
              let affiliationStr = item.attribute("affiliation") else { return nil }

        let affiliation = MUCAffiliation(rawValue: affiliationStr) ?? .none
        let nickname = item.attribute("nick")
        let reason = item.child(named: "reason")?.textContent

        return MUCAffiliationItem(jid: jid, affiliation: affiliation, nickname: nickname, reason: reason)
    }
}

/// MUC role per XEP-0045 §5.1.
public enum MUCRole: String, Sendable, Hashable {
    case moderator, participant, visitor, none
}

/// Reason an occupant was removed from a MUC room per XEP-0045 status codes.
public enum OccupantLeaveReason: Sendable, Hashable {
    case kicked(reason: String?) // status 307
    case banned(reason: String?) // status 301
    case affiliationChanged(reason: String?) // status 321
    case serviceShutdown // status 332
}

/// Room status flags surfaced on join per XEP-0045 status codes.
public enum RoomFlag: Sendable, Hashable {
    /// Status 100: room is non-anonymous — occupants' real JIDs are visible to all.
    case nonAnonymous
    /// Status 170: room conversation is being logged.
    case logged
}

/// An occupant in a MUC room.
public struct RoomOccupant: Sendable, Hashable {
    public let nickname: String
    public let jid: BareJID?
    public let affiliation: MUCAffiliation
    public let role: MUCRole

    public init(nickname: String, jid: BareJID? = nil, affiliation: MUCAffiliation, role: MUCRole) {
        self.nickname = nickname
        self.jid = jid
        self.affiliation = affiliation
        self.role = role
    }

    /// Parses a `RoomOccupant` from a `<item>` element inside `<x xmlns='muc#user'>`.
    public static func parse(_ item: XMLElement, nickname: String) -> RoomOccupant? {
        guard let affiliationStr = item.attribute("affiliation"),
              let roleStr = item.attribute("role") else { return nil }

        let affiliation = MUCAffiliation(rawValue: affiliationStr) ?? .none
        let role = MUCRole(rawValue: roleStr) ?? .none
        let jid = item.attribute("jid").flatMap { JID.parse($0)?.bareJID }

        return RoomOccupant(nickname: nickname, jid: jid, affiliation: affiliation, role: role)
    }
}

/// Snapshot of room state after joining.
public struct RoomOccupancy: Sendable {
    public let nickname: String
    public let occupants: [RoomOccupant]
    public let subject: String?
    public let flags: Set<RoomFlag>

    public init(nickname: String, occupants: [RoomOccupant], subject: String?, flags: Set<RoomFlag> = []) {
        self.nickname = nickname
        self.occupants = occupants
        self.subject = subject
        self.flags = flags
    }
}

/// A MUC room invitation.
public struct RoomInvite: Sendable {
    public let room: BareJID
    public let from: JID
    public let reason: String?
    public let password: String?
    public let isDirect: Bool
    public let isContinuation: Bool
    public let thread: String?

    public init(
        room: BareJID,
        from: JID,
        reason: String? = nil,
        password: String? = nil,
        isDirect: Bool = false,
        isContinuation: Bool = false,
        thread: String? = nil
    ) {
        self.room = room
        self.from = from
        self.reason = reason
        self.password = password
        self.isDirect = isDirect
        self.isContinuation = isContinuation
        self.thread = thread
    }
}
