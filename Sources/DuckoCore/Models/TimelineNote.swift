import Foundation

/// A line in a chat's timeline that records something this app did, such as switching encryption on. It is not a
/// message: nothing sends it, and unread counts, notifications, previews and archive sync never see it.
public struct TimelineNote: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable, Codable {
        /// A contact's encrypted message switched encryption on for the chat.
        case encryptionEnabledByContact = "encryption-enabled-by-contact"
    }

    public var id: UUID
    public var conversationID: UUID
    public var timestamp: Date
    public var kind: Kind

    public init(id: UUID = UUID(), conversationID: UUID, timestamp: Date = Date(), kind: Kind) {
        self.id = id
        self.conversationID = conversationID
        self.timestamp = timestamp
        self.kind = kind
    }

    /// What the note says, naming the contact the way the surface showing it does.
    public func text(contactName: String) -> String {
        switch kind {
        case .encryptionEnabledByContact:
            "Encryption enabled because \(contactName) sent an encrypted message"
        }
    }
}
