import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoUI

@MainActor
struct ChatContainerStateTests {
    private struct Fixture {
        let container: ChatContainerState
        let environment: AppEnvironment
        let store: MockPersistenceStore
        let accountID: UUID
        let accountID2: UUID
    }

    private static func makeFixture() async throws -> Fixture {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let account = try Account(
            id: UUID(),
            jid: #require(BareJID.parse("alice@example.com")),
            isEnabled: true,
            connectOnLaunch: false,
            createdAt: Date()
        )
        let account2 = try Account(
            id: UUID(),
            jid: #require(BareJID.parse("alice@other.example")),
            isEnabled: true,
            connectOnLaunch: false,
            createdAt: Date()
        )
        await store.addAccount(account)
        await store.addAccount(account2)
        let environment = AppEnvironment(
            store: store,
            transcripts: transcripts,
            credentialStore: NullCredentialStore()
        )
        try await environment.accountService.loadAccounts()
        // Focused, as a chat window the user is working in is. The tests about an unfocused window clear it.
        let container = ChatContainerState(environment: environment)
        container.isWindowFocused = true
        return Fixture(
            container: container,
            environment: environment,
            store: store,
            accountID: account.id,
            accountID2: account2.id
        )
    }

    private func key(_ jid: String, _ accountID: UUID) -> ConversationKey {
        ConversationKey(accountID: accountID, jid: jid)
    }

    private struct PruneFixture {
        let container: ChatContainerState
        let environment: AppEnvironment
        let account: Account
        let roomJID: BareJID
        let roomJIDString = "room@conference.example.com"
    }

    /// Builds a container with a single groupchat conversation seeded in the store,
    /// for the `pruneClosedConversations` tests.
    private static func makePruneFixture() async throws -> PruneFixture {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let account = try Account(
            id: UUID(),
            jid: #require(BareJID.parse("alice@example.com")),
            isEnabled: true,
            connectOnLaunch: false,
            createdAt: Date()
        )
        await store.addAccount(account)
        let roomJID = try #require(BareJID.parse("room@conference.example.com"))
        await store.addConversation(Conversation(
            id: UUID(),
            accountID: account.id,
            jid: roomJID,
            type: .groupchat,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        ))
        let environment = AppEnvironment(store: store, transcripts: transcripts, credentialStore: NullCredentialStore())
        try await environment.accountService.loadAccounts()
        return PruneFixture(
            container: ChatContainerState(environment: environment),
            environment: environment,
            account: account,
            roomJID: roomJID
        )
    }

    /// Opens a tab and drains `open()`'s background load Task: it polls until the
    /// tab's conversation resolves, so a later destroy can't race the in-flight
    /// `findOrCreateConversation` (which would otherwise recreate the row).
    private func openAndAwaitLoad(_ container: ChatContainerState, _ jid: String, _ accountID: UUID) async {
        container.open(jid, accountID: accountID)
        for _ in 0 ..< 1000 {
            if container.state(for: key(jid, accountID))?.conversation != nil { return }
            await Task.yield()
        }
        Issue.record("tab \(jid) did not finish loading within budget")
    }

    /// Gives an activation that was scheduled the turns it needs, before a test asserts that none happened.
    private func letScheduledActivationsRun() async {
        for _ in 0 ..< 200 {
            await Task.yield()
        }
    }

    @Test func `open appends a tab and selects it`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID

        container.open("bob@example.com", accountID: id)

        #expect(container.orderedTabs == [key("bob@example.com", id)])
        #expect(container.selectedKey == key("bob@example.com", id))
        #expect(container.hasTabs)
    }

    @Test func `opening an already-open chat selects its existing tab without duplicating`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID

        container.open("bob@example.com", accountID: id)
        container.open("carol@example.com", accountID: id)
        container.open("bob@example.com", accountID: id)

        #expect(container.orderedTabs == [key("bob@example.com", id), key("carol@example.com", id)])
        #expect(container.selectedKey == key("bob@example.com", id))
    }

    @Test func `close removes a tab and selects a neighbor`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID
        container.open("a@example.com", accountID: id)
        container.open("b@example.com", accountID: id)
        container.open("c@example.com", accountID: id)

        // Closing the middle tab while it is selected picks the tab that shifts into its slot.
        container.select(key("b@example.com", id))
        container.close(key("b@example.com", id))
        #expect(container.orderedTabs == [key("a@example.com", id), key("c@example.com", id)])
        #expect(container.selectedKey == key("c@example.com", id))

        // Closing the last tab picks the new last.
        container.select(key("c@example.com", id))
        container.close(key("c@example.com", id))
        #expect(container.orderedTabs == [key("a@example.com", id)])
        #expect(container.selectedKey == key("a@example.com", id))
    }

    @Test func `closing the final tab yields an empty container`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID
        container.open("solo@example.com", accountID: id)

        container.close(key("solo@example.com", id))

        #expect(container.orderedTabs.isEmpty)
        #expect(container.selectedKey == nil)
        #expect(!container.hasTabs)
        #expect(container.selectedState == nil)
    }

    @Test func `next and previous tab wrap at both ends`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID
        container.open("a@example.com", accountID: id)
        container.open("b@example.com", accountID: id)
        container.open("c@example.com", accountID: id)

        container.selectNextTab()
        #expect(container.selectedKey == key("a@example.com", id))
        container.selectNextTab()
        #expect(container.selectedKey == key("b@example.com", id))

        container.selectPreviousTab()
        #expect(container.selectedKey == key("a@example.com", id))
        container.selectPreviousTab()
        #expect(container.selectedKey == key("c@example.com", id))
    }

    @Test func `tab cycling is a no-op with one tab`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID
        container.open("solo@example.com", accountID: id)

        container.selectNextTab()
        container.selectPreviousTab()

        #expect(container.selectedKey == key("solo@example.com", id))
    }

    @Test func `closeAll empties the tabs and clears the selection`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID
        container.open("a@example.com", accountID: id)
        container.open("b@example.com", accountID: id)

        container.closeAll()

        #expect(container.orderedTabs.isEmpty)
        #expect(container.selectedKey == nil)
        #expect(container.state(for: key("a@example.com", id)) == nil)
    }

    @Test func `tab cycling pauses while the New Chat sheet or the file importer is up`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID
        container.open("a@example.com", accountID: id)
        #expect(!container.canCycleTabs)
        container.open("b@example.com", accountID: id)
        #expect(container.canCycleTabs)

        container.newChat()
        #expect(!container.canCycleTabs)
        container.isShowingNewChat = false

        container.selectedState?.showFileImporter()
        #expect(!container.canCycleTabs)
    }

    @Test func `switching tabs drops the outgoing tab's file importer request`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID
        container.open("a@example.com", accountID: id)
        let stateA = try #require(container.state(for: key("a@example.com", id)))
        stateA.showFileImporter()

        // Opening another chat from outside the chat window moves the selection past the open picker.
        container.open("b@example.com", accountID: id)

        #expect(!stateA.isShowingFileImporter)
    }

    @Test func `a background tab finishing its load leaves the selected tab active`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let chatService = fixture.environment.chatService
        let id = fixture.accountID

        // Hold A's load in its conversation upsert while B opens, loads, and activates.
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        await fixture.store.installConversationWriteGate(entered: entered, release: release)
        container.open("a@example.com", accountID: id)
        let stateA = try #require(container.state(for: key("a@example.com", id)))
        await entered.wait()
        await openAndAwaitLoad(container, "b@example.com", id)
        let conversationB = try #require(container.state(for: key("b@example.com", id))?.conversation)
        try await waitUntil { chatService.activeConversationID == conversationB.id }

        await release.signal()
        try await waitUntil { stateA.conversation != nil && !stateA.isLoading }

        #expect(chatService.activeConversationID == conversationB.id)
    }

    @Test func `a tab re-selected while loading becomes active once its load finishes`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let chatService = fixture.environment.chatService
        let id = fixture.accountID

        // Hold A's load in its conversation upsert, then move on to B, which loads and activates.
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        await fixture.store.installConversationWriteGate(entered: entered, release: release)
        container.open("a@example.com", accountID: id)
        let stateA = try #require(container.state(for: key("a@example.com", id)))
        await entered.wait()
        await openAndAwaitLoad(container, "b@example.com", id)
        let conversationB = try #require(container.state(for: key("b@example.com", id))?.conversation)
        try await waitUntil { chatService.activeConversationID == conversationB.id }

        // Back on A before its conversation exists: `select` can't activate it, so A's own load must.
        container.select(key("a@example.com", id))
        await release.signal()
        try await waitUntil { stateA.conversation != nil && !stateA.isLoading }

        #expect(chatService.activeConversationID == stateA.conversation?.id)
    }

    @Test func `a tab closed while loading never becomes the active conversation`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let chatService = fixture.environment.chatService
        let id = fixture.accountID
        await openAndAwaitLoad(container, "a@example.com", id)
        let conversationA = try #require(container.state(for: key("a@example.com", id))?.conversation)
        try await waitUntil { chatService.activeConversationID == conversationA.id }

        // Hold B's load in its conversation upsert.
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        await fixture.store.installConversationWriteGate(entered: entered, release: release)
        container.open("b@example.com", accountID: id)
        let stateB = try #require(container.state(for: key("b@example.com", id)))
        await entered.wait()

        container.closeAll()
        try await waitUntil { chatService.activeConversationID == nil }

        await release.signal()
        try await waitUntil { stateB.conversation != nil && !stateB.isLoading }

        #expect(chatService.activeConversationID == nil)
    }

    @Test func `the selected tab is the active conversation only while the chat window is focused`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let chatService = fixture.environment.chatService
        let id = fixture.accountID
        await openAndAwaitLoad(container, "a@example.com", id)
        let conversationA = try #require(container.state(for: key("a@example.com", id))?.conversation)
        try await waitUntil { chatService.activeConversationID == conversationA.id }

        container.isWindowFocused = false
        try await waitUntil { chatService.activeConversationID == nil }

        container.isWindowFocused = true
        try await waitUntil { chatService.activeConversationID == conversationA.id }
    }

    @Test func `closing the selected tab of an unfocused chat window activates no other`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let chatService = fixture.environment.chatService
        let id = fixture.accountID
        await openAndAwaitLoad(container, "a@example.com", id)
        await openAndAwaitLoad(container, "b@example.com", id)
        let conversationB = try #require(container.state(for: key("b@example.com", id))?.conversation)
        try await waitUntil { chatService.activeConversationID == conversationB.id }
        container.isWindowFocused = false
        try await waitUntil { chatService.activeConversationID == nil }

        container.close(key("b@example.com", id))
        // Armed: the neighbor took the selection, so only the window's focus stands between it and activation.
        #expect(container.selectedKey == key("a@example.com", id))
        await letScheduledActivationsRun()

        #expect(chatService.activeConversationID == nil)
    }

    @Test func `a tab opened in an unfocused chat window becomes active once the window is focused`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let chatService = fixture.environment.chatService
        let id = fixture.accountID
        container.isWindowFocused = false

        await openAndAwaitLoad(container, "a@example.com", id)
        let stateA = try #require(container.state(for: key("a@example.com", id)))
        try await waitUntil { !stateA.isLoading }
        #expect(chatService.activeConversationID == nil)

        container.isWindowFocused = true
        try await waitUntil { chatService.activeConversationID == stateA.conversation?.id }
    }

    @Test func `a tab opened in the background leaves the selected tab and the active conversation alone`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let chatService = fixture.environment.chatService
        let id = fixture.accountID
        await openAndAwaitLoad(container, "a@example.com", id)
        let conversationA = try #require(container.state(for: key("a@example.com", id))?.conversation)
        try await waitUntil { chatService.activeConversationID == conversationA.id }

        container.openInBackground("b@example.com", accountID: id)
        let stateB = try #require(container.state(for: key("b@example.com", id)))
        try await waitUntil { stateB.conversation != nil && !stateB.isLoading }

        #expect(container.orderedTabs == [key("a@example.com", id), key("b@example.com", id)])
        #expect(container.selectedKey == key("a@example.com", id))
        #expect(chatService.activeConversationID == conversationA.id)
    }

    @Test func `a tab opened in the background is selected when it is the only one`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID

        container.openInBackground("a@example.com", accountID: id)
        container.openInBackground("a@example.com", accountID: id)

        #expect(container.orderedTabs == [key("a@example.com", id)])
        #expect(container.selectedKey == key("a@example.com", id))
    }

    @Test func `a further message for a tab open in the background leaves the selection alone`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID
        await openAndAwaitLoad(container, "a@example.com", id)
        container.openInBackground("b@example.com", accountID: id)

        container.openInBackground("b@example.com", accountID: id)

        #expect(container.orderedTabs == [key("a@example.com", id), key("b@example.com", id)])
        #expect(container.selectedKey == key("a@example.com", id))
    }

    @Test func `a chat window opening on its own is not in view, even while it has the keyboard`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let chatService = fixture.environment.chatService
        let id = fixture.accountID
        container.isWindowFocused = false
        container.isOpeningQuietly = true

        // The window has the keyboard for a moment, both while its tab loads and after.
        container.isWindowFocused = true
        container.openInBackground("a@example.com", accountID: id)
        let stateA = try #require(container.state(for: key("a@example.com", id)))
        try await waitUntil { stateA.conversation != nil && !stateA.isLoading }
        container.isWindowFocused = false
        container.isWindowFocused = true
        // Armed: the tab is selected and loaded in a focused window, so only the quiet opening keeps it inactive.
        #expect(container.selectedKey == key("a@example.com", id))
        await letScheduledActivationsRun()
        #expect(chatService.activeConversationID == nil)

        // The user goes to the window, which ends the quiet opening.
        container.isOpeningQuietly = false
        try await waitUntil { chatService.activeConversationID == stateA.conversation?.id }
    }

    @Test func `a quiet opening that ends behind another window leaves the chat inactive`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let chatService = fixture.environment.chatService
        let id = fixture.accountID
        container.isWindowFocused = false
        container.isOpeningQuietly = true
        container.openInBackground("a@example.com", accountID: id)
        let stateA = try #require(container.state(for: key("a@example.com", id)))
        try await waitUntil { stateA.conversation != nil && !stateA.isLoading }

        container.isOpeningQuietly = false
        await letScheduledActivationsRun()

        #expect(chatService.activeConversationID == nil)
    }

    @Test func `draft text is retained per tab across switches`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID
        container.open("bob@example.com", accountID: id)
        container.state(for: key("bob@example.com", id))?.draftText = "half-typed"

        container.open("carol@example.com", accountID: id)
        #expect(container.state(for: key("carol@example.com", id))?.draftText == "")

        container.select(key("bob@example.com", id))
        #expect(container.state(for: key("bob@example.com", id))?.draftText == "half-typed")
    }

    @Test func `a MUC PM is a distinct tab from its room`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID

        container.open("room@conference.example.com", accountID: id)
        container.open("room@conference.example.com/nick", accountID: id)

        #expect(container.orderedTabs.count == 2)
        #expect(container.orderedTabs.contains(key("room@conference.example.com", id)))
        #expect(container.orderedTabs.contains(key("room@conference.example.com/nick", id)))
        #expect(container.state(for: key("room@conference.example.com", id))
            !== container.state(for: key("room@conference.example.com/nick", id)))
    }

    @Test func `same JID under two accounts opens two distinct tabs`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id1 = fixture.accountID
        let id2 = fixture.accountID2

        container.open("bob@example.com", accountID: id1)
        container.open("bob@example.com", accountID: id2)

        #expect(container.orderedTabs.count == 2)
        #expect(container.orderedTabs.contains(key("bob@example.com", id1)))
        #expect(container.orderedTabs.contains(key("bob@example.com", id2)))
        #expect(container.state(for: key("bob@example.com", id1))
            !== container.state(for: key("bob@example.com", id2)))
    }

    @Test func `same JID opened twice under the same account is one tab`() async throws {
        let fixture = try await Self.makeFixture()
        let container = fixture.container
        let id = fixture.accountID

        container.open("bob@example.com", accountID: id)
        container.open("bob@example.com", accountID: id)

        #expect(container.orderedTabs == [key("bob@example.com", id)])
    }

    @Test func `pruneClosedConversations closes a tab whose conversation was deleted`() async throws {
        let fixture = try await Self.makePruneFixture()
        let container = fixture.container
        let id = fixture.account.id
        let peerJIDString = "bob@example.com"
        await openAndAwaitLoad(container, fixture.roomJIDString, id)
        await openAndAwaitLoad(container, peerJIDString, id)
        #expect(container.orderedTabs.count == 2)

        // Destroying the room removes it from the service's `openConversations`.
        await fixture.environment.chatService.handleEvent(
            .roomDestroyed(room: fixture.roomJID, reason: nil, alternateVenue: nil),
            accountID: id
        )
        container.pruneClosedConversations()

        // The room tab is gone; the still-live 1:1 tab stays.
        #expect(container.orderedTabs == [key(peerJIDString, id)])
        #expect(container.state(for: key(fixture.roomJIDString, id)) == nil)
    }

    @Test func `pruneClosedConversations closing the selected tab selects a neighbor`() async throws {
        let fixture = try await Self.makePruneFixture()
        let container = fixture.container
        let id = fixture.account.id
        let peerJIDString = "bob@example.com"
        await openAndAwaitLoad(container, fixture.roomJIDString, id)
        await openAndAwaitLoad(container, peerJIDString, id)
        container.select(key(fixture.roomJIDString, id))
        #expect(container.selectedKey == key(fixture.roomJIDString, id))

        await fixture.environment.chatService.handleEvent(
            .roomDestroyed(room: fixture.roomJID, reason: nil, alternateVenue: nil),
            accountID: id
        )
        container.pruneClosedConversations()

        // The selected room tab is pruned; selection falls to the surviving tab.
        #expect(container.orderedTabs == [key(peerJIDString, id)])
        #expect(container.selectedKey == key(peerJIDString, id))
    }

    @Test func `pruneClosedConversations leaves a still-loading tab alone`() async throws {
        let fixture = try await Self.makePruneFixture()
        let container = fixture.container
        let id = fixture.account.id

        // `open` loads on a background Task; pruning synchronously — before any
        // await lets that load run — sees a nil conversation and must NOT close
        // the freshly opened tab (it isn't in `openConversations` yet).
        container.open(fixture.roomJIDString, accountID: id)
        #expect(container.state(for: key(fixture.roomJIDString, id))?.conversation == nil)
        container.pruneClosedConversations()
        #expect(container.orderedTabs == [key(fixture.roomJIDString, id)])
    }
}
