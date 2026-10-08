import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoUI

/// A stored history behind gated stores: two accounts, of which the first holds two conversations, and one imported
/// history. `day(_:of:)` numbers the days from the oldest.
///
/// | Day | alice (home)          | bob (home) | carol (work) | dave (imported) |
/// |-----|-----------------------|------------|--------------|-----------------|
/// | 4   |                       | delta      |              |                 |
/// | 3   | alpha three           |            |              |                 |
/// | 2   |                       | gamma      | alpha carol  |                 |
/// | 1   | alpha one, beta, alpha two |       |              | epsilon         |
/// | 0   |                       |            |              | alpha dave      |
@MainActor
struct TranscriptLibraryFixture {
    static let importSource = "old@example.com"
    /// The start of a UTC day.
    private static let firstDay = Date(timeIntervalSince1970: 1_700_006_400)

    let gates: TranscriptReadGates
    let store: GatedTranscriptPersistenceStore
    let transcripts: GatedTranscriptStore
    let state: TranscriptViewerState
    let home: Account
    let work: Account
    let alice: Conversation
    let bob: Conversation
    let carol: Conversation
    let dave: Conversation
    private let messages: [ChatMessage]

    init(searchDelay: Duration = .zero) throws {
        let gates = TranscriptReadGates()
        self.gates = gates
        let store = GatedTranscriptPersistenceStore(gates: gates)
        self.store = store
        let transcripts = GatedTranscriptStore(gates: gates)
        self.transcripts = transcripts
        self.state = TranscriptViewerState(
            environment: AppEnvironment(store: store, transcripts: transcripts, credentialStore: NullCredentialStore()),
            searchDelay: searchDelay
        )
        let home = try Self.account("home@example.com")
        let work = try Self.account("work@example.com")
        self.home = home
        self.work = work
        let alice = try Self.conversation("alice@example.com", accountID: home.id)
        let bob = try Self.conversation("bob@example.com", accountID: home.id)
        let carol = try Self.conversation("carol@example.com", accountID: work.id)
        let dave = try Self.conversation("dave@example.com", importSourceJID: Self.importSource)
        (self.alice, self.bob, self.carol, self.dave) = (alice, bob, carol, dave)
        self.messages = [
            Self.message("alpha one", in: alice, day: 1, second: 10),
            Self.message("beta", in: alice, day: 1, second: 20),
            Self.message("alpha two", in: alice, day: 1, second: 30),
            Self.message("alpha three", in: alice, day: 3),
            Self.message("gamma", in: bob, day: 2),
            Self.message("delta", in: bob, day: 4),
            Self.message("alpha carol", in: carol, day: 2),
            Self.message("alpha dave", in: dave, day: 0),
            Self.message("epsilon", in: dave, day: 1)
        ]
    }

    func seed() async {
        for account in [home, work] {
            await store.mock.addAccount(account)
        }
        for conversation in [alice, bob, carol, dave] {
            await store.mock.addConversation(conversation)
        }
        for message in messages {
            await transcripts.mock.addMessage(message)
        }
    }

    /// The days listed for the first account, newest first.
    var homeDays: [TranscriptDay] {
        [day(4, of: bob), day(3, of: alice), day(2, of: bob), day(1, of: alice)]
    }

    func day(_ index: Int, of conversation: Conversation) -> TranscriptDay {
        TranscriptDay(conversationID: conversation.id, date: Self.date(day: index))
    }

    /// The conversations whose days were listed, in the order they were asked for.
    var listedConversations: [UUID] {
        get async {
            await gates.seen.compactMap { read in
                if case let .dates(conversationID) = read { conversationID } else { nil }
            }
        }
    }

    func id(_ body: String) throws -> UUID {
        try #require(messages.first { $0.body == body }).id
    }

    func scope(_ conversation: Conversation, generation: Int = 1) -> ScopeRequest {
        ScopeRequest(generation: generation, ref: ConversationRef(conversation: conversation))
    }

    /// Waits out the scheduled search and every load it or a setter started.
    func settle() async throws {
        await state.pendingSearch?.value
        try await waitUntil { !state.isLoading }
    }

    private static func date(day index: Int) -> Date {
        firstDay.addingTimeInterval(Double(index) * 24 * 60 * 60)
    }

    private static func account(_ jid: String) throws -> Account {
        try Account(id: UUID(), jid: #require(BareJID.parse(jid)), isEnabled: true, connectOnLaunch: false, createdAt: Date())
    }

    static func conversation(_ jid: String, accountID: UUID? = nil, importSourceJID: String? = nil) throws -> Conversation {
        try Conversation(
            id: UUID(), accountID: accountID, importSourceJID: importSourceJID, jid: #require(BareJID.parse(jid)), type: .chat,
            isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
        )
    }

    private static func message(_ body: String, in conversation: Conversation, day index: Int, second: TimeInterval = 0) -> ChatMessage {
        ChatMessage(
            id: UUID(), conversationID: conversation.id, fromJID: conversation.jid.description, body: body,
            timestamp: date(day: index).addingTimeInterval(second), isOutgoing: false, isDelivered: true, isEdited: false, type: "chat"
        )
    }
}
