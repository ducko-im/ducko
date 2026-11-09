import DuckoXMPP

/// Who sent a room's message or a room's private message, as known when it was stored. Unlike the nickname, it tells
/// the author apart from whoever holds that nickname later.
public struct RoomSenderIdentity: Codable, Sendable, Hashable {
    /// The room's XEP-0421 occupant id for the sender, kept only from a room that advertises them.
    public var occupantID: String?
    public var realJID: String?
    /// The sender's continuous presence in the room under their nickname, known only for a message received live.
    public var presenceSession: String?

    public init(occupantID: String? = nil, realJID: String? = nil, presenceSession: String? = nil) {
        self.occupantID = occupantID
        self.realJID = realJID
        self.presenceSession = presenceSession
    }
}

extension RoomSenderIdentity {
    init(_ author: RoomAuthorIdentity) {
        self.init(occupantID: author.occupantID, realJID: author.realJID?.description, presenceSession: author.presenceSession)
    }
}
