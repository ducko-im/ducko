import Foundation

/// A contact's request for unencrypted messages (an OMEMO opt-out), held on the conversation it came in until the user
/// switches encryption back on or the contact sends encrypted messages again.
public struct PlaintextRequest: Sendable, Equatable {
    /// Who asked: the contact's bare JID in a 1:1 chat, the occupant's nickname in a room.
    public var requester: String
    public var reason: String?
    /// The user switched encryption off after the request, or it was off already, so sends go out unencrypted.
    public var isConfirmed: Bool

    public init(requester: String, reason: String?, isConfirmed: Bool) {
        self.requester = requester
        self.reason = reason
        self.isConfirmed = isConfirmed
    }

    /// Whether this is the request `requester` made for `reason`, answered or not.
    func isSame(requester: String, reason: String?) -> Bool {
        self.requester == requester && self.reason == reason
    }

    /// What the request says, as the chat, the composer and the CLI show it.
    public static func summary(requester: String, reason: String?) -> String {
        "\(requester) asked for unencrypted messages" + (reason.map { " (\($0))" } ?? "")
    }
}
