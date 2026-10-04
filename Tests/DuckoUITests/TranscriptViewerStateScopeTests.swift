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

        #expect(fixture.state.selectedConversation?.id == conv.id)
        #expect(fixture.state.selectedDate != nil)
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

        #expect(fixture.state.selectedConversation?.id == conv.id)
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

        #expect(fixture.state.selectedConversation == nil)
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

        func assertSelected(_ conversation: Conversation, on date: Date) {
            #expect(state.selectedConversation?.id == conversation.id)
            #expect(state.selectedDate == date)
            #expect(state.messageDates == [latest, older])
            #expect(state.messageDateCounts == [latest: 1, older: 1])
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
        await fixture.state.selectConversation(fixture.first)
        let list = StandInTranscriptList(attachedTo: fixture.state.scroller)

        await fixture.state.selectDate(fixture.older)

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

        await fixture.state.selectConversation(fixture.first)
        // Armed: the day the note was written on is the one shown.
        #expect(fixture.state.selectedDate == fixture.latest)
        #expect(fixture.state.notes == [note])
        #expect(fixture.state.timelineItems.last?.id == note.id)

        await fixture.state.selectDate(fixture.older)
        #expect(fixture.state.notes.isEmpty)
    }

    @Test(arguments: [false, true], [false, true])
    func `new conversation wins regardless of detail completion order`(pauseDay: Bool, oldFinishesFirst: Bool) async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let firstGate = await fixture.gates.suspendNext(pauseDay ? .day(fixture.first.id, fixture.latest) : .dates(fixture.first.id))
        let first = Task { await fixture.state.selectConversation(fixture.first) }
        try await firstGate.waitForArrival()
        let secondGate = await fixture.gates.suspendNext(.dates(fixture.second.id))
        let second = Task { await fixture.state.selectConversation(fixture.second) }
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
        let automatic = Task { await fixture.state.selectConversation(fixture.first) }
        try await gate.waitForArrival()
        await fixture.state.selectDate(fixture.older)
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
        let loading = Task { await fixture.state.selectConversation(fixture.first) }
        try await gate.waitForArrival()
        if clearConversation { await fixture.state.selectConversation(nil) } else { await fixture.state.selectDate(nil) }
        await gate.open()
        await loading.value
        #expect(fixture.state.selectedDate == nil)
        #expect(fixture.state.messages.isEmpty)
        #expect(fixture.state.positions.isEmpty)
        #expect(!fixture.state.isLoading)
        if clearConversation {
            #expect(fixture.state.selectedConversation == nil)
            #expect(fixture.state.messageDates.isEmpty)
            #expect(fixture.state.messageDateCounts.isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func `clearing a date invalidates pending date counts`(clearDate: Bool) async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let gate = await fixture.gates.suspendNext(.dates(fixture.first.id))
        let loading = Task { await fixture.state.selectConversation(fixture.first) }
        defer { loading.cancel(); Task { await gate.open() } }
        try await gate.waitForArrival()
        #expect(fixture.state.selectedConversation?.id == fixture.first.id)
        #expect(fixture.state.isLoading)
        if clearDate { await fixture.state.selectDate(nil) }
        await gate.open()
        await loading.value
        if clearDate {
            #expect(fixture.state.selectedDate == nil)
            #expect(fixture.state.messageDates.isEmpty)
            #expect(fixture.state.messageDateCounts.isEmpty)
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
        await fixture.state.selectConversation(fixture.second)
        await gate.open()
        await scope.value
        fixture.assertSelected(fixture.second, on: fixture.latest)
    }

    @Test(arguments: [false, true])
    func `resolved scope supersedes local load but an unmatched scope preserves it`(unmatched: Bool) async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let gate = await fixture.gates.suspendNext(.dates(fixture.first.id))
        let local = Task { await fixture.state.selectConversation(fixture.first) }
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
        await fixture.state.selectConversation(fixture.second)
        await fixture.state.applyScope(request)
        fixture.assertSelected(fixture.second, on: fixture.latest)
    }

    @Test(arguments: [false, true])
    func `stale detail failure cannot clear the current loading owner`(pauseDay: Bool) async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        let oldGate = await fixture.gates.suspendNext(pauseDay ? .day(fixture.first.id, fixture.latest) : .dates(fixture.first.id))
        let old = Task { await fixture.state.selectConversation(fixture.first) }
        try await oldGate.waitForArrival()
        let currentGate = await fixture.gates.suspendNext(.dates(fixture.second.id))
        let current = Task { await fixture.state.selectConversation(fixture.second) }
        try await currentGate.waitForArrival()
        await oldGate.open(failing: true)
        await old.value
        #expect(fixture.state.isLoading)
        #expect(fixture.state.selectedConversation?.id == fixture.second.id)
        await currentGate.open()
        await current.value
        fixture.assertSelected(fixture.second, on: fixture.latest)
        #expect(!fixture.state.isLoading)
    }

    @Test(arguments: [false, true])
    func `search A B A cannot publish the first A after the newest results`(failOldRead: Bool) async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        await fixture.state.selectConversation(fixture.first)
        fixture.state.transcriptSearchText = "alpha"
        let gate = await fixture.gates.suspendNext(.search(fixture.first.id, "alpha"))
        let old = Task { await fixture.state.performTranscriptSearch() }
        try await gate.waitForArrival()
        fixture.state.transcriptSearchText = "beta"
        await fixture.state.performTranscriptSearch()
        #expect(fixture.state.searchMatchDates == [fixture.latest])
        let newMatch = Self.message(conversationID: fixture.first.id, body: "new alpha", timestamp: fixture.latest)
        await fixture.transcripts.mock.addMessage(newMatch)
        fixture.state.transcriptSearchText = " alpha "
        await fixture.state.performTranscriptSearch()
        let newest = fixture.state.searchResults
        #expect(newest.contains(newMatch.id))
        await gate.open(failing: failOldRead)
        await old.value
        #expect(fixture.state.searchResults == newest)
        #expect(fixture.state.searchMatchDates == [fixture.older, fixture.latest])
    }

    @Test(arguments: [false, true])
    func `conversation and query changes invalidate search before replacement work starts`(changeConversation: Bool) async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        await fixture.state.selectConversation(fixture.first)
        fixture.state.transcriptSearchText = "alpha"
        let gate = await fixture.gates.suspendNext(.search(fixture.first.id, "alpha"))
        let old = Task { await fixture.state.performTranscriptSearch() }
        try await gate.waitForArrival()
        if changeConversation { await fixture.state.selectConversation(fixture.second) } else { fixture.state.transcriptSearchText = "" }
        await gate.open()
        await old.value
        #expect(fixture.state.searchResults.isEmpty)
        #expect(fixture.state.searchMatchDates.isEmpty)
    }

    @Test
    func `date selection preserves conversation wide search validity`() async throws {
        let fixture = try RaceFixture()
        await fixture.seed()
        await fixture.state.selectConversation(fixture.first)
        fixture.state.transcriptSearchText = "alpha"
        let gate = await fixture.gates.suspendNext(.search(fixture.first.id, "alpha"))
        let search = Task { await fixture.state.performTranscriptSearch() }
        try await gate.waitForArrival()
        await fixture.state.selectDate(fixture.older)
        await gate.open()
        await search.value
        #expect(fixture.state.searchResults == Set(fixture.state.messages.map(\.id)))
        #expect(fixture.state.searchMatchDates == [fixture.older])
        fixture.assertSelected(fixture.first, on: fixture.older)
    }
}
