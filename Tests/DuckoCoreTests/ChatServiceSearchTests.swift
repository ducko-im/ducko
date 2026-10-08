import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore

private let dayLength: TimeInterval = 24 * 60 * 60
/// The start of a UTC day.
private let firstDay = Date(timeIntervalSince1970: 1_700_006_400)

private func day(_ index: Int) -> Date {
    firstDay.addingTimeInterval(Double(index) * dayLength)
}

private func makeMessage(in conversationID: UUID, body: String, day index: Int, second: TimeInterval = 0) -> ChatMessage {
    ChatMessage(
        id: UUID(),
        conversationID: conversationID,
        fromJID: "contact@example.com",
        body: body,
        timestamp: day(index).addingTimeInterval(second),
        isOutgoing: false,
        isDelivered: false,
        isEdited: false,
        type: "chat"
    )
}

@MainActor
private struct Fixture {
    let transcripts = MockTranscriptStore()
    let service: ChatService
    let first = UUID()
    let second = UUID()

    init() {
        self.service = ChatService(store: MockPersistenceStore(), transcripts: transcripts, filterPipeline: MessageFilterPipeline())
    }

    @discardableResult
    func add(_ body: String, to conversationID: UUID, day index: Int, second: TimeInterval = 0) async -> ChatMessage {
        let message = makeMessage(in: conversationID, body: body, day: index, second: second)
        await transcripts.addMessage(message)
        return message
    }
}

enum ChatServiceSearchTests {
    @MainActor
    struct TranscriptDays {
        @Test
        func `days of several conversations come newest first, equal dates in the order the conversations were given`() async throws {
            let fixture = Fixture()
            await fixture.add("a", to: fixture.first, day: 0)
            await fixture.add("b", to: fixture.first, day: 2)
            await fixture.add("c", to: fixture.second, day: 1)
            await fixture.add("d", to: fixture.second, day: 2)

            let days = try await fixture.service.transcriptDays(for: [fixture.second, fixture.first])

            #expect(days == [
                TranscriptDay(conversationID: fixture.second, date: day(2)),
                TranscriptDay(conversationID: fixture.first, date: day(2)),
                TranscriptDay(conversationID: fixture.second, date: day(1)),
                TranscriptDay(conversationID: fixture.first, date: day(0))
            ])
        }
    }

    @MainActor
    struct SearchTranscriptMessages {
        /// The conversation given first holds the older match, so results ordered by conversation would put it first.
        @Test
        func `the newer day comes first whichever conversation holds it`() async throws {
            let fixture = Fixture()
            let older = await fixture.add("needle older", to: fixture.first, day: 0)
            let newer = await fixture.add("needle newer", to: fixture.second, day: 3)
            await fixture.add("hay", to: fixture.second, day: 4)

            let found = try await fixture.service.searchTranscriptMessages(query: "needle", in: [fixture.first, fixture.second], limit: 10)

            #expect(found.map(\.day) == [
                TranscriptDay(conversationID: fixture.second, date: day(3)),
                TranscriptDay(conversationID: fixture.first, date: day(0))
            ])
            #expect(found.map { $0.messages.map(\.id) } == [[newer.id], [older.id]])
        }

        @Test
        func `with more matches in a day than the limit, the newest are returned, oldest first`() async throws {
            let fixture = Fixture()
            var matches: [ChatMessage] = []
            for second in 0 ..< 5 {
                await matches.append(fixture.add("needle \(second)", to: fixture.first, day: 0, second: TimeInterval(second)))
            }

            let found = try await fixture.service.searchTranscriptMessages(query: "needle", in: [fixture.first], limit: 3)

            #expect(found.map { $0.messages.map(\.id) } == [matches[2...].map(\.id)])
        }

        /// A search goes through every stored day, so a match is found however many newer messages there are.
        @Test
        func `a match older than the conversation's newest 500 messages is found`() async throws {
            let fixture = Fixture()
            let old = await fixture.add("needle", to: fixture.first, day: 0)
            for second in 0 ..< 501 {
                await fixture.add("hay", to: fixture.first, day: 1, second: TimeInterval(second))
            }

            let found = try await fixture.service.searchTranscriptMessages(query: "needle", in: [fixture.first], limit: 10)

            #expect(found.map { $0.messages.map(\.id) } == [[old.id]])
        }

        @Test
        func `the limit counts across days, and no day older than the last one needed is read`() async throws {
            let fixture = Fixture()
            let outside = UUID()
            await fixture.add("needle", to: outside, day: 3)
            await fixture.add("needle", to: fixture.first, day: 0)
            let middle = await fixture.add("needle", to: fixture.first, day: 1)
            let newest = await fixture.add("needle", to: fixture.first, day: 2)

            let found = try await fixture.service.searchTranscriptMessages(query: "needle", in: [fixture.first], limit: 2)

            #expect(found.map { $0.messages.map(\.id) } == [[newest.id], [middle.id]])
            #expect(await fixture.transcripts.matchedDays == [
                TranscriptDay(conversationID: fixture.first, date: day(2)),
                TranscriptDay(conversationID: fixture.first, date: day(1))
            ])
        }

        @Test(arguments: [false, true])
        func `with two conversations matching on one date, the later message wins whichever is listed first`(laterListedFirst: Bool) async throws {
            let fixture = Fixture()
            await fixture.add("needle", to: fixture.first, day: 0, second: 10)
            let later = await fixture.add("needle", to: fixture.second, day: 0, second: 20)
            let conversations = laterListedFirst ? [fixture.second, fixture.first] : [fixture.first, fixture.second]

            let found = try await fixture.service.searchTranscriptMessages(query: "needle", in: conversations, limit: 1)

            #expect(found.map { $0.messages.map(\.id) } == [[later.id]])
        }

        /// Ranking a match by the newest message of its day would keep both of the first conversation's.
        @Test
        func `a limit that cuts through a date keeps the newest messages across its conversations`() async throws {
            let fixture = Fixture()
            await fixture.add("needle early", to: fixture.first, day: 0, second: 10)
            let late = await fixture.add("needle late", to: fixture.first, day: 0, second: 30)
            let between = await fixture.add("needle between", to: fixture.second, day: 0, second: 20)

            let found = try await fixture.service.searchTranscriptMessages(query: "needle", in: [fixture.first, fixture.second], limit: 2)

            #expect(found.map { $0.messages.map(\.id) } == [[late.id], [between.id]])
        }

        @Test
        func `of messages with one timestamp, the one a day shows later is the newer`() async throws {
            let fixture = Fixture()
            await fixture.add("needle one", to: fixture.first, day: 0, second: 10)
            await fixture.add("needle two", to: fixture.first, day: 0, second: 10)
            let shown = try await fixture.transcripts.fetchMessages(for: fixture.first, on: day(0))
            try #require(shown.count == 2)

            let found = try await fixture.service.searchTranscriptMessages(query: "needle", in: [fixture.first], limit: 1)

            #expect(found.map { $0.messages.map(\.id) } == [[shown[1].id]])
        }
    }

    struct MatchesSearch {
        private let message = makeMessage(in: UUID(), body: "Meet at the Café", day: 0)

        @Test(arguments: ["café", "CAFE", "at the"])
        func `text is matched ignoring case and diacritics`(query: String) {
            #expect(message.matchesSearch(query))
        }

        @Test
        func `other text is not matched`() {
            #expect(!message.matchesSearch("tea"))
        }

        /// A received file is stored with an empty body, so its name is the only text there is to match.
        @Test
        func `a file is matched by its name`() {
            var file = makeMessage(in: UUID(), body: "", day: 0)
            file.attachments = [Attachment(id: UUID(), url: "file:///tmp/quarterly-report.pdf", fileName: "quarterly-report.pdf")]

            #expect(file.matchesSearch("quarterly"))
        }

        /// `SearchableText` leaves out a letter under more marks than a character is searched with, which keeps such a
        /// text from holding a search up. That the letter is not found tells that both are searched through it.
        @Test(arguments: [false, true])
        func `the text and a file's name are searched without a character of too many code points`(inFileName: Bool) {
            let marked = "report x" + String(repeating: "\u{301}", count: SearchableText.characterLimit) + " final"
            var message = makeMessage(in: UUID(), body: inFileName ? "" : marked, day: 0)
            if inFileName {
                message.attachments = [Attachment(id: UUID(), url: "file:///tmp/report.pdf", fileName: marked)]
            }

            #expect(message.matchesSearch("final"))
            #expect(!message.matchesSearch("x"))
        }

        @Test
        func `a retracted message is never matched`() {
            var retracted = message
            retracted.isRetracted = true

            #expect(!retracted.matchesSearch("café"))
        }
    }
}
