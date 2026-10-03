import Foundation

/// One row of a chat's timeline: a message, or a note between messages.
public enum TimelineItem: Sendable, Identifiable {
    case message(ChatMessage)
    case note(TimelineNote)

    public var id: UUID {
        switch self {
        case let .message(message): message.id
        case let .note(note): note.id
        }
    }

    public var timestamp: Date {
        switch self {
        case let .message(message): message.timestamp
        case let .note(note): note.timestamp
        }
    }

    /// Messages and notes as one timeline. The messages keep the order they come in, oldest first. Each note goes after
    /// the last row that is not newer than it, so a note stamped at the same moment as a message follows it, since a
    /// note reports what a message led to.
    public static func merged(messages: [ChatMessage], notes: [TimelineNote]) -> [TimelineItem] {
        var items = messages.map(TimelineItem.message)
        for note in notes.sorted(by: { $0.timestamp < $1.timestamp }) {
            let index = items.lastIndex { $0.timestamp <= note.timestamp }.map { $0 + 1 } ?? 0
            items.insert(.note(note), at: index)
        }
        return items
    }
}
