import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoUI

/// One chat tab's state over in-memory stores, with its account and conversation in place.
@MainActor
struct ChatWindowFixture {
    static let jidString = "bob@example.com"

    let windowState: ChatWindowState
    let environment: AppEnvironment
    let store: MockPersistenceStore
    let transcripts: MockTranscriptStore
    let accountID: UUID
    let conversationID: UUID

    /// `loads: false` leaves `load()` to the test, for the tests about what happens during it.
    static func make(
        jidString: String = jidString,
        type: Conversation.ConversationType = .chat,
        linkPreviewFetcher: any LinkPreviewFetcher = NoOpLinkPreviewFetcher(),
        clientFactory: any XMPPClientFactory = DefaultXMPPClientFactory(),
        loads: Bool = true
    ) async throws -> ChatWindowFixture {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let jid = try #require(BareJID.parse(jidString))
        let aliceJID = try #require(BareJID.parse("alice@example.com"))
        let account = Account(
            id: UUID(),
            jid: aliceJID,
            isEnabled: true,
            connectOnLaunch: false,
            createdAt: Date()
        )
        await store.addAccount(account)
        let conversation = Conversation(
            id: UUID(),
            accountID: account.id,
            jid: jid,
            type: type,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        )
        await store.addConversation(conversation)
        let environment = AppEnvironment(
            store: store,
            transcripts: transcripts,
            credentialStore: NullCredentialStore(),
            linkPreviewFetcher: linkPreviewFetcher,
            clientFactory: clientFactory
        )
        try await environment.accountService.loadAccounts()
        let windowState = ChatWindowState(jidString: jidString, accountID: account.id, environment: environment)
        if loads {
            await windowState.load()
        }
        return ChatWindowFixture(
            windowState: windowState, environment: environment, store: store, transcripts: transcripts,
            accountID: account.id, conversationID: conversation.id
        )
    }
}
