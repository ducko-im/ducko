import DuckoCore
import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoUI

/// The search over all conversations and the find bar of the history window. The fixture's doc comment has the stored
/// history these tests search.
@MainActor
struct TranscriptViewerStateSearchTests {
    /// A fixture whose window is open on the first account, as a start from the File menu leaves it.
    private static func started(searchDelay: Duration = .zero) async throws -> TranscriptLibraryFixture {
        let library = try TranscriptLibraryFixture(searchDelay: searchDelay)
        await library.seed()
        await library.state.start(with: nil)
        return library
    }

    private static func alphaDays(_ library: TranscriptLibraryFixture) -> [TranscriptDay] {
        [library.day(3, of: library.alice), library.day(2, of: library.carol), library.day(1, of: library.alice), library.day(0, of: library.dave)]
    }

    // MARK: - Searching all conversations

    @Test
    func `a search over all conversations lists only the days with matches and opens the first at its match`() async throws {
        let library = try await Self.started()
        let list = StandInTranscriptList(attachedTo: library.state.scroller)
        let days = Self.alphaDays(library)

        library.state.setSearchText("alpha")
        try await library.settle()

        #expect(library.state.listedDays == days)
        #expect(library.state.matchCounts == [days[0]: 1, days[1]: 1, days[2]: 2, days[3]: 1])
        #expect(library.state.matchTotal == 5)
        #expect(library.state.selectedDay == days[0])
        #expect(try library.state.currentMatchID == library.id("alpha three"))
        #expect(library.state.currentMatchNumber == 1)
        #expect(try list.takenRequests == [.revealWhenShown(library.id("alpha three"))])
        #expect(!library.state.isScanning)
        #expect(library.state.isFindBarVisible)
        // The row on the left stays what a cleared search returns to, and shows unselected meanwhile.
        #expect(library.state.selection == .account(library.home.id))
        #expect(library.state.sidebarSelection == nil)
    }

    @Test
    func `while a day's read is held, the search is still scanning and lists the days found so far`() async throws {
        let library = try await Self.started()
        let gate = await library.gates.suspendNext(.matches(library.carol.id, library.day(2, of: library.carol).date))

        library.state.setSearchText("alpha")
        try await gate.waitForArrival()

        #expect(library.state.isScanning)
        #expect(library.state.listedDays == [library.day(3, of: library.alice)])

        await gate.open()
        try await library.settle()
        #expect(!library.state.isScanning)
        #expect(library.state.listedDays == Self.alphaDays(library))
    }

    @Test
    func `a toolbar text of spaces alone starts nothing`() async throws {
        let library = try await Self.started()
        let open = library.state.selectedDay

        library.state.setSearchText("   ")

        #expect(!library.state.searchesAllConversations)
        #expect(!library.state.isFindBarVisible)
        #expect(library.state.pendingSearch == nil)
        #expect(library.state.sidebarSelection == .account(library.home.id))
        #expect(library.state.selectedDay == open)
        #expect(library.state.messages.map(\.body) == ["delta"])
    }

    @Test
    func `spaces around the keyword keep the results, the open day and its messages`() async throws {
        let library = try await Self.started()
        library.state.setSearchText("alpha")
        try await library.settle()
        let (results, open, messages) = (library.state.dayMatches, library.state.selectedDay, library.state.messages)
        try #require(!results.isEmpty)

        library.state.setSearchText("alpha ")
        library.state.setFindText(" alpha  ")

        #expect(library.state.keyword == " alpha  ")
        #expect(library.state.dayMatches == results)
        #expect(library.state.selectedDay == open)
        #expect(library.state.messages == messages)
        #expect(!library.state.isScanning)
    }

    @Test(arguments: [false, true])
    func `another keyword drops the results and the open day, and the new search's first result is opened`(inFindBar: Bool) async throws {
        let library = try await Self.started()
        library.state.setSearchText("alpha")
        try await library.settle()

        if inFindBar { library.state.setFindText("delta") } else { library.state.setSearchText("delta") }

        #expect(library.state.dayMatches.isEmpty)
        #expect(library.state.selectedDay == nil)
        #expect(library.state.messages.isEmpty)
        #expect(library.state.isScanning)

        try await library.settle()
        #expect(library.state.searchesAllConversations)
        #expect(library.state.listedDays == [library.day(4, of: library.bob)])
        #expect(library.state.selectedDay == library.day(4, of: library.bob))
        #expect(try library.state.currentMatchID == library.id("delta"))
    }

    /// With a keyword that matches nothing, no result's day is opened, so the search starting is all that keeps the
    /// held load from publishing.
    @Test(arguments: ["alpha", "nowhere"])
    func `a selection's load held when a search starts publishes nothing under the search`(keyword: String) async throws {
        let library = try TranscriptLibraryFixture()
        await library.seed()
        await library.state.load()
        let gate = await library.gates.suspendNext(.dates(library.alice.id))
        let loading = Task { await library.state.select(.account(library.home.id))?.value }
        try await gate.waitForArrival()
        let matches = keyword == "alpha"

        library.state.setSearchText(keyword)
        try await library.settle()
        await gate.open()
        await loading.value

        #expect(library.state.days.isEmpty)
        #expect(library.state.listedDays == (matches ? Self.alphaDays(library) : []))
        #expect(library.state.selectedDay == (matches ? library.day(3, of: library.alice) : nil))
        #expect(library.state.messages.map(\.body) == (matches ? ["alpha three"] : []))
        #expect(!library.state.isLoading)
    }

    /// The search has run over lists still empty before the load is let through, so it finds something only by
    /// starting over when they arrive. That holds whatever else the start does: with a filter that hides every section
    /// there is no default to select, and after a request that matches nothing none is wanted.
    @Test(arguments: ["a default section", "a filter that hides every section", "a request that matches nothing"])
    func `a keyword typed while the lists load is searched once they are there`(start: String) async throws {
        let library = try TranscriptLibraryFixture()
        await library.seed()
        let unknown = try TranscriptLibraryFixture.conversation("unknown@example.com", accountID: library.home.id)
        let selectsDefault = start == "a default section"
        let gate = await library.gates.suspendNext(.conversations)
        let starting = Task { await library.state.start(with: start == "a request that matches nothing" ? library.scope(unknown) : nil) }
        try await gate.waitForArrival()

        if start == "a filter that hides every section" { library.state.sidebarFilter = "nobody" }
        library.state.setSearchText("alpha")
        await library.state.pendingSearch?.value
        try #require(library.state.hasNoResults)
        await gate.open()
        await starting.value
        try await library.settle()

        #expect(library.state.listedDays == Self.alphaDays(library))
        #expect(library.state.selectedDay == library.day(3, of: library.alice))
        #expect(try library.state.currentMatchID == library.id("alpha three"))
        #expect(library.state.sidebarSelection == nil)

        library.state.setSearchText("")
        try await library.settle()
        #expect(library.state.sidebarSelection == (selectsDefault ? .account(library.home.id) : nil))
        #expect(library.state.listedDays == (selectsDefault ? library.homeDays : []))
    }

    @Test
    func `a keyword typed over cancels the search still waiting, so each day is listed once`() async throws {
        let library = try await Self.started(searchDelay: .milliseconds(20))
        library.state.setSearchText("alph")
        let waiting = try #require(library.state.pendingSearch)

        library.state.setSearchText("alpha")
        await waiting.value
        try await library.settle()

        #expect(library.state.listedDays == Self.alphaDays(library))
        #expect(library.state.matchTotal == 5)
    }

    @Test
    func `the reveal of a result's match stays pending until the list holds the day's rows`() async throws {
        let library = try await Self.started()
        let list = StandInTranscriptList(attachedTo: library.state.scroller)
        list.rowIDs = []

        library.state.setSearchText("alpha")
        try await library.settle()
        #expect(list.takenRequests.isEmpty)

        list.rowIDs = Set(library.state.messages.map(\.id))
        list.takePendingRequest()
        #expect(try list.takenRequests == [.revealWhenShown(library.id("alpha three"))])
    }

    @Test
    func `between a keyword change and the search's end, the state never reads as no results`() async throws {
        let library = try await Self.started()
        let gate = await library.gates.suspendNext(.matches(library.bob.id, library.day(4, of: library.bob).date))

        library.state.setSearchText("nowhere")
        #expect(!library.state.hasNoResults)
        try await gate.waitForArrival()
        #expect(!library.state.hasNoResults)

        await gate.open()
        try await library.settle()
        #expect(library.state.hasNoResults)

        library.state.setSearchText("nowhere at all")
        #expect(!library.state.hasNoResults)
        try await library.settle()
        #expect(library.state.hasNoResults)
    }

    @Test(arguments: [false, true])
    func `clearing the search text restores the selection's days`(searchDroppedTheirLoad: Bool) async throws {
        let library = try TranscriptLibraryFixture()
        await library.seed()
        await library.state.load()
        if searchDroppedTheirLoad {
            let gate = await library.gates.suspendNext(.dates(library.alice.id))
            let loading = Task { await library.state.select(.account(library.home.id))?.value }
            try await gate.waitForArrival()
            library.state.setSearchText("alpha")
            await gate.open()
            await loading.value
        } else {
            await library.state.select(.account(library.home.id))?.value
            library.state.setSearchText("alpha")
        }
        try await library.settle()
        try #require(library.state.selectedDay == library.day(3, of: library.alice))

        library.state.setSearchText("")
        try await library.settle()

        #expect(!library.state.isFindBarVisible)
        #expect(library.state.sidebarSelection == .account(library.home.id))
        #expect(library.state.listedDays == library.homeDays)
        // The result that was open is one of the account's days, so it stays open.
        #expect(library.state.selectedDay == library.day(3, of: library.alice))
        #expect(library.state.messages.map(\.body) == ["alpha three"])
        #expect(library.state.dayMatches.isEmpty)
    }

    // MARK: - Leaving a search

    @Test
    func `clicking the row selected before ends the search and keeps its keyword as a find within that row`() async throws {
        let library = try await Self.started()
        library.state.setSearchText("alpha")
        try await library.settle()

        let loading = library.state.select(.account(library.home.id))

        #expect(!library.state.searchesAllConversations)
        #expect(library.state.isFindBarVisible)
        #expect(library.state.keyword == "alpha")
        #expect(library.state.searchFieldText.isEmpty)
        #expect(library.state.sidebarSelection == .account(library.home.id))

        await loading?.value
        try await library.settle()
        #expect(library.state.listedDays == library.homeDays)
        // The open result is a day of the clicked account.
        #expect(library.state.selectedDay == library.day(3, of: library.alice))
        #expect(library.state.dayMatches.map(\.day) == [library.day(3, of: library.alice), library.day(1, of: library.alice)])
    }

    @Test
    func `clicking a row the open result does not belong to opens that row's newest day`() async throws {
        let library = try await Self.started()
        await library.state.select(.account(library.work.id))?.value
        library.state.setSearchText("alpha")
        try await library.settle()
        try #require(library.state.selectedDay == library.day(3, of: library.alice))

        await library.state.select(.account(library.work.id))?.value
        try await library.settle()

        #expect(library.state.selectedDay == library.day(2, of: library.carol))
        #expect(library.state.dayMatches.map(\.day) == [library.day(2, of: library.carol)])
    }

    @Test
    func `selecting an account's only conversation after the account drops the results and searches again`() async throws {
        let library = try await Self.started()
        await library.state.select(.account(library.work.id))?.value
        library.state.toggleFind()
        library.state.setFindText("alpha")
        try await library.settle()
        let results = library.state.dayMatches
        try #require(results.map(\.day) == [library.day(2, of: library.carol)])
        let readsBefore = await library.transcripts.mock.matchedDays.count

        let loading = library.state.select(.conversation(library.carol.id))
        #expect(library.state.dayMatches.isEmpty)
        #expect(library.state.isScanning)

        await loading?.value
        try await library.settle()
        #expect(library.state.dayMatches == results)
        #expect(await library.transcripts.mock.matchedDays.count == readsBefore + 1)
    }

    @Test
    func `emptying the find bar during a search over all conversations ends it and leaves the bar`() async throws {
        let library = try await Self.started()
        library.state.setSearchText("alpha")
        try await library.settle()

        library.state.setFindText("")
        try await library.settle()

        #expect(!library.state.searchesAllConversations)
        #expect(library.state.isFindBarVisible)
        #expect(library.state.listedDays == library.homeDays)
        #expect(library.state.dayMatches.isEmpty)
    }

    @Test
    func `the find command shows the bar, and hides it together with a search that showed it`() async throws {
        let library = try await Self.started()

        library.state.toggleFind()
        #expect(library.state.isFindBarVisible)
        library.state.toggleFind()
        #expect(!library.state.isFindBarVisible)

        library.state.setSearchText("alpha")
        try await library.settle()
        library.state.toggleFind()
        try await library.settle()

        #expect(!library.state.isFindBarVisible)
        #expect(!library.state.searchesAllConversations)
        #expect(library.state.keyword.isEmpty)
        #expect(library.state.listedDays == library.homeDays)
    }

    @Test
    func `done on a find within the selection drops its matches and keeps the open day`() async throws {
        let library = try await Self.started()
        library.state.toggleFind()
        library.state.setFindText("alpha")
        try await library.settle()
        try #require(!library.state.dayMatches.isEmpty)

        library.state.endFind()

        #expect(!library.state.isFindBarVisible)
        #expect(library.state.dayMatches.isEmpty)
        #expect(library.state.selectedDay == library.day(4, of: library.bob))
        #expect(library.state.messages.map(\.body) == ["delta"])
    }

    /// The search opens its first result while the request waits for the conversations. That is no choice of the
    /// reader's, so the request still goes through.
    @Test
    func `a request for a conversation ends a search, also one that opened a result while the request waited`() async throws {
        let library = try await Self.started()
        let searchGate = await library.gates.suspendNext(.matches(library.alice.id, library.day(3, of: library.alice).date))
        library.state.setSearchText("alpha")
        try await searchGate.waitForArrival()
        let scopeGate = await library.gates.suspendNext(.conversations)
        let scoping = Task { await library.state.applyScope(library.scope(library.bob)) }
        try await scopeGate.waitForArrival()

        await searchGate.open()
        try await library.settle()
        try #require(library.state.selectedDay == library.day(3, of: library.alice))
        await scopeGate.open()
        await scoping.value
        try await library.settle()

        #expect(!library.state.isFindBarVisible)
        #expect(library.state.keyword.isEmpty)
        #expect(library.state.sidebarSelection == .conversation(library.bob.id))
        #expect(library.state.listedDays == [library.day(4, of: library.bob), library.day(2, of: library.bob)])
        #expect(library.state.selectedDay == library.day(4, of: library.bob))
        #expect(library.state.dayMatches.isEmpty)
    }

    /// A request that matches nothing refreshes the left list and leaves the rest alone, also when the refresh brings
    /// a conversation the search has not read.
    @Test(arguments: [false, true])
    func `a refresh of the conversations leaves a search its results and the day the reader opened`(opensWhileWaiting: Bool) async throws {
        let library = try await Self.started()
        library.state.setSearchText("alpha")
        try await library.settle()
        let results = library.state.dayMatches
        try #require(results.map(\.day) == Self.alphaDays(library))
        let opened = library.day(1, of: library.alice)
        let newcomer = try TranscriptLibraryFixture.conversation("newcomer@example.com", accountID: library.home.id)
        await library.store.mock.addConversation(newcomer)
        let unknown = try TranscriptLibraryFixture.conversation("unknown@example.com", accountID: library.home.id)

        if !opensWhileWaiting { await library.state.selectDay(opened)?.value }
        let gate = await library.gates.suspendNext(.conversations)
        let scoping = Task { await library.state.applyScope(library.scope(unknown)) }
        try await gate.waitForArrival()
        if opensWhileWaiting { await library.state.selectDay(opened)?.value }
        await gate.open()
        await scoping.value
        try await library.settle()

        try #require(library.state.allConversations.contains { $0.id == newcomer.id })
        #expect(library.state.dayMatches == results)
        #expect(library.state.selectedDay == opened)
        #expect(library.state.messages.map(\.body) == ["alpha one", "beta", "alpha two"])
    }

    // MARK: - Stepping through matches

    @Test
    func `next and previous cross from one day's matches into the next listed day's and wrap at the ends`() async throws {
        let library = try await Self.started()
        await library.state.select(.conversation(library.alice.id))?.value
        let list = StandInTranscriptList(attachedTo: library.state.scroller)
        library.state.toggleFind()
        library.state.setFindText("alpha")
        try await library.settle()
        let (newer, older) = (library.day(3, of: library.alice), library.day(1, of: library.alice))
        let (one, two, three) = try (library.id("alpha one"), library.id("alpha two"), library.id("alpha three"))

        // With matches and none current, the bar has a total and no number.
        #expect(library.state.matchTotal == 3)
        #expect(library.state.currentMatchNumber == nil)

        var visited: [UUID?] = []
        var numbers: [Int?] = []
        for forward in [true, true, true, true, false, false, false] {
            await (forward ? library.state.findNext() : library.state.findPrevious())?.value
            visited.append(library.state.currentMatchID)
            numbers.append(library.state.currentMatchNumber)
        }

        #expect(visited == [three, one, two, three, two, one, three])
        #expect(numbers == [1, 2, 3, 1, 3, 2, 1])
        #expect(library.state.selectedDay == newer)
        #expect(list.takenRequests == [three, one, two, three, two, one, three].map { .revealWhenShown($0) })

        // After the reader opens another day, stepping starts from that day.
        await library.state.selectDay(older)?.value
        #expect(library.state.currentMatchID == nil)
        library.state.findNext()
        #expect(library.state.currentMatchID == one)

        await library.state.selectDay(newer)?.value
        await library.state.selectDay(older)?.value
        library.state.findPrevious()
        #expect(library.state.currentMatchID == two)
    }

    @Test
    func `with no current match, stepping starts at the nearest listed day with matches and wraps past the ends`() async throws {
        let library = try await Self.started()
        library.state.toggleFind()
        library.state.setFindText("alpha")
        try await library.settle()
        let (one, two, three) = try (library.id("alpha one"), library.id("alpha two"), library.id("alpha three"))
        let (newest, between) = (library.day(4, of: library.bob), library.day(2, of: library.bob))

        // The open day is the newest and has no match.
        try #require(library.state.selectedDay == newest)
        await library.state.findNext()?.value
        #expect(library.state.currentMatchID == three)

        await library.state.selectDay(between)?.value
        await library.state.findNext()?.value
        #expect(library.state.currentMatchID == one)

        await library.state.selectDay(between)?.value
        await library.state.findPrevious()?.value
        #expect(library.state.currentMatchID == three)

        await library.state.selectDay(newest)?.value
        await library.state.findPrevious()?.value
        #expect(library.state.currentMatchID == two)
    }

    // MARK: - Superseded searches

    /// Run in a task the test owns: cancelling the state's own task would let the gate through at once.
    @Test
    func `a superseded search reads no further day and publishes nothing`() async throws {
        let library = try await Self.started(searchDelay: .seconds(60))
        library.state.setSearchText("alpha")
        let gate = await library.gates.suspendNext(.matches(library.alice.id, library.day(3, of: library.alice).date))
        let search = Task { await library.state.runSearch() }
        try await gate.waitForArrival()

        library.state.endFind()
        await gate.open()
        await search.value
        try await library.settle()

        #expect(library.state.dayMatches.isEmpty)
        #expect(!library.state.isScanning)
        #expect(await library.transcripts.mock.matchedDays == [library.day(4, of: library.bob), library.day(3, of: library.alice)])
    }

    /// The only match is on the last day read, so the run is superseded while it opens that day and ends without
    /// another day to stop at.
    @Test
    func `a search superseded while it opens its last day leaves the newer search scanning`() async throws {
        let library = try await Self.started(searchDelay: .seconds(60))
        library.state.setSearchText("dave")
        let gate = await library.gates.suspendNext(.day(library.dave.id, library.day(0, of: library.dave).date))
        let search = Task { await library.state.runSearch() }
        try await gate.waitForArrival()

        library.state.setSearchText("nowhere")
        await gate.open()
        await search.value

        #expect(library.state.isScanning)
        #expect(!library.state.hasNoResults)
        #expect(library.state.selectedDay == nil)
        library.state.endFind()
    }
}
