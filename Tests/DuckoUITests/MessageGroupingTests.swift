import DuckoCore
import Foundation
import Testing
@testable import DuckoUI

struct MessageGroupingTests {
    private func makeMessage(
        id: UUID = UUID(),
        fromJID: String = "alice@example.com",
        isOutgoing: Bool = false,
        timestamp: Date = Date()
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            conversationID: UUID(),
            fromJID: fromJID,
            body: "test",
            timestamp: timestamp,
            isOutgoing: isOutgoing,
            isDelivered: false,
            isEdited: false,
            type: "chat"
        )
    }

    @Test func `empty array`() {
        let positions = computeMessagePositions([])
        #expect(positions.isEmpty)
    }

    @Test func `single message`() throws {
        let msg = makeMessage()
        let positions = computeMessagePositions([.message(msg)])

        let pos = try #require(positions[msg.id])
        #expect(pos.isFirstInGroup)
        #expect(pos.isLastInGroup)
    }

    @Test func `same sender within grouping interval`() throws {
        let now = Date()
        let msg1 = makeMessage(timestamp: now)
        let msg2 = makeMessage(timestamp: now.addingTimeInterval(30))
        let msg3 = makeMessage(timestamp: now.addingTimeInterval(60))

        let positions = computeMessagePositions([.message(msg1), .message(msg2), .message(msg3)])

        let pos1 = try #require(positions[msg1.id])
        #expect(pos1.isFirstInGroup)
        #expect(!pos1.isLastInGroup)

        let pos2 = try #require(positions[msg2.id])
        #expect(!pos2.isFirstInGroup)
        #expect(!pos2.isLastInGroup)

        let pos3 = try #require(positions[msg3.id])
        #expect(!pos3.isFirstInGroup)
        #expect(pos3.isLastInGroup)
    }

    @Test func `same sender over grouping interval`() throws {
        let now = Date()
        let msg1 = makeMessage(timestamp: now)
        let msg2 = makeMessage(timestamp: now.addingTimeInterval(150))

        let positions = computeMessagePositions([.message(msg1), .message(msg2)])

        let pos1 = try #require(positions[msg1.id])
        #expect(pos1.isFirstInGroup)
        #expect(pos1.isLastInGroup)

        let pos2 = try #require(positions[msg2.id])
        #expect(pos2.isFirstInGroup)
        #expect(pos2.isLastInGroup)
    }

    @Test func `alternating senders`() throws {
        let now = Date()
        let msg1 = makeMessage(fromJID: "alice@example.com", timestamp: now)
        let msg2 = makeMessage(fromJID: "bob@example.com", timestamp: now.addingTimeInterval(10))
        let msg3 = makeMessage(fromJID: "alice@example.com", timestamp: now.addingTimeInterval(20))

        let positions = computeMessagePositions([.message(msg1), .message(msg2), .message(msg3)])

        for msg in [msg1, msg2, msg3] {
            let pos = try #require(positions[msg.id])
            #expect(pos.isFirstInGroup)
            #expect(pos.isLastInGroup)
        }
    }

    @Test func `a note between two messages splits their group`() throws {
        let now = Date()
        let msg1 = makeMessage(timestamp: now)
        let msg2 = makeMessage(timestamp: now.addingTimeInterval(10))
        let note = TimelineNote(conversationID: UUID(), timestamp: now.addingTimeInterval(5), kind: .encryptionEnabledByContact)

        let positions = computeMessagePositions([.message(msg1), .note(note), .message(msg2)])

        #expect(try #require(positions[msg1.id]).isLastInGroup)
        #expect(try #require(positions[msg2.id]).isFirstInGroup)
        #expect(positions[note.id] == nil)
    }

    @Test func `outgoing incoming groups separately`() throws {
        let now = Date()
        let msg1 = makeMessage(fromJID: "me@example.com", isOutgoing: true, timestamp: now)
        let msg2 = makeMessage(fromJID: "me@example.com", isOutgoing: false, timestamp: now.addingTimeInterval(10))

        let positions = computeMessagePositions([.message(msg1), .message(msg2)])

        let pos1 = try #require(positions[msg1.id])
        #expect(pos1.isFirstInGroup)
        #expect(pos1.isLastInGroup)

        let pos2 = try #require(positions[msg2.id])
        #expect(pos2.isFirstInGroup)
        #expect(pos2.isLastInGroup)
    }
}
