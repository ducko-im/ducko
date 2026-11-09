/// Who sent a room or room-private stanza, as known when it arrived.
public struct RoomAuthorIdentity: Sendable, Hashable {
    /// Whether the room advertised XEP-0421 occupant ids when this was taken; nil when its features were unknown.
    public let roomSupportsOccupantIDs: Bool?
    /// The stanza's own occupant id, set only when `roomSupportsOccupantIDs` is true.
    public let occupantID: String?
    public let realJID: BareJID?
    /// Identifies the sender's continuous presence in the room under its nickname.
    public let presenceSession: String?

    public init(
        roomSupportsOccupantIDs: Bool?,
        occupantID: String? = nil,
        realJID: BareJID? = nil,
        presenceSession: String? = nil
    ) {
        self.roomSupportsOccupantIDs = roomSupportsOccupantIDs
        self.occupantID = occupantID
        self.realJID = realJID
        self.presenceSession = presenceSession
    }
}
