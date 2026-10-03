import Foundation
import Testing
@testable import DuckoCore

struct TimelineItemTests {
    private func makeMessage(at timestamp: Date) -> ChatMessage {
        ChatMessage(
            id: UUID(), conversationID: UUID(), fromJID: "alice@example.com", body: "hi",
            timestamp: timestamp, isOutgoing: false, isDelivered: false, isEdited: false, type: "chat"
        )
    }

    @Test func `notes are merged among the messages by time, a note following a message of the same moment`() {
        let start = Date(timeIntervalSince1970: 1_772_280_000)
        let first = makeMessage(at: start)
        let second = makeMessage(at: start.addingTimeInterval(10))
        let sameMoment = TimelineNote(conversationID: first.conversationID, timestamp: start, kind: .encryptionEnabledByContact)
        let last = TimelineNote(conversationID: first.conversationID, timestamp: start.addingTimeInterval(20), kind: .encryptionEnabledByContact)

        let items = TimelineItem.merged(messages: [first, second], notes: [last, sameMoment])

        #expect(items.map(\.id) == [first.id, sameMoment.id, second.id, last.id])
    }

    @Test func `a note leaves the messages in the order they came in`() {
        let start = Date(timeIntervalSince1970: 1_772_280_000)
        // A message that arrived late follows a newer one, as it does in a day's transcript.
        let newer = makeMessage(at: start.addingTimeInterval(10))
        let late = makeMessage(at: start)
        let note = TimelineNote(conversationID: newer.conversationID, timestamp: start.addingTimeInterval(20), kind: .encryptionEnabledByContact)

        let items = TimelineItem.merged(messages: [newer, late], notes: [note])

        #expect(items.map(\.id) == [newer.id, late.id, note.id])
    }
}
