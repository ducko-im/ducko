import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore

private let testConversationID = UUID()

private func makeMessage(
    conversationID: UUID = testConversationID,
    stanzaID: String? = nil,
    serverID: String? = nil,
    fromJID: String = "alice@example.com",
    body: String = "hello",
    timestamp: Date = Date(),
    isOutgoing: Bool = false
) -> ChatMessage {
    ChatMessage(
        id: UUID(),
        conversationID: conversationID,
        stanzaID: stanzaID,
        serverID: serverID,
        fromJID: fromJID,
        body: body,
        timestamp: timestamp,
        isOutgoing: isOutgoing,
        isDelivered: false,
        isEdited: false,
        type: "chat"
    )
}

enum FileTranscriptStoreTests {
    struct WriteAndRead {
        @Test(arguments: [false, true])
        func `Write failure propagates from single and batch append`(batch: Bool) async throws {
            try await withTemporaryDirectory { dir in
                let readOnlyFile = dir.appendingPathComponent("read-only")
                let original = Data("unchanged".utf8)
                try original.write(to: readOnlyFile)
                let store = FileTranscriptStore(baseDirectory: dir, openFileHandle: { _ in
                    try FileHandle(forReadingFrom: readOnlyFile)
                })
                let message = makeMessage(stanzaID: "failed")

                await #expect(throws: (any Error).self) {
                    if batch {
                        try await store.appendMessages([message])
                    } else {
                        try await store.appendMessage(message)
                    }
                }
                #expect(try Data(contentsOf: readOnlyFile) == original)
                #expect(try await store.fetchMessages(for: message.conversationID, before: nil, limit: 50).isEmpty)
            }
        }

        @Test
        func `Amendment write failure preserves the original transcript`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let message = makeMessage(stanzaID: "original")
                try await store.appendMessage(message)
                let conversationDirectory = dir.appendingPathComponent(message.conversationID.uuidString)
                let files = try FileManager.default.contentsOfDirectory(at: conversationDirectory, includingPropertiesForKeys: nil)
                let file = try #require(files.first)
                let original = try Data(contentsOf: file)
                #expect(original.last == UInt8(ascii: "\n"))
                #expect(original.split(separator: UInt8(ascii: "\n")).count == 1)
                let failingStore = FileTranscriptStore(baseDirectory: dir, openFileHandle: { url in
                    try FileHandle(forReadingFrom: url)
                })
                let amendment = TranscriptAmendment(action: .edit, targetStanzaID: "original", timestamp: Date(), body: "edited")

                await #expect(throws: (any Error).self) {
                    try await failingStore.appendAmendment(amendment, conversationID: message.conversationID)
                }
                #expect(try Data(contentsOf: file) == original)
                try await store.appendAmendment(amendment, conversationID: message.conversationID)
                let amended = try Data(contentsOf: file)
                #expect(amended.starts(with: original))
                #expect(amended.last == UInt8(ascii: "\n"))
                #expect(amended.split(separator: UInt8(ascii: "\n")).count == 2)
                let reloaded = FileTranscriptStore(baseDirectory: dir)
                let messages = try await reloaded.fetchMessages(for: message.conversationID, before: nil, limit: 50)
                #expect(messages.count == 1)
                #expect(messages.first?.body == "edited")
            }
        }

        @Test
        func `Appended message is retrievable`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let msg = makeMessage(stanzaID: "s1", body: "hello world")
                try await store.appendMessage(msg)

                let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
                #expect(fetched.count == 1)
                #expect(fetched[0].body == "hello world")
                #expect(fetched[0].stanzaID == "s1")
                #expect(fetched[0].conversationID == testConversationID)
            }
        }

        @Test
        func `Batch append writes multiple messages`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let now = Date()
                let messages = (0 ..< 5).map { i in
                    makeMessage(stanzaID: "s\(i)", body: "msg \(i)", timestamp: now.addingTimeInterval(Double(i)))
                }
                try await store.appendMessages(messages)

                let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
                #expect(fetched.count == 5)
            }
        }

        @Test
        func `Concurrent appends from separate store instances produce valid JSONL`() async throws {
            try await withTemporaryDirectory { dir in
                let store1 = FileTranscriptStore(baseDirectory: dir)
                let store2 = FileTranscriptStore(baseDirectory: dir)
                let convID = UUID()
                let base = Date()

                try await withThrowingTaskGroup(of: Void.self) { group in
                    for i in 0 ..< 10 {
                        let store = i.isMultiple(of: 2) ? store1 : store2
                        group.addTask {
                            try await store.appendMessage(makeMessage(
                                conversationID: convID,
                                stanzaID: "s\(i)",
                                body: "msg-\(i)",
                                timestamp: base.addingTimeInterval(Double(i))
                            ))
                        }
                    }
                    try await group.waitForAll()
                }

                let fetched = try await store1.fetchMessages(for: convID, before: nil, limit: 50)
                #expect(fetched.count == 10)
            }
        }
    }

    struct Pagination {
        @Test
        func `Fetch respects limit`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let now = Date()
                let messages = (0 ..< 10).map { i in
                    makeMessage(stanzaID: "s\(i)", body: "msg \(i)", timestamp: now.addingTimeInterval(Double(i)))
                }
                try await store.appendMessages(messages)

                let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 3)
                #expect(fetched.count == 3)
                // Should return newest first
                #expect(fetched[0].body == "msg 9")
            }
        }

        @Test
        func `Fetch before date filters correctly`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let base = Date()
                let old = makeMessage(stanzaID: "old", body: "old", timestamp: base)
                let new = makeMessage(stanzaID: "new", body: "new", timestamp: base.addingTimeInterval(100))
                try await store.appendMessages([old, new])

                let fetched = try await store.fetchMessages(for: testConversationID, before: base.addingTimeInterval(50), limit: 50)
                #expect(fetched.count == 1)
                #expect(fetched[0].body == "old")
            }
        }

        @Test
        func `Messages written within one second come back newest first`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                // Timestamps are stored to the second, so these three tie once written.
                let second = Date(timeIntervalSince1970: 1_772_280_000)
                let older = makeMessage(stanzaID: "older", body: "older", timestamp: second.addingTimeInterval(-60))
                try await store.appendMessage(older)
                for (offset, body) in ["first", "second", "third"].enumerated() {
                    try await store.appendMessage(makeMessage(stanzaID: body, body: body, timestamp: second.addingTimeInterval(Double(offset) / 10)))
                }

                let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)

                #expect(fetched.map(\.body) == ["third", "second", "first", "older"])
            }
        }
    }

    struct Amendments {
        @Test
        func `Edit amendment updates body`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let msg = makeMessage(stanzaID: "s1", body: "original")
                try await store.appendMessage(msg)

                try await store.appendAmendment(TranscriptAmendment(
                    action: .edit, targetStanzaID: "s1", timestamp: Date(), body: "corrected"
                ), conversationID: testConversationID)

                let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
                #expect(fetched[0].body == "corrected")
                #expect(fetched[0].isEdited == true)
                #expect(fetched[0].editedAt != nil)
            }
        }

        @Test
        func `Retraction clears body`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let msg = makeMessage(stanzaID: "s1", body: "secret")
                try await store.appendMessage(msg)

                try await store.appendAmendment(TranscriptAmendment(
                    action: .retract, targetStanzaID: "s1", timestamp: Date()
                ), conversationID: testConversationID)

                let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
                #expect(fetched[0].isRetracted == true)
                #expect(fetched[0].body == "")
            }
        }

        @Test
        func `Displayed amendment marks the message read and delivered`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let msg = makeMessage(stanzaID: "s1", body: "hello", isOutgoing: true)
                try await store.appendMessage(msg)

                try await store.appendAmendment(TranscriptAmendment(
                    action: .displayed, targetMessageID: msg.id
                ), conversationID: testConversationID)

                let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
                #expect(fetched[0].isDisplayed == true)
                #expect(fetched[0].isDelivered == true)
            }
        }

        @Test
        func `Delivery amendment sets isDelivered`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let msg = makeMessage(stanzaID: "s1", body: "hello", isOutgoing: true)
                try await store.appendMessage(msg)

                try await store.appendAmendment(TranscriptAmendment(
                    action: .delivery, targetStanzaID: "s1"
                ), conversationID: testConversationID)

                let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
                #expect(fetched[0].isDelivered == true)
            }
        }

        @Test
        func `Error amendment sets errorText`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let msg = makeMessage(stanzaID: "s1", body: "hello")
                try await store.appendMessage(msg)

                try await store.appendAmendment(TranscriptAmendment(
                    action: .error, targetStanzaID: "s1", errorText: "Service unavailable"
                ), conversationID: testConversationID)

                let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
                #expect(fetched[0].errorText == "Service unavailable")
            }
        }

        @Test
        func `ServerID-only retraction resolves without stanzaID`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let msg = makeMessage(serverID: "mam-123", body: "moderated")
                try await store.appendMessage(msg)

                // Amendment targets serverID only (moderation path)
                try await store.appendAmendment(TranscriptAmendment(
                    action: .retract, targetServerID: "mam-123", timestamp: Date()
                ), conversationID: testConversationID)

                let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
                #expect(fetched[0].isRetracted == true)
                #expect(fetched[0].body == "")
            }
        }

        @Test
        func `ServerID amendment applies when message has both stanzaID and serverID`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                // Append with both stanzaID and serverID
                let msg = makeMessage(stanzaID: "s1", serverID: "mam-456", body: "indexed")
                try await store.appendMessage(msg)

                // Amendment targets serverID only — should match via serverToID map during materialization
                try await store.appendAmendment(TranscriptAmendment(
                    action: .retract, targetServerID: "mam-456", timestamp: Date()
                ), conversationID: testConversationID)

                let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
                #expect(fetched[0].isRetracted == true)
                #expect(fetched[0].body == "")
            }
        }

        @Test
        func `Amendment persists across store instance restart`() async throws {
            // Use two separate store instances to simulate app restart.
            try await withTemporaryDirectory { dir in
                let store1 = FileTranscriptStore(baseDirectory: dir)
                let msg = makeMessage(stanzaID: "cold-sid", body: "original")
                try await store1.appendMessage(msg)

                // New store instance writes the amendment scoped to the conversation.
                let store2 = FileTranscriptStore(baseDirectory: dir)
                try await store2.appendAmendment(TranscriptAmendment(
                    action: .edit, targetStanzaID: "cold-sid", timestamp: Date(), body: "edited after restart"
                ), conversationID: testConversationID)

                let fetched = try await store2.fetchMessages(for: testConversationID, before: nil, limit: 50)
                #expect(fetched[0].body == "edited after restart")
                #expect(fetched[0].isEdited == true)
            }
        }

        @Test
        func `Amendment dated later than message lands in message's date file`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                // Message timestamped two days in the past — different UTC date file.
                let twoDaysAgo = Date().addingTimeInterval(-2 * 86400)
                let msg = makeMessage(stanzaID: "old-sid", body: "from yesterday", timestamp: twoDaysAgo)
                try await store.appendMessage(msg)

                // Amendment timestamped now (today's UTC date) targeting yesterday's message.
                try await store.appendAmendment(TranscriptAmendment(
                    action: .edit, targetStanzaID: "old-sid", timestamp: Date(), body: "edited today"
                ), conversationID: testConversationID)

                // Without conversation-scoped date resolution, the amendment would be
                // written to today's file and never apply to yesterday's message.
                let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
                let target = try #require(fetched.first { $0.stanzaID == "old-sid" })
                #expect(target.body == "edited today")
                #expect(target.isEdited == true)
            }
        }

        @Test
        func `Amendment routes to correct conversation when stanzaIDs collide`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let convA = UUID()
                let convB = UUID()

                // Both conversations have a message with the same stanzaID — possible
                // when alice and bob share a process (multi-account or test harness)
                // and each generates the same client-side ID.
                let msgA = makeMessage(conversationID: convA, stanzaID: "ducko-12", body: "alice's msg")
                let msgB = makeMessage(conversationID: convB, stanzaID: "ducko-12", body: "bob's msg")
                try await store.appendMessage(msgA)
                try await store.appendMessage(msgB)

                // Edit only convA's message.
                try await store.appendAmendment(TranscriptAmendment(
                    action: .edit, targetStanzaID: "ducko-12", timestamp: Date(), body: "alice's edit"
                ), conversationID: convA)

                let fetchedA = try await store.fetchMessages(for: convA, before: nil, limit: 50)
                let fetchedB = try await store.fetchMessages(for: convB, before: nil, limit: 50)

                let targetA = try #require(fetchedA.first { $0.stanzaID == "ducko-12" })
                let targetB = try #require(fetchedB.first { $0.stanzaID == "ducko-12" })

                #expect(targetA.body == "alice's edit")
                #expect(targetA.isEdited == true)
                // convB must remain untouched even though stanzaID matches.
                #expect(targetB.body == "bob's msg")
                #expect(targetB.isEdited == false)
            }
        }

        @Test
        func `Amendment with targetMessageID routes around stanzaID collision within one conversation`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                // Two messages in the SAME conversation share a stanzaID — possible after
                // MAM imports a historical message whose per-session counter (`ducko-N`)
                // happens to match a local-send's counter from a later session.
                let historical = makeMessage(stanzaID: "ducko-12", body: "historical")
                let local = makeMessage(stanzaID: "ducko-12", body: "current send")
                try await store.appendMessage(historical)
                try await store.appendMessage(local)

                // Amendment carries the UUID of the local send — must apply to that
                // specific message even though the historical entry was written first
                // (and would win a stanzaID-only resolution that picks last-write).
                try await store.appendAmendment(TranscriptAmendment(
                    action: .edit, targetMessageID: local.id, targetStanzaID: "ducko-12", timestamp: Date(), body: "edited"
                ), conversationID: testConversationID)

                let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
                let editedLocal = try #require(fetched.first { $0.id == local.id })
                let untouchedHistorical = try #require(fetched.first { $0.id == historical.id })

                #expect(editedLocal.body == "edited")
                #expect(editedLocal.isEdited == true)
                #expect(untouchedHistorical.body == "historical")
                #expect(untouchedHistorical.isEdited == false)
            }
        }

        @Test
        func `UUID-bearing amendment survives store restart`() async throws {
            // Second instance has an empty in-memory uuidIndex — routing must
            // rehydrate from the on-disk `targetMessageID`.
            try await withTemporaryDirectory { dir in
                let store1 = FileTranscriptStore(baseDirectory: dir)
                let msg = makeMessage(stanzaID: "cold-sid", body: "original")
                try await store1.appendMessage(msg)

                let store2 = FileTranscriptStore(baseDirectory: dir)
                try await store2.appendAmendment(TranscriptAmendment(
                    action: .edit, targetMessageID: msg.id, targetStanzaID: "cold-sid", timestamp: Date(), body: "edited via UUID"
                ), conversationID: testConversationID)

                // A third instance proves the targetMessageID round-tripped through JSONL.
                let store3 = FileTranscriptStore(baseDirectory: dir)
                let fetched = try await store3.fetchMessages(for: testConversationID, before: nil, limit: 50)
                let target = try #require(fetched.first { $0.id == msg.id })
                #expect(target.body == "edited via UUID")
                #expect(target.isEdited == true)
            }
        }

        @Test
        func `UUID-bearing amendment fails closed when target UUID is absent from file`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                // Fail-closed contract: no fallback to stanzaID. The amendment
                // must be ignored AND must not write a dangling JSONL record.
                let messageA = makeMessage(stanzaID: "shared-sid", body: "A's body")
                let messageB = makeMessage(stanzaID: "shared-sid", body: "B's body")
                try await store.appendMessage(messageA)
                try await store.appendMessage(messageB)

                let phantomUUID = UUID()
                try await store.appendAmendment(TranscriptAmendment(
                    action: .edit, targetMessageID: phantomUUID, targetStanzaID: "shared-sid", timestamp: Date(), body: "should not apply"
                ), conversationID: testConversationID)

                let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
                let resolvedA = try #require(fetched.first { $0.id == messageA.id })
                let resolvedB = try #require(fetched.first { $0.id == messageB.id })
                #expect(resolvedA.body == "A's body")
                #expect(resolvedA.isEdited == false)
                #expect(resolvedB.body == "B's body")
                #expect(resolvedB.isEdited == false)

                // Confirm no amend record written — a silently-routed amendment
                // would re-surface on a cold-read in another store instance.
                let convDir = dir.appendingPathComponent(testConversationID.uuidString)
                let dateFiles = try FileManager.default.contentsOfDirectory(at: convDir, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "jsonl" }
                for fileURL in dateFiles {
                    let raw = try String(contentsOf: fileURL, encoding: .utf8)
                    #expect(!raw.contains("\"type\":\"amend\""), "Unexpected amendment record in \(fileURL.lastPathComponent)")
                }
            }
        }
    }

    struct Notes {
        @Test
        func `A note is stored beside the messages without becoming one`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let day = Date(timeIntervalSince1970: 1_772_280_000)
                try await store.appendMessage(makeMessage(stanzaID: "s1", timestamp: day))
                let note = TimelineNote(conversationID: testConversationID, timestamp: day.addingTimeInterval(1), kind: .encryptionEnabledByContact)
                try await store.appendNote(note)

                #expect(try await store.fetchNotes(for: testConversationID, since: nil, before: nil) == [note])
                #expect(try await store.fetchMessages(for: testConversationID, before: nil, limit: 50).count == 1)
                #expect(try await store.fetchMessages(for: testConversationID, on: day).count == 1)
                #expect(try await store.messageDateCounts(for: testConversationID).map(\.count) == [1])
            }
        }

        @Test
        func `Notes are fetched within their bounds across day files, oldest first`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let start = Date(timeIntervalSince1970: 1_772_280_000)
                let oneDay: TimeInterval = 24 * 60 * 60
                let notes = (0 ..< 4).map { index in
                    TimelineNote(
                        conversationID: testConversationID,
                        timestamp: start.addingTimeInterval(Double(index) * oneDay),
                        kind: .encryptionEnabledByContact
                    )
                }
                // Written newest first, so the order returned is not the order stored.
                for note in notes.reversed() {
                    try await store.appendNote(note)
                }
                // On the lower bound's own day, a minute before it.
                try await store.appendNote(TimelineNote(
                    conversationID: testConversationID, timestamp: notes[1].timestamp.addingTimeInterval(-60), kind: .encryptionEnabledByContact
                ))
                // On the upper bound's own day, a minute before it and so within the bounds.
                let lastWithin = TimelineNote(
                    conversationID: testConversationID, timestamp: notes[3].timestamp.addingTimeInterval(-60), kind: .encryptionEnabledByContact
                )
                try await store.appendNote(lastWithin)

                let middle = try await store.fetchNotes(for: testConversationID, since: notes[1].timestamp, before: notes[3].timestamp)

                #expect(middle == [notes[1], notes[2], lastWithin])
            }
        }

        @Test
        func `A note of a kind this build does not know is skipped`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let day = Date(timeIntervalSince1970: 1_772_280_000)
                let message = makeMessage(stanzaID: "s1", timestamp: day)
                try await store.appendMessage(message)
                let file = dir.appendingPathComponent(testConversationID.uuidString)
                    .appendingPathComponent(FileTranscriptStore.dateString(for: day) + ".jsonl")
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(
                    #"{"id":"\#(UUID().uuidString)","kind":"from-a-later-release","timestamp":"2026-02-28T12:00:01Z","type":"note"}"#.utf8 + [0x0A]
                ))
                try handle.close()

                #expect(try await store.fetchNotes(for: testConversationID, since: nil, before: nil).isEmpty)
                #expect(try await store.fetchMessages(for: testConversationID, before: nil, limit: 50).map(\.id) == [message.id])
            }
        }
    }

    struct Lookup {
        @Test
        func `Find message by stanzaID`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let msg = makeMessage(stanzaID: "find-me", body: "target")
                try await store.appendMessage(msg)

                let found = try await store.findMessage(stanzaID: "find-me", conversationID: testConversationID)
                #expect(found != nil)
                #expect(found?.body == "target")

                let notFound = try await store.findMessage(stanzaID: "nonexistent", conversationID: testConversationID)
                #expect(notFound == nil)
            }
        }

        @Test
        func `Find message by UUID disambiguates colliding stanzaID`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                // stanzaID-only lookup is ambiguous when `ducko-N` collides;
                // UUID lookup must return the exact named message.
                let historical = makeMessage(stanzaID: "ducko-12", fromJID: "peer@example.com", body: "peer msg", isOutgoing: false)
                let local = makeMessage(stanzaID: "ducko-12", fromJID: "peer@example.com", body: "our msg", isOutgoing: true)
                try await store.appendMessage(historical)
                try await store.appendMessage(local)

                let foundLocal = try await store.findMessage(id: local.id, conversationID: testConversationID)
                #expect(foundLocal?.id == local.id)
                #expect(foundLocal?.isOutgoing == true)
                #expect(foundLocal?.body == "our msg")

                let foundHistorical = try await store.findMessage(id: historical.id, conversationID: testConversationID)
                #expect(foundHistorical?.id == historical.id)
                #expect(foundHistorical?.isOutgoing == false)
                #expect(foundHistorical?.body == "peer msg")

                let notFound = try await store.findMessage(id: UUID(), conversationID: testConversationID)
                #expect(notFound == nil)
            }
        }

        @Test
        func `Find message by UUID rejects cross-conversation hits`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                // A message indexed under convA must not be returned when the
                // caller asks for it under convB — UUIDs are unique globally but
                // the API requires conversation scoping so a future refactor
                // can't loosen the guard without a test failure.
                let convA = UUID()
                let convB = UUID()
                let msg = makeMessage(conversationID: convA, stanzaID: "s-cross", body: "alice's msg")
                try await store.appendMessage(msg)

                let foundInA = try await store.findMessage(id: msg.id, conversationID: convA)
                #expect(foundInA?.id == msg.id)

                let foundInB = try await store.findMessage(id: msg.id, conversationID: convB)
                #expect(foundInB == nil)
            }
        }

        @Test
        func `Find message by serverID`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let msg = makeMessage(serverID: "srv-lookup", body: "server indexed")
                try await store.appendMessage(msg)

                let found = try await store.findMessage(serverID: "srv-lookup", conversationID: testConversationID)
                #expect(found != nil)
                #expect(found?.body == "server indexed")

                let notFound = try await store.findMessage(serverID: "nonexistent", conversationID: testConversationID)
                #expect(notFound == nil)
            }
        }

        @Test
        func `Message exists check`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let msg = makeMessage(stanzaID: "exists", body: "hi")
                try await store.appendMessage(msg)

                let exists = try await store.messageExists(stanzaID: "exists", conversationID: testConversationID)
                #expect(exists == true)

                let notExists = try await store.messageExists(stanzaID: "nope", conversationID: testConversationID)
                #expect(notExists == false)
            }
        }

        @Test
        func `(stanzaID, fromJID) dedup ignores outgoing rows whose fromJID is the recipient`() async throws {
            // Regression: outgoing 1:1 messages persist `fromJID = recipient`
            // (so server carbon copies dedup via stanzaID), so a fresh inbound
            // from bob carrying a stanzaID that collides with a prior outgoing
            // alice→bob row would otherwise be silently dropped. The overload
            // must scope to `!isOutgoing` to keep the inbound dedup honest.
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                // Outgoing alice→bob, stored as `fromJID="bob@example.com"`.
                let outgoing = makeMessage(
                    stanzaID: "collide", fromJID: "bob@example.com", body: "out", isOutgoing: true
                )
                try await store.appendMessage(outgoing)

                // Fresh inbound from bob with the same stanzaID must NOT be deduped.
                let exists = try await store.messageExists(
                    stanzaID: "collide", fromJID: "bob@example.com", conversationID: testConversationID
                )
                #expect(exists == false, "outgoing row leaked into inbound dedup")

                // Now persist a real inbound match — same key must dedup.
                let inbound = makeMessage(
                    stanzaID: "collide", fromJID: "bob@example.com", body: "in", isOutgoing: false
                )
                try await store.appendMessage(inbound)
                let existsAfter = try await store.messageExists(
                    stanzaID: "collide", fromJID: "bob@example.com", conversationID: testConversationID
                )
                #expect(existsAfter == true)
            }
        }
    }

    struct Search {
        @Test
        func `Search finds matching messages`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                try await store.appendMessages([
                    makeMessage(body: "hello world"),
                    makeMessage(body: "goodbye world"),
                    makeMessage(body: "hello there")
                ])

                let results = try await store.searchMessages(query: "hello", conversationID: testConversationID, before: nil, after: nil, limit: 50)
                #expect(results.count == 2)
            }
        }
    }

    struct Lifecycle {
        @Test
        func `Delete transcripts removes conversation directory`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let msg = makeMessage(body: "to be deleted")
                try await store.appendMessage(msg)

                let convDir = dir.appendingPathComponent(testConversationID.uuidString)
                #expect(FileManager.default.fileExists(atPath: convDir.path))

                try await store.deleteTranscripts(for: testConversationID)
                #expect(!FileManager.default.fileExists(atPath: convDir.path))
            }
        }

        @Test
        func `Write and read metadata`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let metadata = TranscriptMetadata(
                    conversationID: testConversationID,
                    accountJID: "user@example.com",
                    contactJID: "alice@example.com",
                    type: "chat",
                    displayName: "Alice"
                )
                try await store.writeMetadata(metadata, for: testConversationID)

                let metaURL = dir.appendingPathComponent(testConversationID.uuidString).appendingPathComponent("meta.json")
                #expect(FileManager.default.fileExists(atPath: metaURL.path))

                let data = try Data(contentsOf: metaURL)
                let decoded = try JSONDecoder().decode(TranscriptMetadata.self, from: data)
                #expect(decoded.conversationID == testConversationID)
                #expect(decoded.accountJID == "user@example.com")
                #expect(decoded.contactJID == "alice@example.com")
                #expect(decoded.type == "chat")
                #expect(decoded.displayName == "Alice")
                #expect(decoded.occupantNickname == nil)
            }
        }

        @Test
        func `Delete clears uuidIndex so post-delete amendments cannot route`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let msg = makeMessage(stanzaID: "indexed-sid", body: "to be deleted")
                try await store.appendMessage(msg)
                try await store.deleteTranscripts(for: testConversationID)

                // Try to route an amendment by the now-deleted message's UUID.
                // resolveAmendmentDate must not return a stale uuidIndex hit —
                // otherwise the amendment would recreate JSONL after deletion,
                // weakening the deletion boundary.
                try await store.appendAmendment(TranscriptAmendment(
                    action: .edit, targetMessageID: msg.id, timestamp: Date(), body: "ghost"
                ), conversationID: testConversationID)

                let fetched = try await store.fetchMessages(for: testConversationID, before: nil, limit: 50)
                #expect(fetched.isEmpty)
            }
        }
    }

    struct Stats {
        @Test
        func `Message date counts returns per-day counts sorted newest first`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .gmt
                let day1 = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
                let day2a = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 9)))
                let day2b = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 15)))
                let day3 = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 15, hour: 8)))

                try await store.appendMessages([
                    makeMessage(body: "a", timestamp: day1),
                    makeMessage(body: "b", timestamp: day2a),
                    makeMessage(body: "c", timestamp: day2b),
                    makeMessage(body: "d", timestamp: day3)
                ])

                let dateCounts = try await store.messageDateCounts(for: testConversationID)
                #expect(dateCounts.count == 3)
                // Newest first
                #expect(dateCounts[0].date == calendar.date(from: DateComponents(year: 2026, month: 3, day: 15))!)
                #expect(dateCounts[0].count == 1)
                #expect(dateCounts[1].date == calendar.date(from: DateComponents(year: 2026, month: 3, day: 12))!)
                #expect(dateCounts[1].count == 2)
                #expect(dateCounts[2].date == calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!)
                #expect(dateCounts[2].count == 1)
            }
        }

        @Test
        func `Message date counts returns empty for nonexistent conversation`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                let dateCounts = try await store.messageDateCounts(for: UUID())
                #expect(dateCounts.isEmpty)
            }
        }
    }

    struct DateFetch {
        @Test
        func `Fetch messages on date returns all messages for that day`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .gmt
                let day1Morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9)))
                let day1Evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 21)))
                let day2Morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 11, hour: 10)))

                try await store.appendMessages([
                    makeMessage(body: "morning", timestamp: day1Morning),
                    makeMessage(body: "evening", timestamp: day1Evening),
                    makeMessage(body: "next day", timestamp: day2Morning)
                ])

                let day1Start = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10)))
                let fetched = try await store.fetchMessages(for: testConversationID, on: day1Start)
                #expect(fetched.count == 2)
                // Chronological order
                #expect(fetched[0].body == "morning")
                #expect(fetched[1].body == "evening")
            }
        }

        @Test
        func `Fetch messages on date with no messages returns empty`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .gmt
                let msg = try makeMessage(body: "hello", timestamp: #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))))
                try await store.appendMessage(msg)

                let otherDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 11)))
                let fetched = try await store.fetchMessages(for: testConversationID, on: otherDay)
                #expect(fetched.isEmpty)
            }
        }
    }
}

// MARK: - TranscriptRecord Round-Trip Tests

enum TranscriptRecordTests {
    struct RoundTrip {
        @Test
        func `Message record round trips through JSON`() throws {
            let msg = makeMessage(stanzaID: "rt1", body: "round trip test")
            let record = TranscriptRecord.from(msg)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(TranscriptRecord.self, from: data)

            let restored = decoded.toChatMessage(conversationID: testConversationID)
            #expect(restored != nil)
            #expect(restored?.body == "round trip test")
            #expect(restored?.stanzaID == "rt1")
        }

        @Test
        func `An undecryptable message round trips with its flag and no body`() throws {
            var msg = makeMessage(body: "")
            msg.isEncrypted = true
            msg.isUndecryptable = true

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(TranscriptRecord.from(msg))

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let restored = try #require(decoder.decode(TranscriptRecord.self, from: data).toChatMessage(conversationID: testConversationID))
            #expect(restored.isUndecryptable)
            #expect(restored.body.isEmpty)
        }

        @Test
        func `An encrypted message that only says the old stand-in sentence stays a message`() throws {
            var msg = makeMessage(body: "Could not decrypt this message")
            msg.isEncrypted = true

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(TranscriptRecord.from(msg))

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let restored = try #require(decoder.decode(TranscriptRecord.self, from: data).toChatMessage(conversationID: testConversationID))
            #expect(!restored.isUndecryptable)
            #expect(restored.body == "Could not decrypt this message")
        }

        /// Records written before the flag existed carry no `isUndecryptable` key, and a failed decrypt among them is an
        /// encrypted message whose body is the sentence that used to stand in for it.
        @Test(arguments: [
            ("Could not decrypt this message", true, true),
            ("Could not decrypt this message", false, false),
            ("hello", true, false)
        ])
        func `A record without the flag reads as undecryptable only when it is the old stand-in`(
            body: String, isEncrypted: Bool, expected: Bool
        ) throws {
            let json = """
            {"type":"msg","id":"\(UUID().uuidString)","fromJID":"alice@example.com","body":"\(body)",\
            "timestamp":"2026-01-01T00:00:00Z","isOutgoing":false,"isEncrypted":\(isEncrypted),\
            "messageType":"chat","attachments":[]}
            """

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(TranscriptRecord.self, from: Data(json.utf8))
            let restored = try #require(record.toChatMessage(conversationID: testConversationID))

            #expect(restored.isUndecryptable == expected)
            #expect(restored.body == (expected ? "" : body))
        }

        @Test
        func `Amendment record round trips through JSON`() throws {
            let amendment = TranscriptAmendment(action: .edit, targetStanzaID: "s1", timestamp: Date(), body: "edited")
            let record = TranscriptRecord.from(amendment)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(TranscriptRecord.self, from: data)

            let restored = decoded.toAmendment()
            #expect(restored != nil)
            #expect(restored?.action == .edit)
            #expect(restored?.body == "edited")
        }
    }

    struct FindMessages {
        @Test
        func `findMessages returns all colliding-stanzaID rows across date files`() async throws {
            try await withTemporaryDirectory { dir in
                let store = FileTranscriptStore(baseDirectory: dir)
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .gmt
                let olderDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 2, day: 27, hour: 12)))
                let newerDay = try #require(calendar.date(from: DateComponents(year: 2026, month: 2, day: 28, hour: 12)))

                // Two rows with the same `ducko-N` stanzaID in different date files: an older reconciled row
                // (serverID set) and a newer un-reconciled optimistic row (serverID nil).
                try await store.appendMessage(makeMessage(
                    stanzaID: "ducko-7", serverID: "older-server-id", body: "older",
                    timestamp: olderDay, isOutgoing: true
                ))
                try await store.appendMessage(makeMessage(
                    stanzaID: "ducko-7", serverID: nil, body: "optimistic",
                    timestamp: newerDay, isOutgoing: true
                ))

                let matches = try await store.findMessages(stanzaID: "ducko-7", conversationID: testConversationID)

                // A single-file / stanza-index fast path would surface only the last-written file's row;
                // the full multi-file scan returns both, so the optimistic row is always reachable.
                #expect(matches.count == 2)
                #expect(matches.contains { $0.serverID == nil && $0.body == "optimistic" })
                #expect(matches.contains { $0.serverID == "older-server-id" && $0.body == "older" })
            }
        }
    }
}
