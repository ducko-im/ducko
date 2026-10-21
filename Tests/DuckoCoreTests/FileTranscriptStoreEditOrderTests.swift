import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore

struct FileTranscriptStoreEditOrderTests {
    @Test(arguments: [false, true])
    func `A correction older than the one applied already does not overwrite it`(coldRead: Bool) async throws {
        try await withTemporaryDirectory { dir in
            let store = FileTranscriptStore(baseDirectory: dir)
            let conversationID = UUID()
            let sentAt = Date(timeIntervalSince1970: 1_772_272_800)
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "s1", fromJID: "alice@example.com", body: "original",
                timestamp: sentAt, isOutgoing: false, isDelivered: false, isEdited: false, type: "chat"
            )
            try await store.appendMessage(message)

            for (minutes, body) in [(10.0, "newer"), (5.0, "older")] {
                try await store.appendAmendment(
                    TranscriptAmendment(action: .edit, targetMessageID: message.id, timestamp: sentAt.addingTimeInterval(minutes * 60), body: body),
                    conversationID: conversationID
                )
            }

            let reader = coldRead ? FileTranscriptStore(baseDirectory: dir) : store
            let stored = try #require(try await reader.fetchMessages(for: conversationID, before: nil, limit: 50).first)
            #expect(stored.body == "newer")
            #expect(stored.editedAt == sentAt.addingTimeInterval(600))
        }
    }

    /// The test store stands in for the file store, so the two apply an edit alike.
    @Test(arguments: [false, true])
    func `An edit replaces the HTML along with the body, and one without a body changes nothing`(isMock: Bool) async throws {
        try await withTemporaryDirectory { dir in
            let store: any TranscriptStore = isMock ? MockTranscriptStore() : FileTranscriptStore(baseDirectory: dir)
            let conversationID = UUID()
            let message = ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "s1", fromJID: "alice@example.com", body: "*old*",
                htmlBody: "<strong>old</strong>", timestamp: Date(timeIntervalSince1970: 1_772_272_800), isOutgoing: false, isDelivered: false,
                isEdited: false, type: "chat"
            )
            try await store.appendMessage(message)

            try await store.appendAmendment(TranscriptAmendment(action: .edit, targetMessageID: message.id, timestamp: message.timestamp), conversationID: conversationID)
            let unchanged = try #require(try await store.fetchMessages(for: conversationID, before: nil, limit: 50).first)
            try await store.appendAmendment(
                TranscriptAmendment(action: .edit, targetMessageID: message.id, timestamp: message.timestamp, body: "plain"), conversationID: conversationID
            )
            let edited = try #require(try await store.fetchMessages(for: conversationID, before: nil, limit: 50).first)

            #expect(!unchanged.isEdited)
            #expect(unchanged.htmlBody == "<strong>old</strong>")
            #expect(edited.body == "plain")
            #expect(edited.htmlBody == nil)
        }
    }
}
