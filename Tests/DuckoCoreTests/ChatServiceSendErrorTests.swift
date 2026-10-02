import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private struct TestError: Error {}

private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!
private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

private func makeTranscripts() -> MockTranscriptStore {
    MockTranscriptStore()
}

@MainActor
private func makeChatService(store: MockPersistenceStore, transcripts: MockTranscriptStore) -> ChatService {
    ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
}

// MARK: - Tests

enum ChatServiceSendErrorTests {
    struct SendMessageRollback {
        @Test
        @MainActor
        func `sendMessage failure appends retract amendment and throws`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let credentials = MockCredentialStore()
            let transport = MockTransport()
            let factory = MockXMPPClientFactory(transport: transport, modules: [ChatModule()])
            let accountService = makeAccountService(store: store, credentials: credentials, clientFactory: factory)
            let chatService = makeChatService(store: store, transcripts: transcripts)
            chatService.setAccountService(accountService)

            let connectTask = Task { @MainActor in
                try await accountService.createAndConnect(
                    jidString: testJIDString, password: "secret",
                    host: "example.com", port: 5222
                )
            }
            await simulateNoTLSConnect(transport)
            let accountID = try await connectTask.value

            let conversation = try await chatService.openConversation(for: contactJID, accountID: accountID)
            await chatService.selectConversation(conversation.id, accountID: accountID)

            await transport.simulateSendFailure(TestError())

            await #expect(throws: TestError.self) {
                try await chatService.sendMessage(to: contactJID, body: "hi", accountID: accountID)
            }

            let persistedMessages = await transcripts.messages
            let stanzaID = try #require(persistedMessages.last?.stanzaID)

            let amendments = await transcripts.amendments
            #expect(amendments.count == 1)
            #expect(amendments.first?.amendment.action == .retract)
            #expect(amendments.first?.amendment.targetStanzaID == stanzaID)
            #expect(amendments.first?.conversationID == conversation.id)

            // The active conversation reload applies the retract amendment to the
            // visible message: it stays in the list but `isRetracted` flips and
            // `body` is cleared. (The mock transcript store mirrors the real
            // amendment-application semantics.)
            #expect(chatService.messages.count == 1)
            #expect(chatService.messages.first?.isRetracted == true)
            #expect(chatService.messages.first?.body.isEmpty == true)

            await accountService.disconnect(accountID: accountID)
        }
    }

    struct SendWithAttachment {
        @Test
        @MainActor
        func `A sent file's message keeps its attachment and tells other clients about it`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let transport = MockTransport()
            let factory = MockXMPPClientFactory(transport: transport, modules: [ChatModule()])
            let accountService = makeAccountService(store: store, credentials: MockCredentialStore(), clientFactory: factory)
            let chatService = makeChatService(store: store, transcripts: transcripts)
            chatService.setAccountService(accountService)

            let connectTask = Task { @MainActor in
                try await accountService.createAndConnect(
                    jidString: testJIDString, password: "secret",
                    host: "example.com", port: 5222
                )
            }
            await simulateNoTLSConnect(transport)
            let accountID = try await connectTask.value

            let link = "https://upload.example.com/photo.png"
            let attachment = Attachment(id: UUID(), url: link, mimeType: "image/png", fileName: "photo.png", fileSize: 12)
            try await chatService.sendMessage(to: contactJID, body: link, accountID: accountID, attachments: [attachment])

            // Without the attachment the sender's own row is a bare link, while the recipient is told it is a file.
            let persisted = try #require(await transcripts.messages.last)
            #expect(persisted.attachments.map(\.url) == [link])
            #expect(persisted.bodyIsAttachmentLink)
            let sent = await String(decoding: transport.sentBytes.last ?? [], as: UTF8.self)
            #expect(sent.contains("<x xmlns=\"jabber:x:oob\"><url>\(link)</url></x>"))

            await accountService.disconnect(accountID: accountID)
        }
    }

    struct GroupSendRollback {
        /// Pre-creates the room conversation with encryption disabled so `sendGroupMessage` takes the
        /// plaintext path (no OMEMO members to resolve).
        @MainActor
        private func seedPlaintextRoom(_ store: MockPersistenceStore, accountID: UUID) async throws -> Conversation {
            let conversation = Conversation(
                id: UUID(), accountID: accountID, jid: roomJID, type: .groupchat,
                isPinned: false, isMuted: false, unreadCount: 0,
                roomNickname: "alice", encryptionEnabled: false, createdAt: Date()
            )
            try await store.upsertConversation(conversation)
            return conversation
        }

        @Test
        @MainActor
        func `sendGroupMessage failure appends retract amendment and throws`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let transport = MockTransport()
            let factory = MockXMPPClientFactory(transport: transport, modules: [MUCModule()])
            let accountService = makeAccountService(store: store, clientFactory: factory)
            let chatService = makeChatService(store: store, transcripts: transcripts)
            chatService.setAccountService(accountService)

            let connectTask = Task { @MainActor in
                try await accountService.createAndConnect(
                    jidString: testJIDString, password: "secret", host: "example.com", port: 5222
                )
            }
            await simulateNoTLSConnect(transport)
            let accountID = try await connectTask.value

            let conversation = try await seedPlaintextRoom(store, accountID: accountID)
            await chatService.selectConversation(conversation.id, accountID: accountID)

            await transport.simulateSendFailure(TestError())

            await #expect(throws: TestError.self) {
                try await chatService.sendGroupMessage(to: roomJID, body: "hi room", accountID: accountID)
            }

            let persistedMessages = await transcripts.messages
            #expect(persistedMessages.count == 1)
            let stanzaID = try #require(persistedMessages.last?.stanzaID)

            let amendments = await transcripts.amendments
            #expect(amendments.count == 1)
            #expect(amendments.first?.amendment.action == .retract)
            #expect(amendments.first?.amendment.targetStanzaID == stanzaID)
            #expect(amendments.first?.conversationID == conversation.id)

            #expect(chatService.messages.count == 1)
            #expect(chatService.messages.first?.isRetracted == true)
            #expect(chatService.messages.first?.body.isEmpty == true)

            await accountService.disconnect(accountID: accountID)
        }

        @Test
        @MainActor
        func `sendGroupMessage success persists exactly once with no amendment`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let transport = MockTransport()
            let factory = MockXMPPClientFactory(transport: transport, modules: [MUCModule()])
            let accountService = makeAccountService(store: store, clientFactory: factory)
            let chatService = makeChatService(store: store, transcripts: transcripts)
            chatService.setAccountService(accountService)

            let connectTask = Task { @MainActor in
                try await accountService.createAndConnect(
                    jidString: testJIDString, password: "secret", host: "example.com", port: 5222
                )
            }
            await simulateNoTLSConnect(transport)
            let accountID = try await connectTask.value

            let conversation = try await seedPlaintextRoom(store, accountID: accountID)
            await chatService.selectConversation(conversation.id, accountID: accountID)

            try await chatService.sendGroupMessage(to: roomJID, body: "hello", accountID: accountID)

            let persistedMessages = await transcripts.messages
            #expect(persistedMessages.count == 1)
            #expect(persistedMessages.first?.isOutgoing == true)
            #expect(persistedMessages.first?.body == "hello")
            let amendments = await transcripts.amendments
            #expect(amendments.isEmpty)

            await accountService.disconnect(accountID: accountID)
        }

        @Test
        @MainActor
        func `sendGroupMessage to an encrypted room resolves encryption before persist, so a failure persists nothing`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let transport = MockTransport()
            let factory = MockXMPPClientFactory(transport: transport, modules: [MUCModule()])
            let accountService = makeAccountService(store: store, clientFactory: factory)
            let chatService = makeChatService(store: store, transcripts: transcripts)
            chatService.setAccountService(accountService)
            // OMEMOService is deliberately not wired, so encryption resolution fails closed.

            let connectTask = Task { @MainActor in
                try await accountService.createAndConnect(
                    jidString: testJIDString, password: "secret", host: "example.com", port: 5222
                )
            }
            await simulateNoTLSConnect(transport)
            let accountID = try await connectTask.value

            // Encryption enabled but no OMEMO service → `prepareGroupMessage` throws before any persist.
            let conversation = Conversation(
                id: UUID(), accountID: accountID, jid: roomJID, type: .groupchat,
                isPinned: false, isMuted: false, unreadCount: 0,
                roomNickname: "alice", encryptionEnabled: true, createdAt: Date()
            )
            try await store.upsertConversation(conversation)
            await chatService.selectConversation(conversation.id, accountID: accountID)

            await #expect(throws: ChatService.ChatServiceError.self) {
                try await chatService.sendGroupMessage(to: roomJID, body: "secret", accountID: accountID)
            }

            // The throw happened before persist, so nothing was written and no rollback amendment was needed.
            let persisted = await transcripts.messages
            #expect(persisted.isEmpty)
            let amendments = await transcripts.amendments
            #expect(amendments.isEmpty)

            await accountService.disconnect(accountID: accountID)
        }
    }

    struct MUCPrivateMessageRollback {
        @Test
        @MainActor
        func `sendMUCPrivateMessage failure appends retract amendment and throws`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let transport = MockTransport()
            let factory = MockXMPPClientFactory(transport: transport, modules: [MUCModule()])
            let accountService = makeAccountService(store: store, clientFactory: factory)
            let chatService = makeChatService(store: store, transcripts: transcripts)
            chatService.setAccountService(accountService)

            let connectTask = Task { @MainActor in
                try await accountService.createAndConnect(
                    jidString: testJIDString, password: "secret", host: "example.com", port: 5222
                )
            }
            await simulateNoTLSConnect(transport)
            let accountID = try await connectTask.value

            let conversation = try await chatService.openMUCPMConversation(
                roomJIDString: roomJID.description, nickname: "bob", accountID: accountID
            )
            await chatService.selectConversation(conversation.id, accountID: accountID)

            await transport.simulateSendFailure(TestError())

            await #expect(throws: TestError.self) {
                try await chatService.sendMUCPrivateMessage(
                    roomJIDString: roomJID.description, nickname: "bob", body: "pm", accountID: accountID
                )
            }

            let persistedMessages = await transcripts.messages
            #expect(persistedMessages.count == 1)
            let stanzaID = try #require(persistedMessages.last?.stanzaID)

            let amendments = await transcripts.amendments
            #expect(amendments.count == 1)
            #expect(amendments.first?.amendment.action == .retract)
            #expect(amendments.first?.amendment.targetStanzaID == stanzaID)
            #expect(amendments.first?.conversationID == conversation.id)

            #expect(chatService.messages.count == 1)
            #expect(chatService.messages.first?.isRetracted == true)
            #expect(chatService.messages.first?.body.isEmpty == true)

            await accountService.disconnect(accountID: accountID)
        }
    }
}
