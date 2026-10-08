import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Observation
import Synchronization
import Testing
@testable import DuckoUI

/// The chat's loaded window through refreshes, older pages, and scrolling, over the real `ChatService` and in-memory
/// stores. A stand-in list reports positions and rest where a test needs the reader to be somewhere.
@MainActor
struct ChatWindowHistoryTests {
    private static let start = Date(timeIntervalSince1970: 1_772_400_000)
    private static let reading = TranscriptPosition.reading(id: UUID(), offset: 40)

    private static func message(_ fixture: ChatWindowFixture, at offset: TimeInterval, body: String = "text") -> ChatMessage {
        ChatMessage(
            id: UUID(), conversationID: fixture.conversationID, stanzaID: UUID().uuidString, fromJID: ChatWindowFixture.jidString, body: body,
            timestamp: start.addingTimeInterval(offset), isOutgoing: false, isDelivered: true, isEdited: false, type: "chat"
        )
    }

    /// Stores `count` messages a second apart, oldest first, the first at `offset` seconds.
    @discardableResult
    private static func store(_ count: Int, in fixture: ChatWindowFixture, from offset: TimeInterval = 0) async throws -> [ChatMessage] {
        let messages = (0 ..< count).map { message(fixture, at: offset + TimeInterval($0)) }
        try await fixture.transcripts.appendMessages(messages)
        return messages
    }

    /// A loaded fixture over `count` stored messages.
    private static func loaded(_ count: Int, linkPreviewFetcher: any LinkPreviewFetcher = NoOpLinkPreviewFetcher()) async throws -> (ChatWindowFixture, [ChatMessage]) {
        let fixture = try await ChatWindowFixture.make(linkPreviewFetcher: linkPreviewFetcher, loads: false)
        let messages = try await store(count, in: fixture)
        await fixture.windowState.load()
        return (fixture, messages)
    }

    /// A list attached to the tab's scroller, with the reader scrolled up.
    private static func scrolledUpList(_ fixture: ChatWindowFixture) -> StandInTranscriptList {
        let list = StandInTranscriptList(attachedTo: fixture.windowState.scroller)
        list.arrive(at: reading)
        return list
    }

    // MARK: - Loading and refreshing

    @Test func `load brings in the initial count and no more`() async throws {
        let (fixture, messages) = try await Self.loaded(120)

        #expect(fixture.windowState.messages.map(\.id) == messages.suffix(MessageWindow.initialCount).map(\.id))
        #expect(!fixture.windowState.isLoadingOlder)
    }

    @Test func `a refresh keeps an older page and its notes`() async throws {
        let (fixture, messages) = try await Self.loaded(120)
        let note = TimelineNote(conversationID: fixture.conversationID, timestamp: messages[40].timestamp, kind: .encryptionEnabledByContact)
        try await fixture.transcripts.appendNote(note)
        await fixture.windowState.loadOlderMessages()
        try #require(fixture.windowState.messages.count == 2 * MessageWindow.pageSize)
        try #require(fixture.windowState.notes == [note])

        await fixture.windowState.refreshMessages()

        #expect(fixture.windowState.messages.map(\.id) == messages.suffix(100).map(\.id))
        #expect(fixture.windowState.notes == [note])
    }

    @Test func `a page waiting for rest and a message arriving meanwhile both end up in the window`() async throws {
        let (fixture, messages) = try await Self.loaded(120)
        let list = Self.scrolledUpList(fixture)
        list.isAtRest = false

        await fixture.windowState.loadOlderMessages()
        #expect(fixture.windowState.messages.count == MessageWindow.initialCount)
        #expect(fixture.windowState.isLoadingOlder)
        let arrival = Self.message(fixture, at: 500)
        await fixture.transcripts.addMessage(arrival)
        await fixture.windowState.refreshMessages()
        #expect(fixture.windowState.messages.last?.id == arrival.id)
        list.comeToRest()

        #expect(fixture.windowState.messages.map(\.id) == messages.suffix(100).map(\.id) + [arrival.id])
        #expect(!fixture.windowState.isLoadingOlder)
    }

    @Test func `a refresh that read its messages before an older page went in keeps that page`() async throws {
        let (fixture, messages) = try await Self.loaded(220)
        _ = Self.scrolledUpList(fixture)
        let note = TimelineNote(conversationID: fixture.conversationID, timestamp: messages[80].timestamp, kind: .encryptionEnabledByContact)
        try await fixture.transcripts.appendNote(note)
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        await fixture.transcripts.installFetchNotesGate(entered: entered, release: release)
        let refresh = Task { await fixture.windowState.refreshMessages() }
        await entered.wait()

        await fixture.windowState.loadOlderMessages()
        await fixture.windowState.loadOlderMessages()
        try #require(fixture.windowState.messages.count == 150)
        await release.signal()
        await refresh.value

        #expect(fixture.windowState.messages.map(\.id) == messages.suffix(150).map(\.id))
        #expect(fixture.windowState.notes == [note])
    }

    @Test func `a message stored while the chat loads is in the window when the load returns`() async throws {
        let fixture = try await ChatWindowFixture.make(loads: false)
        try await Self.store(10, in: fixture)
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        await fixture.transcripts.installFetchNotesGate(entered: entered, release: release)
        let load = Task { await fixture.windowState.load() }
        await entered.wait()

        let arrival = Self.message(fixture, at: 500)
        await fixture.transcripts.addMessage(arrival)
        await fixture.windowState.refreshMessages()
        // Nothing pages before the first load has finished.
        await fixture.windowState.loadOlderMessages()
        #expect(fixture.windowState.messages.isEmpty)
        await release.signal()
        await load.value

        #expect(fixture.windowState.messages.count == 11)
        #expect(fixture.windowState.messages.last?.id == arrival.id)
    }

    @Test func `a note older than the window is not published by a refresh that reads back past it`() async throws {
        let (fixture, messages) = try await Self.loaded(120)
        try await fixture.transcripts.appendNote(
            TimelineNote(conversationID: fixture.conversationID, timestamp: messages[30].timestamp, kind: .encryptionEnabledByContact)
        )

        // This refresh reads the newest 100 again, 50 more than are loaded.
        await fixture.windowState.refreshMessages()

        #expect(fixture.windowState.messages.count == MessageWindow.initialCount)
        #expect(fixture.windowState.notes.isEmpty)
    }

    @Test func `the timeline is never seen with the messages of one fetch and the notes of another`() async throws {
        let (fixture, _) = try await Self.loaded(5)
        let arrival = Self.message(fixture, at: 500)
        await fixture.transcripts.addMessage(arrival)
        let note = TimelineNote(conversationID: fixture.conversationID, timestamp: arrival.timestamp, kind: .encryptionEnabledByContact)
        try await fixture.transcripts.appendNote(note)

        // The first change to the timeline schedules a look at it, which runs once the step that made the change is over.
        let seen = Mutex<Task<[UUID], Never>?>(nil)
        withObservationTracking {
            _ = fixture.windowState.timelineItems
        } onChange: {
            seen.withLock { $0 = Task { @MainActor in fixture.windowState.timelineItems.map(\.id) } }
        }
        await fixture.windowState.refreshMessages()

        let ids = try #require(await seen.withLock { $0 }?.value)
        #expect(ids.contains(arrival.id))
        #expect(ids.contains(note.id))
    }

    // MARK: - The window while scrolled up and back at the newest message

    @Test func `scrolled up, arrivals are added without dropping what is loaded`() async throws {
        let (fixture, messages) = try await Self.loaded(700)
        _ = Self.scrolledUpList(fixture)
        await fixture.windowState.loadOlderMessages()
        try #require(fixture.windowState.messages.count == 100)

        // More arrive than the window grew by since its last refresh.
        let arrivals = try await Self.store(51, in: fixture, from: 1000)
        await fixture.windowState.refreshMessages()
        #expect(fixture.windowState.messages.map(\.id) == messages.suffix(100).map(\.id) + arrivals.map(\.id))

        while fixture.windowState.messages.count < 600 {
            await fixture.windowState.loadOlderMessages()
        }
        let loaded = fixture.windowState.messages.map(\.id)
        let late = Self.message(fixture, at: 2000)
        await fixture.transcripts.addMessage(late)
        await fixture.windowState.refreshMessages()

        #expect(fixture.windowState.messages.map(\.id) == loaded + [late.id])
    }

    @Test func `back at the newest message a refresh cuts the window to its resting count`() async throws {
        let (fixture, messages) = try await Self.loaded(300)
        let list = Self.scrolledUpList(fixture)
        while fixture.windowState.messages.count < 300 {
            await fixture.windowState.loadOlderMessages()
        }
        fixture.windowState.hasReachedEnd = true

        list.arrive(at: .newest)
        await fixture.windowState.refreshMessages()

        #expect(fixture.windowState.messages.map(\.id) == messages.suffix(MessageWindow.restingCount).map(\.id))
        #expect(!fixture.windowState.hasReachedEnd)
    }

    @Test func `more arrivals than a refresh reads again start the window over at the newest messages`() async throws {
        let (fixture, _) = try await Self.loaded(120)
        let list = Self.scrolledUpList(fixture)

        let arrivals = try await Self.store(MessageWindow.refreshDepth + 10, in: fixture, from: 1000)
        await fixture.windowState.refreshMessages()

        #expect(fixture.windowState.messages.map(\.id) == arrivals.suffix(MessageWindow.initialCount).map(\.id))
        #expect(list.takenRequests == [.newest])
    }

    @Test func `a page waiting for rest is dropped when the window was replaced meanwhile`() async throws {
        let (fixture, _) = try await Self.loaded(120)
        let list = Self.scrolledUpList(fixture)
        list.isAtRest = false
        await fixture.windowState.loadOlderMessages()
        try #require(fixture.windowState.isLoadingOlder)

        let arrivals = try await Self.store(MessageWindow.refreshDepth + 10, in: fixture, from: 1000)
        await fixture.windowState.refreshMessages()
        list.comeToRest()

        #expect(fixture.windowState.messages.map(\.id) == arrivals.suffix(MessageWindow.initialCount).map(\.id))
        #expect(!fixture.windowState.isLoadingOlder)
    }

    // MARK: - Older pages

    @Test func `a run of messages in one second longer than a fetch is paged through without asking the server`() async throws {
        let fixture = try await ChatWindowFixture.make(loads: false)
        let older = Self.message(fixture, at: -10, body: "older")
        await fixture.transcripts.addMessage(older)
        let run = (0 ..< 2 * MessageWindow.pageSize + 5).map { _ in Self.message(fixture, at: 0) }
        try await fixture.transcripts.appendMessages(run)
        await fixture.windowState.load()
        _ = Self.scrolledUpList(fixture)

        await fixture.windowState.loadOlderMessages()
        try #require(fixture.windowState.messages.map(\.id) == run.suffix(100).map(\.id))
        // The fetch for this page comes back full of the run and holds nothing older than what is loaded.
        await fixture.windowState.loadOlderMessages()

        #expect(fixture.windowState.messages.map(\.id) == [older.id] + run.map(\.id))
        #expect(fixture.windowState.lastLoadHistoryError == nil)
    }

    @Test func `a load that fails ends loading and says why`() async throws {
        let (fixture, _) = try await Self.loaded(5)

        // The store has nothing older, and the account is not connected.
        await fixture.windowState.loadOlderMessages()

        #expect(!fixture.windowState.isLoadingOlder)
        #expect(fixture.windowState.lastLoadHistoryError != nil)
        #expect(!fixture.windowState.hasReachedEnd)
        #expect(fixture.windowState.messages.count == 5)
    }

    // MARK: - Sending and searching

    @Test func `sending a message or a file asks for the newest message, and sending a correction does not`() async throws {
        let (fixture, messages) = try await Self.loaded(5)
        let list = Self.scrolledUpList(fixture)

        fixture.windowState.startEdit(of: messages[2])
        await fixture.windowState.sendMessage("corrected")
        #expect(list.takenRequests.isEmpty)

        await fixture.windowState.sendMessage("new")
        #expect(list.takenRequests == [.newest])

        fixture.windowState.addAttachment(url: URL(fileURLWithPath: "/nonexistent/notes.txt"))
        await fixture.windowState.sendAttachments()
        #expect(list.takenRequests == [.newest, .newest])
    }

    @Test func `stepping through search results reveals each in turn`() async throws {
        let fixture = try await ChatWindowFixture.make(loads: false)
        let matches = [Self.message(fixture, at: 0, body: "needle one"), Self.message(fixture, at: 1, body: "hay"), Self.message(fixture, at: 2, body: "needle two")]
        try await fixture.transcripts.appendMessages(matches)
        await fixture.windowState.load()
        let list = StandInTranscriptList(attachedTo: fixture.windowState.scroller)

        fixture.windowState.isSearching = true
        fixture.windowState.searchText = "needle"
        fixture.windowState.performSearch()
        fixture.windowState.nextSearchResult()
        fixture.windowState.previousSearchResult()

        #expect(list.takenRequests == [.reveal(matches[2].id), .reveal(matches[0].id), .reveal(matches[2].id)])
    }

    @Test func `search results follow the window when a refresh cuts or replaces it`() async throws {
        let fixture = try await ChatWindowFixture.make(loads: false)
        let early = Self.message(fixture, at: 0, body: "needle early")
        await fixture.transcripts.addMessage(early)
        try await Self.store(147, in: fixture, from: 1)
        let middle = Self.message(fixture, at: 180, body: "needle middle")
        let late = Self.message(fixture, at: 200, body: "needle late")
        try await fixture.transcripts.appendMessages([middle, late])
        await fixture.windowState.load()
        let list = Self.scrolledUpList(fixture)
        while fixture.windowState.messages.count < 150 {
            await fixture.windowState.loadOlderMessages()
        }
        fixture.windowState.isSearching = true
        fixture.windowState.searchText = "needle"
        fixture.windowState.performSearch()
        fixture.windowState.previousSearchResult()
        try #require(fixture.windowState.searchResults == [early.id, middle.id, late.id])
        try #require(list.takenRequests == [.reveal(late.id), .reveal(middle.id)])

        // Back at the newest message, the window is cut and loses the early match. The middle one stays selected,
        // which moves it from second to first.
        list.arrive(at: .newest)
        await fixture.windowState.refreshMessages()
        #expect(fixture.windowState.searchResults == [middle.id, late.id])
        #expect(fixture.windowState.currentSearchIndex == 0)

        // Scrolled up again, the window is replaced by newer messages, of which one matches.
        list.arrive(at: Self.reading)
        try await Self.store(MessageWindow.refreshDepth + 10, in: fixture, from: 1000)
        let newest = Self.message(fixture, at: 5000, body: "needle newest")
        await fixture.transcripts.addMessage(newest)
        await fixture.windowState.refreshMessages()

        #expect(fixture.windowState.searchResults == [newest.id])
        #expect(fixture.windowState.currentSearchIndex == 0)
        // Only the no-overlap case asked the list for anything, and that was the newest message, not a match.
        #expect(list.takenRequests == [.reveal(late.id), .reveal(middle.id), .newest])
    }

    /// A received file's message has no text, so its name is the only thing a find can match it by.
    @Test func `the find matches a file by its name`() async throws {
        let fixture = try await ChatWindowFixture.make(loads: false)
        var file = Self.message(fixture, at: 0, body: "")
        file.attachments = [Attachment(id: UUID(), url: "file:///tmp/quarterly-report.pdf", fileName: "quarterly-report.pdf")]
        try await fixture.transcripts.appendMessages([file, Self.message(fixture, at: 1, body: "hay")])
        await fixture.windowState.load()

        fixture.windowState.isSearching = true
        fixture.windowState.searchText = "quarterly"
        fixture.windowState.performSearch()

        #expect(fixture.windowState.searchResults == [file.id])
    }

    @Test func `results stay on the text searched for while the field holds another`() async throws {
        let fixture = try await ChatWindowFixture.make(loads: false)
        let needle = Self.message(fixture, at: 0, body: "needle")
        try await fixture.transcripts.appendMessages([needle])
        await fixture.windowState.load()
        fixture.windowState.isSearching = true
        fixture.windowState.searchText = "needle"
        fixture.windowState.performSearch()

        // Typed and not submitted, then a message arrives that only the typed text matches.
        fixture.windowState.searchText = "thread"
        await fixture.transcripts.addMessage(Self.message(fixture, at: 1, body: "thread"))
        await fixture.windowState.refreshMessages()

        #expect(fixture.windowState.searchResults == [needle.id])
        #expect(fixture.windowState.searchResultsQuery == "needle")
    }

    @Test func `a result goes when its message is retracted, also while the field is empty`() async throws {
        let fixture = try await ChatWindowFixture.make(loads: false)
        let needle = Self.message(fixture, at: 0, body: "needle")
        try await fixture.transcripts.appendMessages([needle])
        await fixture.windowState.load()
        fixture.windowState.isSearching = true
        fixture.windowState.searchText = "needle"
        fixture.windowState.performSearch()
        try #require(fixture.windowState.searchResults == [needle.id])

        fixture.windowState.searchText = ""
        try await fixture.transcripts.appendAmendment(
            TranscriptAmendment(action: .retract, targetMessageID: needle.id), conversationID: fixture.conversationID
        )
        await fixture.windowState.refreshMessages()

        #expect(fixture.windowState.searchResults.isEmpty)
    }

    @Test func `after the find is dismissed, a message that matches what was searched for is no result`() async throws {
        let fixture = try await ChatWindowFixture.make(loads: false)
        try await fixture.transcripts.appendMessages([Self.message(fixture, at: 0, body: "needle")])
        await fixture.windowState.load()
        fixture.windowState.toggleSearch()
        fixture.windowState.searchText = "needle"
        fixture.windowState.performSearch()
        try #require(fixture.windowState.searchResults.count == 1)

        fixture.windowState.toggleSearch()
        await fixture.transcripts.addMessage(Self.message(fixture, at: 1, body: "another needle"))
        await fixture.windowState.refreshMessages()

        #expect(!fixture.windowState.isSearching)
        #expect(fixture.windowState.searchResults.isEmpty)
        #expect(fixture.windowState.searchResultsQuery.isEmpty)
    }

    // MARK: - Link previews

    @Test func `a stored preview is there when its message is published, without a fetch`() async throws {
        let fetcher = CountingLinkPreviewFetcher()
        let fixture = try await ChatWindowFixture.make(linkPreviewFetcher: fetcher, loads: false)
        var messages = try await Self.store(118, in: fixture)
        let inOlderPage = Self.message(fixture, at: 30.5, body: "https://example.com/older")
        let newest = Self.message(fixture, at: 500, body: "https://example.com/newest")
        try await fixture.transcripts.appendMessages([inOlderPage, newest])
        messages += [inOlderPage, newest]
        for message in [inOlderPage, newest] {
            try await fixture.store.upsertLinkPreview(LinkPreview(url: message.body, title: "Stored", fetchedAt: Date()))
        }

        // Looked at once the step that first publishes the messages is over, before the prefetch that step starts
        // could have brought the preview in.
        let atPublish = Mutex<Task<LinkPreview?, Never>?>(nil)
        withObservationTracking {
            _ = fixture.windowState.messages
        } onChange: {
            atPublish.withLock { $0 = Task { @MainActor in fixture.windowState.linkPreview(for: newest) } }
        }
        await fixture.windowState.load()
        #expect(try #require(await atPublish.withLock { $0 }?.value)?.title == "Stored")
        #expect(fixture.windowState.linkPreview(for: inOlderPage) == nil)

        await fixture.windowState.loadOlderMessages()
        #expect(fixture.windowState.messages.contains { $0.id == inOlderPage.id })
        #expect(fixture.windowState.linkPreview(for: inOlderPage)?.title == "Stored")
        #expect(await fetcher.invocationCount == 0)
    }

    @Test func `a message corrected to another text no longer shows the preview of the link it had`() async throws {
        let fixture = try await ChatWindowFixture.make(loads: false)
        let linked = Self.message(fixture, at: 0, body: "https://example.com/first")
        await fixture.transcripts.addMessage(linked)
        try await fixture.store.upsertLinkPreview(LinkPreview(url: linked.body, title: "Stored", fetchedAt: Date()))
        await fixture.windowState.load()
        try #require(fixture.windowState.linkPreview(for: linked)?.title == "Stored")

        var corrected = linked
        corrected.body = "No link in here any more"

        #expect(fixture.windowState.linkPreview(for: corrected) == nil)
    }

    @Test func `a preview fetched while the reader is scrolled up shows once it arrives`() async throws {
        let (fixture, _) = try await Self.loaded(5, linkPreviewFetcher: CountingLinkPreviewFetcher())
        _ = Self.scrolledUpList(fixture)
        let linked = Self.message(fixture, at: 500, body: "https://example.com/fresh")
        await fixture.transcripts.addMessage(linked)

        await fixture.windowState.refreshMessages()
        #expect(fixture.windowState.linkPreview(for: linked) == nil)

        try await waitUntil { fixture.windowState.linkPreview(for: linked) != nil }
        #expect(fixture.windowState.linkPreview(for: linked)?.title == "Counted Title")
    }
}

// MARK: - With the server archive

extension ChatWindowHistoryTests {
    private static func connected() async throws -> (ChatWindowFixture, MockServerSession) {
        let transport = MockTransport()
        let fixture = try await ChatWindowFixture.make(
            clientFactory: MockXMPPClientFactory(transport: transport, modules: [MAMModule()]), loads: false
        )
        let server = MockServerSession(transport: transport)
        try await server.connect(fixture.environment, accountID: fixture.accountID)
        return (fixture, server)
    }

    /// Answers the next archive query with `entries`, each a body and the ISO 8601 time it was archived at. The
    /// archive holds more before them when `first` names the page's first entry, and nothing more otherwise.
    private static func answerArchiveQuery(
        _ server: MockServerSession, with entries: [(body: String, stamp: String)], first: String? = nil
    ) async throws -> String {
        let query = try await server.next("urn:xmpp:mam:2")
        let queryID = try #require(extractQueryID(from: query))
        for (index, entry) in entries.enumerated() {
            await server.transport.simulateReceive(
                "<message from='alice@example.com'>"
                    + "<result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='arch-\(entry.body)-\(index)'>"
                    + "<forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='\(entry.stamp)'/>"
                    + "<message from='bob@example.com/phone' to='alice@example.com' type='chat' id='\(entry.body)'><body>\(entry.body)</body></message>"
                    + "</forwarded></result></message>"
            )
        }
        let fin = if let first {
            "<fin xmlns='urn:xmpp:mam:2'><set xmlns='http://jabber.org/protocol/rsm'><first>\(first)</first></set></fin>"
        } else {
            "<fin xmlns='urn:xmpp:mam:2' complete='true'/>"
        }
        await server.reply(to: query, contents: fin)
        return query
    }

    private static func stamp(_ offset: TimeInterval) -> String {
        start.addingTimeInterval(offset).formatted(.iso8601)
    }

    @Test func `history ends when the server adds nothing, and a page from the server is followed by a refresh`() async throws {
        let (fixture, server) = try await Self.connected()
        let only = Self.message(fixture, at: 0.25)
        await fixture.transcripts.addMessage(only)
        await fixture.windowState.load()
        let list = Self.scrolledUpList(fixture)
        list.isAtRest = false

        let paging = Task { await fixture.windowState.loadOlderMessages() }
        let query = try await Self.answerArchiveQuery(server, with: [("fromserver", Self.stamp(-60))])
        await paging.value
        // The server is asked for what is before the second after the oldest loaded message's.
        #expect(query.contains(Self.stamp(1)))
        #expect(fixture.windowState.isLoadingOlder)

        // The page is waiting for rest. What arrives meanwhile is published by the refresh the insert starts.
        let arrival = Self.message(fixture, at: 500)
        await fixture.transcripts.addMessage(arrival)
        list.comeToRest()
        #expect(fixture.windowState.messages.map(\.body).prefix(2) == ["fromserver", "text"])
        #expect(!fixture.windowState.hasReachedEnd)
        try await waitUntil { fixture.windowState.messages.last?.id == arrival.id }

        let ending = Task { await fixture.windowState.loadOlderMessages() }
        _ = try await Self.answerArchiveQuery(server, with: [])
        await ending.value

        #expect(fixture.windowState.hasReachedEnd)
        #expect(fixture.windowState.lastLoadHistoryError == nil)
        await fixture.environment.accountService.disconnect(accountID: fixture.accountID)
    }

    @Test func `server entries that share the oldest loaded message's second are followed by the page before them`() async throws {
        let (fixture, server) = try await Self.connected()
        let stored = try await Self.store(MessageWindow.refreshDepth + 50, in: fixture)
        await fixture.windowState.load()
        _ = Self.scrolledUpList(fixture)
        while fixture.windowState.messages.count < stored.count {
            await fixture.windowState.loadOlderMessages()
        }

        let paging = Task { await fixture.windowState.loadOlderMessages() }
        // The archive keeps fractions of a second, so these sort after the oldest loaded message, which was stored
        // on the second.
        let sameSecond = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Self.start.addingTimeInterval(0.5))
        // Asked the same question twice, the archive gives the same last page twice. What is before it is reached
        // through the page's first entry.
        _ = try await Self.answerArchiveQuery(server, with: [("samesecond", sameSecond)], first: "arch-samesecond-0")
        _ = try await Self.answerArchiveQuery(server, with: [("samesecond", sameSecond)], first: "arch-samesecond-0")
        let query = try await Self.answerArchiveQuery(server, with: [("before", Self.stamp(-60))])
        await paging.value

        #expect(query.contains("<before>arch-samesecond-0</before>"))
        #expect(fixture.windowState.messages.first?.body == "before")
        #expect(fixture.windowState.messages.count == stored.count + 1)
        await fixture.environment.accountService.disconnect(accountID: fixture.accountID)
    }

    @Test func `an archive that keeps adding entries which give no page ends paging`() async throws {
        let (fixture, server) = try await Self.connected()
        await fixture.transcripts.addMessage(Self.message(fixture, at: 0))
        await fixture.windowState.load()
        _ = Self.scrolledUpList(fixture)
        let sameSecond = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Self.start.addingTimeInterval(0.5))

        let paging = Task { await fixture.windowState.loadOlderMessages() }
        for round in 0 ..< MessageWindow.serverRounds {
            _ = try await Self.answerArchiveQuery(server, with: [("again\(round)", sameSecond)])
        }
        // Bounded: a load that asked once more would wait for an answer that never comes.
        try #require(try await boundedOutcome { await paging.value } != nil)

        #expect(fixture.windowState.hasReachedEnd)
        #expect(!fixture.windowState.isLoadingOlder)
        await fixture.environment.accountService.disconnect(accountID: fixture.accountID)
    }

    @Test func `a load that fails after the server added entries changes no rows`() async throws {
        let (fixture, server) = try await Self.connected()
        await fixture.transcripts.addMessage(Self.message(fixture, at: 0))
        await fixture.windowState.load()
        _ = Self.scrolledUpList(fixture)
        let sameSecond = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(Self.start.addingTimeInterval(0.5))

        let paging = Task { await fixture.windowState.loadOlderMessages() }
        _ = try await Self.answerArchiveQuery(server, with: [("samesecond", sameSecond)])
        // The entry gave no page, so the server is asked again, and that question is cut off.
        _ = try await server.next("urn:xmpp:mam:2")
        await fixture.environment.accountService.disconnect(accountID: fixture.accountID)
        try #require(try await boundedOutcome { await paging.value } != nil)

        // New rows would have the list ask for a page again. The entries show with the next refresh.
        #expect(fixture.windowState.lastLoadHistoryError != nil)
        #expect(fixture.windowState.messages.count == 1)
        await fixture.windowState.refreshMessages()
        #expect(fixture.windowState.messages.contains { $0.body == "samesecond" })
    }

    @Test func `a page that ended history is dropped without ending it when the window was replaced meanwhile`() async throws {
        let (fixture, server) = try await Self.connected()
        await fixture.transcripts.addMessage(Self.message(fixture, at: 0))
        await fixture.windowState.load()
        let list = Self.scrolledUpList(fixture)
        list.isAtRest = false
        let paging = Task { await fixture.windowState.loadOlderMessages() }
        _ = try await Self.answerArchiveQuery(server, with: [])
        await paging.value
        try #require(fixture.windowState.isLoadingOlder)

        try await Self.store(MessageWindow.refreshDepth + 10, in: fixture, from: 1000)
        await fixture.windowState.refreshMessages()
        list.comeToRest()

        #expect(!fixture.windowState.isLoadingOlder)
        #expect(!fixture.windowState.hasReachedEnd)
        await fixture.environment.accountService.disconnect(accountID: fixture.accountID)
    }
}
