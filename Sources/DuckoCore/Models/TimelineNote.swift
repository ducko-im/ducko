import Foundation

/// A line in a chat's timeline that records an event around the chat's encryption, such as a contact's message
/// switching it on. It is not a message: nothing sends it, and unread counts, notifications, previews and archive sync
/// never see it.
public struct TimelineNote: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, Codable {
        /// A contact's encrypted message switched encryption on for the chat.
        case encryptionEnabledByContact = "encryption-enabled-by-contact"
        /// The contact, or the room occupant `subject`, asked for unencrypted messages, for the reason in `detail`,
        /// if any.
        case plaintextRequested = "plaintext-requested"
        /// The contact who asked for unencrypted messages sent an encrypted one after the user switched encryption off.
        case encryptionResumedByContact = "encryption-resumed-by-contact"
        /// The user reset the encryption sessions with the contact. `detail` lists the devices that need attention.
        case sessionsReset = "sessions-reset"
    }

    public var id: UUID
    public var conversationID: UUID
    public var timestamp: Date
    public var kind: Kind
    /// Who the note is about, when that is a room occupant rather than the chat's contact: the occupant's nickname.
    public var subject: String?
    /// What the note adds to what its kind says.
    public var detail: String?

    public init(
        id: UUID = UUID(), conversationID: UUID, timestamp: Date = Date(), kind: Kind, subject: String? = nil, detail: String? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.timestamp = timestamp
        self.kind = kind
        self.subject = subject
        self.detail = detail
    }

    /// What the note says, naming the contact the way the surface showing it does.
    public func text(contactName: String) -> String {
        switch kind {
        case .encryptionEnabledByContact:
            "Encryption enabled because \(contactName) sent an encrypted message"
        case .plaintextRequested:
            PlaintextRequest.summary(requester: subject ?? contactName, reason: detail)
        case .encryptionResumedByContact:
            "\(contactName) sent an encrypted message again. Encryption stays off until you switch it on"
        case .sessionsReset:
            "Encryption sessions with \(contactName) reset" + (detail.map { ". \($0)" } ?? "")
        }
    }
}
