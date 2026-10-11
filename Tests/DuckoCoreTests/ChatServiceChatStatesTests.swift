import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let testAccountID = UUID()
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!

@MainActor
private func makeChatService(store: MockPersistenceStore, transcripts: MockTranscriptStore) -> ChatService {
    ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
}

// MARK: - Tests

enum ChatServiceChatStatesTests {
    struct TypingState {
        @Test
        @MainActor
        func `Chat state event updates typingStates`() async {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = makeChatService(store: store, transcripts: transcripts)

            await service.handleEvent(
                .chatStateChanged(from: contactJID, state: .composing),
                accountID: testAccountID
            )

            #expect(service.typingStates[testAccountID]?[contactJID] == .composing)
        }

        @Test
        @MainActor
        func `Active state replaces composing`() async {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = makeChatService(store: store, transcripts: transcripts)

            await service.handleEvent(
                .chatStateChanged(from: contactJID, state: .composing),
                accountID: testAccountID
            )
            #expect(service.typingStates[testAccountID]?[contactJID] == .composing)

            await service.handleEvent(
                .chatStateChanged(from: contactJID, state: .active),
                accountID: testAccountID
            )
            #expect(service.typingStates[testAccountID]?[contactJID] == .active)
        }

        @Test
        @MainActor
        func `typing ends once the contact's last session goes offline, not before`() async throws {
            let environment = AppEnvironment(store: MockPersistenceStore(), transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore())
            // Each event reaches both services, in the order the environment's dispatch hands it to them.
            func deliver(_ event: XMPPEvent) async {
                await environment.chatService.handleEvent(event, accountID: testAccountID)
                await environment.presenceService.handleEvent(event, accountID: testAccountID)
            }
            let laptop = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "laptop")))
            let phone = try JID.full(#require(FullJID(bareJID: contactJID, resourcePart: "phone")))
            await deliver(.presenceUpdated(from: laptop, presence: XMPPPresence()))
            await deliver(.presenceUpdated(from: phone, presence: XMPPPresence()))
            await deliver(.chatStateChanged(from: contactJID, state: .composing))

            // The phone going away leaves the laptop, which may be the one typing and would not say so again.
            await deliver(.presenceUpdated(from: phone, presence: XMPPPresence(type: .unavailable)))
            #expect(environment.chatService.isPartnerTyping(jidString: contactJID.description, accountID: testAccountID))

            await deliver(.presenceUpdated(from: laptop, presence: XMPPPresence(type: .unavailable)))
            #expect(!environment.chatService.isPartnerTyping(jidString: contactJID.description, accountID: testAccountID))
        }
    }
}
