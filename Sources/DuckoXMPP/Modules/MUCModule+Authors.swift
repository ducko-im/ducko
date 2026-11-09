/// Who sent a room's stanzas: the user's own occupant id, each occupant's presence session, and the author snapshot
/// taken as a stanza arrives.
public extension MUCModule {
    /// The occupant id the room gave the user's own presence. Kept whether or not the room advertises occupant ids, so
    /// a reader checks that before trusting it.
    func ownOccupantID(in room: BareJID) -> String? {
        state.withLock { $0.rooms[room]?.ownOccupantID }
    }

    /// The presence session of the user's nickname, once the room has confirmed it.
    func ownPresenceSession(in room: BareJID) -> String? {
        state.withLock { state in
            state.rooms[room].flatMap { room in room.confirmedNickname.flatMap { room.presenceSessions[$0] } }
        }
    }

    /// Who sent `message` through `room`, as the stanza shows it now. The occupant id is the stanza's own, and only when
    /// the room advertises occupant ids. The real JID and presence session are those of whoever holds the sender's
    /// nickname, so a delayed stanza, such as join history, gets neither. Nil for a room the module does not track.
    func roomAuthor(of message: XMPPMessage, in room: BareJID) -> RoomAuthorIdentity? {
        let nickname: String? = if case let .full(fullJID) = message.from { fullJID.resourcePart } else { nil }
        return state.withLock { state in
            guard let roomState = state.rooms[room] else { return nil }
            let supportsOccupantIDs = state.knownRoomInfo[room]?.supportsOccupantIDs
            let occupantID = supportsOccupantIDs == true ? message.occupantID : nil
            guard !message.isDelayed, let nickname else {
                return RoomAuthorIdentity(roomSupportsOccupantIDs: supportsOccupantIDs, occupantID: occupantID)
            }
            return RoomAuthorIdentity(
                roomSupportsOccupantIDs: supportsOccupantIDs,
                occupantID: occupantID,
                realJID: roomState.occupants[nickname]?.jid,
                presenceSession: roomState.presenceSessions[nickname]
            )
        }
    }
}

public extension ServiceDiscoveryModule.InfoResult {
    /// Whether the room whose disco#info this is stamps each occupant's stanzas with an occupant id (XEP-0421).
    var supportsOccupantIDs: Bool {
        features.contains(XMPPNamespaces.occupantID)
    }
}

extension MUCModule.RoomState {
    /// Gives `nickname` the presence session `id`, unless a presence update continues the one it has.
    mutating func startPresenceSession(of nickname: String, id: String?) {
        guard presenceSessions[nickname] == nil else { return }
        presenceSessions[nickname] = id
    }
}
