import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoUI

@MainActor
struct TranscriptViewerStateScopeTests {
    private struct Fixture {
        let state: TranscriptViewerState
        let store: MockPersistenceStore
        let transcripts: MockTranscriptStore
    }

    private static func makeFixture() async throws -> Fixture {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let environment = AppEnvironment(
            store: store,
            transcripts: transcripts,
            credentialStore: NullCredentialStore()
        )
        return Fixture(
            state: TranscriptViewerState(environment: environment),
            store: store,
            transcripts: transcripts
        )
    }

    private static func conversation(id: UUID = UUID(), accountID: UUID, jid: String) throws -> Conversation {
        try Conversation(
            id: id,
            accountID: accountID,
            jid: #require(BareJID.parse(jid)),
            type: .chat,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        )
    }

    private static func message(conversationID: UUID, body: String, timestamp: Date) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            conversationID: conversationID,
            fromJID: "bob@example.com",
            body: body,
            timestamp: timestamp,
            isOutgoing: false,
            isDelivered: true,
            isEdited: false,
            type: "chat"
        )
    }

    @Test func `applyScope resolves by conversation id and loads the latest day's messages`() async throws {
        let fixture = try await Self.makeFixture()
        let conv = try Self.conversation(accountID: UUID(), jid: "bob@example.com")
        await fixture.store.addConversation(conv)
        await fixture.transcripts.addMessage(Self.message(conversationID: conv.id, body: "hi", timestamp: Date()))

        let request = TranscriptScope().request(ConversationRef(conversation: conv))
        await fixture.state.applyScope(request)

        #expect(fixture.state.selection == .conversation(conv.id))
        #expect(fixture.state.selectedDay != nil)
        #expect(fixture.state.messages.count == 1)
    }

    @Test func `applyScope refreshes the conversation list so a conversation created after load still resolves`() async throws {
        let fixture = try await Self.makeFixture()
        // The viewer opened with no conversations (load() ran before this chat existed),
        // so allConversations is empty — the History re-scope path must refresh first.
        #expect(fixture.state.allConversations.isEmpty)

        let conv = try Self.conversation(accountID: UUID(), jid: "carol@example.com")
        await fixture.store.addConversation(conv)
        await fixture.transcripts.addMessage(Self.message(conversationID: conv.id, body: "later", timestamp: Date()))

        let request = TranscriptScope().request(ConversationRef(conversation: conv))
        await fixture.state.applyScope(request)

        #expect(fixture.state.selection == .conversation(conv.id))
        #expect(fixture.state.messages.count == 1)
    }

    @Test func `applyScope leaves selection unchanged when no conversation matches`() async throws {
        let fixture = try await Self.makeFixture()
        let present = try Self.conversation(accountID: UUID(), jid: "bob@example.com")
        await fixture.store.addConversation(present)

        // Request a different conversation that the store never knows about.
        let absent = try Self.conversation(accountID: UUID(), jid: "ghost@example.com")
        let request = TranscriptScope().request(ConversationRef(conversation: absent))
        await fixture.state.applyScope(request)

        #expect(fixture.state.selection == nil)
        #expect(fixture.state.messages.isEmpty)
    }
}

extension TranscriptViewerStateScopeTests {
    @MainActor
    private struct RaceFixture {
        let gates: TranscriptReadGates
        let store: GatedTranscriptPersistenceStore
        let transcripts: GatedTranscriptStore
        let state: TranscriptViewerState
        let first: Conversation
        let second: Conversation
        let older = Date(timeIntervalSince1970: 1_700_006_400)
        let latest = Date(timeIntervalSince1970: 1_700_092_800)

        init() throws {
            let gates = TranscriptReadGates()
            self.gates = gates
            let store = GatedTranscriptPersistenceStore(gates: gates)
            self.store = store
            let transcripts = GatedTranscriptStore(gates: gates)
            self.transcripts = transcripts
            self.state = TranscriptViewerState(environment: AppEnvironment(store: store, transcripts: transcripts, credentialStore: NullCredentialStore()))
            self.first = try conversation(accountID: UUID(), jid: "first@example.com")
            self.second = try conversation(accountID: UUID(), jid: "second@example.com")
        }

        func seed() async {
            await store.mock.addConversation(first)
            await store.mock.addConversation(second)
            for conversation in [first, second] {
                await transcripts.mock.addMessage(message(conversationID: conversation.id, body: "alpha", timestamp: older))
                await transcripts.mock.addMessage(message(conversationID: conversation.id, body: "beta", timestamp: latest))
            }
        }

        func day(_ date: Date, of conversation: Conversation) -> TranscriptDay {
            TranscriptDay(conversationID: conversation.id, date: date)
        }

        func select(_ conversation: Conversation?) async {
            await state.select(conversation.map { .conversation($0.id) })?.value
        }

        func selectDay(_ date: Date?, of conversation: Conversation) async {
            await state.selectDay(date.map { day($0, of: conversation) })?.value
        }

        func assertSelected(_ conversation: Conversation, on date: Date) {
            #expect(state.selection == .conversation(conversation.id))
            #expect(state.selectedDay == day(date, of: conversation))
            #expect(state.days == [day(latest, of: conversation), day(older, of: conversation)])
            #expect(state.messages.count == 1)
            #expect(state.messages.allSatisfy { $0.conversationID == conversation.id && $0.timestamp == date })
            #expect(Set(state.positions.keys) == Set(state.messages.map(\.id)))
        }

        func scope(_ conversation: Conversation, generation: Int = 1) -> ScopeRequest {
            ScopeRequest(generation: generation, ref: ConversationRef(conversation: conversation))
        }
    }

    @Test func `a day is shown from its first message`() async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        await fixture.select(fixture.first)
        let list = StandInTranscriptList(attachedTo: fixture.state.scroller)

        await fixture.selectDay(fixture.older, of: fixture.first)

        // Once when the day before is taken away, and once when this day's messages are in.
        #expect(list.settledPositions == [.oldest, .oldest])
    }

    @Test func `a day shows the timeline notes written on it`() async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let note = TimelineNote(
            conversationID: fixture.first.id, timestamp: fixture.latest.addingTimeInterval(60), kind: .encryptionEnabledByContact
        )
        try await fixture.transcripts.mock.appendNote(note)

        await fixture.select(fixture.first)
        // Armed: the day the note was written on is the one shown.
        #expect(fixture.state.selectedDay == fixture.day(fixture.latest, of: fixture.first))
        #expect(fixture.state.notes == [note])
        #expect(fixture.state.timelineItems.last?.id == note.id)

        await fixture.selectDay(fixture.older, of: fixture.first)
        #expect(fixture.state.notes.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func `new conversation wins regardless of detail completion order`(pauseDay: Bool, oldFinishesFirst: Bool) async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let firstGate = await fixture.gates.suspendNext(pauseDay ? .day(fixture.first.id, fixture.latest) : .dates(fixture.first.id))
        let first = Task { await fixture.select(fixture.first) }
        try await firstGate.waitForArrival()
        let secondGate = await fixture.gates.suspendNext(.dates(fixture.second.id))
        let second = Task { await fixture.select(fixture.second) }
        try await secondGate.waitForArrival()
        if oldFinishesFirst {
            await firstGate.open()
            await first.value
            #expect(fixture.state.isLoading)
            #expect(fixture.state.messages.isEmpty)
            await secondGate.open()
        } else {
            await secondGate.open()
            await second.value
            fixture.assertSelected(fixture.second, on: fixture.latest)
            await firstGate.open()
        }
        await first.value
        await second.value
        fixture.assertSelected(fixture.second, on: fixture.latest)
        #expect(!fixture.state.isLoading)
    }

    @Test
    func `explicit date supersedes the automatic latest day`() async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let gate = await fixture.gates.suspendNext(.day(fixture.first.id, fixture.latest))
        let automatic = Task { await fixture.select(fixture.first) }
        try await gate.waitForArrival()
        await fixture.selectDay(fixture.older, of: fixture.first)
        await gate.open()
        await automatic.value
        fixture.assertSelected(fixture.first, on: fixture.older)
        #expect(!fixture.state.isLoading)
    }

    @Test(arguments: [false, true])
    func `clearing conversation or date invalidates suspended detail`(clearConversation: Bool) async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let gate = await fixture.gates.suspendNext(.day(fixture.first.id, fixture.latest))
        let loading = Task { await fixture.select(fixture.first) }
        try await gate.waitForArrival()
        if clearConversation { await fixture.select(nil) } else { await fixture.selectDay(nil, of: fixture.first) }
        await gate.open()
        await loading.value
        #expect(fixture.state.selectedDay == nil)
        #expect(fixture.state.messages.isEmpty)
        #expect(fixture.state.positions.isEmpty)
        #expect(!fixture.state.isLoading)
        if clearConversation {
            #expect(fixture.state.selection == nil)
            #expect(fixture.state.days.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func `clearing a date invalidates the pending list of days`(clearDate: Bool) async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let gate = await fixture.gates.suspendNext(.dates(fixture.first.id))
        let loading = Task { await fixture.select(fixture.first) }
        defer { loading.cancel(); Task { await gate.open() } }
        try await gate.waitForArrival()
        #expect(fixture.state.selection == .conversation(fixture.first.id))
        #expect(fixture.state.isLoading)
        if clearDate { await fixture.selectDay(nil, of: fixture.first) }
        await gate.open()
        await loading.value
        if clearDate {
            #expect(fixture.state.selectedDay == nil)
            #expect(fixture.state.days.isEmpty)
            #expect(fixture.state.messages.isEmpty)
            #expect(fixture.state.positions.isEmpty)
        } else {
            fixture.assertSelected(fixture.first, on: fixture.latest)
        }
        #expect(!fixture.state.isLoading)
    }

    @Test
    func `local selection during scope refresh wins`() async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let gate = await fixture.gates.suspendNext(.conversations)
        let scope = Task { await fixture.state.applyScope(fixture.scope(fixture.first)) }
        try await gate.waitForArrival()
        await fixture.select(fixture.second)
        await gate.open()
        await scope.value
        fixture.assertSelected(fixture.second, on: fixture.latest)
    }

    @Test(arguments: [false, true])
    func `resolved scope supersedes local load but an unmatched scope preserves it`(unmatched: Bool) async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let gate = await fixture.gates.suspendNext(.dates(fixture.first.id))
        let local = Task { await fixture.select(fixture.first) }
        try await gate.waitForArrival()
        let target = try unmatched ? Self.conversation(accountID: UUID(), jid: "missing@example.com") : fixture.second
        await fixture.state.applyScope(fixture.scope(target))
        if unmatched { #expect(fixture.state.isLoading) }
        await gate.open()
        await local.value
        fixture.assertSelected(unmatched ? fixture.first : fixture.second, on: fixture.latest)
        #expect(!fixture.state.isLoading)
    }

    @Test(arguments: [false, true])
    func `new scope rejects an older refresh even when the old read fails`(failOldRead: Bool) async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let gate = await fixture.gates.suspendNext(.conversations)
        let old = Task { await fixture.state.applyScope(fixture.scope(fixture.first)) }
        try await gate.waitForArrival()
        try await fixture.store.mock.deleteConversation(fixture.first.id)
        await fixture.state.applyScope(fixture.scope(fixture.second, generation: 2))
        await gate.open(failing: failOldRead)
        await old.value
        #expect(fixture.state.allConversations.map(\.id) == [fixture.second.id])
        fixture.assertSelected(fixture.second, on: fixture.latest)
    }

    @Test(arguments: [false, true])
    func `bootstrap cannot overwrite a newer scope list`(pauseAccounts: Bool) async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let gate = await fixture.gates.suspendNext(pauseAccounts ? .accounts : .conversations)
        let bootstrap = Task { await fixture.state.load() }
        try await gate.waitForArrival()
        try await fixture.store.mock.deleteConversation(fixture.first.id)
        await fixture.state.applyScope(fixture.scope(fixture.second))
        #expect(fixture.state.isLoading)
        await gate.open()
        await bootstrap.value
        #expect(fixture.state.allConversations.map(\.id) == [fixture.second.id])
        fixture.assertSelected(fixture.second, on: fixture.latest)
        #expect(!fixture.state.isLoading)
    }

    @Test
    func `new bootstrap rejects an older successful conversation list`() async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let gate = await fixture.gates.suspendNext(.conversations)
        let old = Task { await fixture.state.load() }
        try await gate.waitForArrival()
        try await fixture.store.mock.deleteConversation(fixture.first.id)
        await fixture.state.load()
        #expect(fixture.state.allConversations.map(\.id) == [fixture.second.id])
        await gate.open()
        await old.value
        #expect(fixture.state.allConversations.map(\.id) == [fixture.second.id])
        #expect(!fixture.state.isLoading)
    }

    @Test(arguments: [false, true], [false, true])
    func `failed scope refresh preserves a successful bootstrap list`(pauseAccounts: Bool, bootstrapFinishesFirst: Bool) async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let bootstrapGate = await fixture.gates.suspendNext(pauseAccounts ? .accounts : .conversations)
        let bootstrap = Task { await fixture.state.load() }
        try await bootstrapGate.waitForArrival()
        let scopeGate = await fixture.gates.suspendNext(.conversations)
        let scope = Task { await fixture.state.applyScope(fixture.scope(fixture.second)) }
        do {
            try await scopeGate.waitForArrival()
            if bootstrapFinishesFirst {
                await bootstrapGate.open()
                await bootstrap.value
            }
            await scopeGate.open(failing: true)
            await scope.value
            if !bootstrapFinishesFirst { await bootstrapGate.open() }
            await bootstrap.value
        } catch {
            await bootstrapGate.open()
            await scopeGate.open(failing: true)
            await bootstrap.value
            await scope.value
            throw error
        }
        #expect(Set(fixture.state.allConversations.map(\.id)) == [fixture.first.id, fixture.second.id])
        #expect(!fixture.state.isLoading)
    }

    @Test
    func `duplicate cold open scope cannot undo a subsequent local choice`() async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let request = fixture.scope(fixture.first)
        await fixture.state.applyScope(request)
        await fixture.select(fixture.second)
        await fixture.state.applyScope(request)
        fixture.assertSelected(fixture.second, on: fixture.latest)
    }

    @Test(arguments: [false, true])
    func `stale detail failure cannot clear the current loading owner`(pauseDay: Bool) async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let oldGate = await fixture.gates.suspendNext(pauseDay ? .day(fixture.first.id, fixture.latest) : .dates(fixture.first.id))
        let old = Task { await fixture.select(fixture.first) }
        try await oldGate.waitForArrival()
        let currentGate = await fixture.gates.suspendNext(.dates(fixture.second.id))
        let current = Task { await fixture.select(fixture.second) }
        try await currentGate.waitForArrival()
        await oldGate.open(failing: true)
        await old.value
        #expect(fixture.state.isLoading)
        #expect(fixture.state.selection == .conversation(fixture.second.id))
        await currentGate.open()
        await current.value
        fixture.assertSelected(fixture.second, on: fixture.latest)
        #expect(!fixture.state.isLoading)
    }
}

extension TranscriptViewerStateScopeTests {
    @Test
    func `selecting an account lists the days of all its conversations newest first, whatever the filter hides`() async throws {
        let library = try TranscriptLibraryFixture()
        await library.seed()
        await library.state.load()
        library.state.sidebarFilter = "alice"
        #expect(library.state.sidebarSections.map { $0.conversations.map(\.id) } == [[library.alice.id]])

        await library.state.select(.account(library.home.id))?.value

        #expect(library.state.days == library.homeDays)
        #expect(library.state.selectedDay == library.day(4, of: library.bob))
        #expect(library.state.shownConversation?.id == library.bob.id)
        #expect(library.state.messages.map(\.body) == ["delta"])
    }

    @Test(arguments: ["zoe", "ZOE", "zoë"])
    func `the filter finds a conversation by its name, ignoring case and diacritics`(filter: String) async throws {
        let library = try TranscriptLibraryFixture()
        await library.seed()
        let zoe = try Conversation(
            id: UUID(), accountID: library.work.id, jid: #require(BareJID.parse("z@example.com")), type: .chat,
            displayName: "Zoë", isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
        )
        await library.store.mock.addConversation(zoe)
        await library.state.load()

        library.state.sidebarFilter = filter

        #expect(library.state.sidebarSections.map { $0.conversations.map(\.id) } == [[zoe.id]])
    }

    /// The list is built anew whenever an edit of the filter changes whether it has the selected row, and at no other
    /// time: not while the row stays hidden or listed, and not when a click selects another row.
    @Test
    func `the left list is built anew when a filter edit hides the selected row or brings it back`() async throws {
        let library = try TranscriptLibraryFixture()
        await library.seed()
        await library.state.load()
        library.state.sidebarFilter = "alice"
        library.state.sidebarFilter = ""
        #expect(library.state.sidebarListGeneration == 0)

        await library.state.select(.conversation(library.bob.id))?.value
        library.state.sidebarFilter = "alice"
        #expect(library.state.sidebarListGeneration == 1)
        library.state.sidebarFilter = "alic"
        #expect(library.state.sidebarListGeneration == 1)
        library.state.sidebarFilter = "bob"
        #expect(library.state.sidebarListGeneration == 2)

        library.state.sidebarFilter = "alice"
        #expect(library.state.sidebarListGeneration == 3)
        await library.state.select(.conversation(library.alice.id))?.value
        library.state.sidebarFilter = ""
        #expect(library.state.sidebarListGeneration == 3)

        // An account goes with the last of its rows.
        await library.state.select(.account(library.home.id))?.value
        library.state.sidebarFilter = "bob"
        #expect(library.state.sidebarListGeneration == 3)
        library.state.sidebarFilter = "carol"
        #expect(library.state.sidebarListGeneration == 4)
        #expect(library.state.selection == .account(library.home.id))
    }

    @Test
    func `selecting an imported history lists its days, and a find within it marks them`() async throws {
        let library = try TranscriptLibraryFixture()
        await library.seed()
        await library.state.load()

        await library.state.select(.importSource(TranscriptLibraryFixture.importSource))?.value
        let days = [library.day(1, of: library.dave), library.day(0, of: library.dave)]
        #expect(library.state.days == days)

        library.state.toggleFind()
        library.state.setFindText("alpha")
        try await library.settle()

        #expect(try library.state.dayMatches == [TranscriptDayMatches(day: days[1], messageIDs: [library.id("alpha dave")])])
        #expect(library.state.matchCounts == [days[1]: 1])
        // A find marks the days it found matches on. It neither narrows the list nor opens a day.
        #expect(library.state.listedDays == days)
        #expect(library.state.selectedDay == days[0])
    }

    @Test
    func `selecting nothing clears the detail`() async throws {
        let library = try TranscriptLibraryFixture()
        await library.seed()
        await library.state.start(with: nil)
        try #require(!library.state.messages.isEmpty)

        library.state.select(nil)

        #expect(library.state.selection == nil)
        #expect(library.state.days.isEmpty)
        #expect(library.state.selectedDay == nil)
        #expect(library.state.messages.isEmpty)
        #expect(!library.state.isLoading)
    }

    @Test
    func `selecting a conversation whose day is open under its account keeps that day open`() async throws {
        let library = try TranscriptLibraryFixture()
        await library.seed()
        await library.state.start(with: nil)
        let open = library.day(1, of: library.alice)
        await library.state.selectDay(open)?.value

        await library.state.select(.conversation(library.alice.id))?.value

        #expect(library.state.days == [library.day(3, of: library.alice), open])
        #expect(library.state.selectedDay == open)
        #expect(library.state.messages.map(\.body) == ["alpha one", "beta", "alpha two"])
    }

    /// The contact list only holds the contacts of enabled accounts whose roster it loaded, so the window reads the
    /// store.
    @Test
    func `a contact's stored photo is found without its account's roster loaded, and an imported conversation has none`() async throws {
        let library = try TranscriptLibraryFixture()
        await library.seed()
        let photo = Data([1, 2, 3])
        try await library.store.mock.upsertContact(Contact(
            id: UUID(), accountID: library.home.id, jid: library.alice.jid, subscription: .both, groups: [],
            avatarData: photo, isBlocked: false, createdAt: Date()
        ))

        await library.state.load()

        #expect(library.state.avatarData(for: library.alice) == photo)
        #expect(library.state.avatarData(for: library.bob) == nil)
        #expect(library.state.avatarData(for: library.dave) == nil)
    }

    @Test
    func `starting with no request selects the first account and loads its newest day`() async throws {
        let library = try TranscriptLibraryFixture()
        await library.seed()

        await library.state.start(with: nil)

        #expect(library.state.selection == .account(library.home.id))
        #expect(library.state.selectedDay == library.day(4, of: library.bob))
        #expect(library.state.messages.map(\.body) == ["delta"])
    }

    @Test
    func `starting with a request ends on its conversation and lists no other on the way`() async throws {
        let library = try TranscriptLibraryFixture()
        await library.seed()

        await library.state.start(with: library.scope(library.carol))

        #expect(library.state.selection == .conversation(library.carol.id))
        #expect(library.state.selectedDay == library.day(2, of: library.carol))
        #expect(await library.listedConversations == [library.carol.id])
    }

    @Test
    func `a request applied while the start is held in its load wins, and the first account is never selected`() async throws {
        let library = try TranscriptLibraryFixture()
        await library.seed()
        let gate = await library.gates.suspendNext(.conversations)
        let start = Task { await library.state.start(with: nil) }
        try await gate.waitForArrival()

        await library.state.applyScope(library.scope(library.carol))
        await gate.open()
        await start.value

        #expect(library.state.selection == .conversation(library.carol.id))
        #expect(library.state.selectedDay == library.day(2, of: library.carol))
        #expect(await library.listedConversations == [library.carol.id])
    }

    @Test
    func `starting with a request that matches nothing selects nothing`() async throws {
        let library = try TranscriptLibraryFixture()
        await library.seed()
        let ghost = try Self.conversation(accountID: UUID(), jid: "ghost@example.com")

        await library.state.start(with: library.scope(ghost))

        #expect(library.state.selection == nil)
        #expect(library.state.selectedDay == nil)
        #expect(await library.listedConversations.isEmpty)
    }
}
