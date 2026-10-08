import Foundation

/// One day of one conversation's stored history, the span one transcript file covers.
public struct TranscriptDay: Hashable, Sendable {
    public let conversationID: UUID
    /// The start of the UTC day.
    public let date: Date

    public init(conversationID: UUID, date: Date) {
        self.conversationID = conversationID
        self.date = date
    }
}
