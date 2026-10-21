import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore

private let conversationID = UUID()

extension FileTranscriptStoreTests {
    struct EncryptedMessages {
        private func encrypted(
            stanzaID: String, serverID: String?, body: String = "", timestamp: Date = Date(), isUndecryptable: Bool = false,
            from: Sender = .alice
        ) -> ChatMessage {
            ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: stanzaID, serverID: serverID, fromJID: from.jid,
                body: body, timestamp: timestamp, isOutgoing: from == .me, isDelivered: false, isEdited: false, type: "chat",
                isEncrypted: true, isUndecryptable: isUndecryptable
            )
        }

        /// Who wrote a message: a contact, or the user from one of their devices.
        enum Sender: String, Sendable {
            case alice
            case bob
            case me

            var jid: String {
                "\(rawValue)@example.com"
            }
        }

        /// A stored message and a later copy with the same message id.
        struct IDReuse: Sendable, CustomTestStringConvertible {
            let stored: (from: Sender, serverID: String?)
            let later: (from: Sender, serverID: String?)
            let fromArchive: Bool
            let outcome: EncryptedMessageStoreOutcome

            var testDescription: String {
                "\(stored.from) \(stored.serverID ?? "-") then \(later.from) \(later.serverID ?? "-")\(fromArchive ? " from the archive" : "")"
            }
        }

        @Test(arguments: [
            // A message id restarts with each client, so it matches only within one direction and one sender.
            IDReuse(stored: (.alice, nil), later: (.me, nil), fromArchive: false, outcome: .inserted),
            IDReuse(stored: (.me, nil), later: (.alice, nil), fromArchive: false, outcome: .inserted),
            IDReuse(stored: (.bob, nil), later: (.alice, nil), fromArchive: false, outcome: .inserted),
            IDReuse(stored: (.alice, nil), later: (.me, "S9"), fromArchive: true, outcome: .inserted),
            // A live copy's own server id tells it apart from an older message.
            IDReuse(stored: (.alice, "S1"), later: (.alice, "S2"), fromArchive: false, outcome: .inserted),
            // The archive's copy of a message the user sent, stored before the server gave it an id.
            IDReuse(stored: (.me, nil), later: (.me, "S9"), fromArchive: true, outcome: .duplicate)
        ])
        func `A reused message id is a copy only in the same direction and from the same sender`(reuse: IDReuse) async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                try await store.appendMessage(encrypted(stanzaID: "ducko-4", serverID: reuse.stored.serverID, body: "first", from: reuse.stored.from))

                let later = encrypted(stanzaID: "ducko-4", serverID: reuse.later.serverID, body: "second", from: reuse.later.from)
                let outcome = try await store.storeEncryptedMessage(later, fromArchive: reuse.fromArchive)

                #expect(outcome == reuse.outcome)
                let bodies = try await store.fetchMessages(for: conversationID, before: nil, limit: 10).map(\.body)
                #expect(bodies.sorted() == (reuse.outcome == .inserted ? ["first", "second"] : ["first"]))
            }
        }

        enum Placeholder: String, CaseIterable, Sendable {
            case liveCopyUndecryptable
            case retracted
            case sentByUser
        }

        @Test(arguments: Placeholder.allCases)
        func `An undecryptable copy takes nothing from a copy that cannot fill it in`(placeholder kind: Placeholder) async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let placeholder = encrypted(stanzaID: "ducko-5", serverID: "S1", isUndecryptable: true, from: kind == .sentByUser ? .me : .alice)
                try await store.appendMessage(placeholder)
                if kind == .retracted {
                    try await store.appendAmendment(TranscriptAmendment(action: .retract, targetMessageID: placeholder.id), conversationID: conversationID)
                }

                let live = encrypted(stanzaID: "ducko-5", serverID: "S1", body: "hello", isUndecryptable: kind == .liveCopyUndecryptable)
                let outcome = try await store.storeEncryptedMessage(live, fromArchive: false)

                #expect(outcome == .duplicate)
                let message = try #require(try await store.fetchMessages(for: conversationID, before: nil, limit: 10).first)
                #expect(message.body.isEmpty)
                #expect(message.isUndecryptable)
            }
        }

        @Test
        func `A new message is stored, a copy under its server id is not, and a live copy without one matches by id`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                var outcomes: [EncryptedMessageStoreOutcome] = []
                for (serverID, fromArchive): (String?, Bool) in [("S1", false), ("S1", true), (nil, false), ("S2", true)] {
                    let message = encrypted(stanzaID: "ducko-1", serverID: serverID, body: "hi")
                    try await outcomes.append(store.storeEncryptedMessage(message, fromArchive: fromArchive))
                }

                // The same id under another server id is another message.
                #expect(outcomes == [.inserted, .duplicate, .duplicate, .inserted])
                let messages = try await store.fetchMessages(for: conversationID, before: nil, limit: 10)
                #expect(messages.count == 2)
            }
        }

        @Test
        func `A decrypted copy fills in the undecryptable one in its own day's file, across a restart`() async throws {
            try await withTemporaryDirectory { dir in
                let twoDaysAgo = Date().addingTimeInterval(-2 * 86400)
                let placeholder = encrypted(stanzaID: "ducko-2", serverID: "S1", timestamp: twoDaysAgo, isUndecryptable: true)
                try await FileTranscriptStore(baseDirectory: dir).appendMessage(placeholder)

                let outcome = try await FileTranscriptStore(baseDirectory: dir)
                    .storeEncryptedMessage(encrypted(stanzaID: "ducko-2", serverID: "S1", body: "hello"), fromArchive: false)

                // Transcripts keep timestamps to the second.
                let storedTimestamp = Date(timeIntervalSince1970: twoDaysAgo.timeIntervalSince1970.rounded(.down))
                #expect(outcome == .upgraded(placeholderID: placeholder.id, timestamp: storedTimestamp))
                let messages = try await FileTranscriptStore(baseDirectory: dir).fetchMessages(for: conversationID, before: nil, limit: 10)
                #expect(messages.map(\.id) == [placeholder.id])
                #expect(messages.first?.body == "hello")
                #expect(messages.first?.isUndecryptable == false)
                #expect(messages.first?.isEdited == false)
                #expect(try await FileTranscriptStore(baseDirectory: dir).transcriptDays(for: conversationID).count == 1)
            }
        }

        /// The placeholder came from outside the encryption, so it named no reply or file of its own, and a correction it
        /// took first names none either.
        @Test(arguments: [false, true])
        func `A decrypted copy brings the reply and files only its encryption names, across a restart`(correctedFirst: Bool) async throws {
            try await withTemporaryDirectory { dir in
                let placeholder = encrypted(stanzaID: "ducko-6", serverID: "S1", isUndecryptable: true)
                try await FileTranscriptStore(baseDirectory: dir).appendMessage(placeholder)
                if correctedFirst {
                    try await FileTranscriptStore(baseDirectory: dir).appendAmendment(
                        TranscriptAmendment(action: .edit, targetMessageID: placeholder.id, body: "yes!"), conversationID: conversationID
                    )
                }
                var copy = encrypted(stanzaID: "ducko-6", serverID: "S1", body: "> hi\nyes")
                copy.replyToID = "ducko-0"
                copy.replyToJID = Sender.me.jid
                copy.replyFallbackRange = 0 ..< 5
                copy.attachments = [Attachment(id: UUID(), url: "https://example.com/photo.jpg")]

                _ = try await FileTranscriptStore(baseDirectory: dir).storeEncryptedMessage(copy, fromArchive: false)

                let message = try #require(try await FileTranscriptStore(baseDirectory: dir).fetchMessages(for: conversationID, before: nil, limit: 10).first)
                #expect(message.replyToID == "ducko-0")
                #expect(message.replyToJID == Sender.me.jid)
                #expect(message.replyFallbackRange == (correctedFirst ? nil : 0 ..< 5))
                #expect(message.attachments.map(\.url) == ["https://example.com/photo.jpg"])
            }
        }

        @Test(arguments: [TranscriptAmendment.Action.retract, .edit])
        func `Decrypted text yields to a retraction and to a correction`(earlier: TranscriptAmendment.Action) async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let placeholder = encrypted(stanzaID: "ducko-3", serverID: "S1", isUndecryptable: true)
                try await store.appendMessage(placeholder)
                try await store.appendAmendment(
                    TranscriptAmendment(action: earlier, targetMessageID: placeholder.id, body: "corrected"), conversationID: conversationID
                )

                try await store.appendAmendment(
                    TranscriptAmendment(action: .decrypted, targetMessageID: placeholder.id, body: "hello"), conversationID: conversationID
                )

                let message = try #require(try await store.fetchMessages(for: conversationID, before: nil, limit: 10).first)
                #expect(message.body == (earlier == .retract ? "" : "corrected"))
                #expect(message.isRetracted == (earlier == .retract))
                #expect(!message.isUndecryptable)
            }
        }
    }
}
