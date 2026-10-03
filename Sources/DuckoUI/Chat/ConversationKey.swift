import Foundation

/// Open-time identity for a chat tab (and contact-list selection): the account plus the full
/// open-string JID (`room@conf/nick` for a MUC PM is distinct from the room's `room@conf`). The
/// same peer JID under two accounts is two distinct keys, so it opens two distinct tabs.
///
/// `hash(into:)` is spelled out explicitly so Periphery sees concrete reads of both fields
/// (synthesized `Hashable` is flagged non-deterministically as assign-only — see `RoomJoinKey`).
///
/// `accountID` is `UUID?` only for the defensive open-time path; in practice every produced key
/// carries a concrete account. Not reused from `ConversationRef` (the load-time identity): a key
/// built at open time would have nil `conversationID`/`type` and never match a later
/// `ConversationRef(conversation:)`, a hash-stability footgun.
public struct ConversationKey: Hashable, Codable {
    public let accountID: UUID?
    public let jid: String

    public init(accountID: UUID?, jid: String) {
        self.accountID = accountID
        self.jid = jid
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(accountID)
        hasher.combine(jid)
    }
}
