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

private let contactPhone = JID.full(FullJID(bareJID: contactJID, resourcePart: "phone")!)
private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

/// A chat service whose account is connected over `transport`, so what it sends can be read off the wire.
@MainActor
private struct ConnectedChat {
    let store: MockPersistenceStore
    let transcripts: MockTranscriptStore
    let chatService: ChatService
    let accountService: AccountService
    let transport: MockTransport
    let accountID: UUID

    static func make() async throws -> ConnectedChat {
        let store = MockPersistenceStore()
        let transport = MockTransport()
        let factory = MockXMPPClientFactory(transport: transport, modules: [ChatModule(), ChatStatesModule(), MUCModule()])
        let accountService = makeAccountService(store: store, clientFactory: factory)
        let transcripts = MockTranscriptStore()
        let chatService = makeChatService(store: store, transcripts: transcripts)
        chatService.setAccountService(accountService)
        let connectTask = Task { @MainActor in
            try await accountService.createAndConnect(jidString: testJIDString, password: "secret", host: "example.com", port: 5222)
        }
        await simulateNoTLSConnect(transport)
        let accountID = try await connectTask.value
        return ConnectedChat(
            store: store, transcripts: transcripts, chatService: chatService, accountService: accountService, transport: transport, accountID: accountID
        )
    }

    func typing(in jid: BareJID, occupantNickname: String? = nil) async {
        await chatService.userIsTyping(in: jid, occupantNickname: occupantNickname, accountID: accountID)
    }

    func receive(_ event: XMPPEvent) async {
        await chatService.handleEvent(event, accountID: accountID)
    }

    func sent(containing fragment: String) async -> [String] {
        await transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }.filter { $0.contains(fragment) }
    }

    func disconnect() async {
        await accountService.disconnect(accountID: accountID)
    }
}

/// A message `from` sent with a body and no chat state.
private func contentMessage(from: JID, isRoomPrivate: Bool = false) -> XMPPMessage {
    var message = XMPPMessage(type: .chat, to: .bare(BareJID.parse(testJIDString)!), id: UUID().uuidString)
    message.from = from
    message.body = "hi"
    if isRoomPrivate {
        message.element.addChild(DuckoXMPP.XMLElement(name: "x", namespace: XMPPNamespaces.mucUser))
    }
    return message
}

private func occupant(_ nickname: String) -> FullJID {
    FullJID(bareJID: roomJID, resourcePart: nickname)!
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
                .chatStateChanged(from: .bare(contactJID), state: .composing, messageType: .chat),
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
                .chatStateChanged(from: .bare(contactJID), state: .composing, messageType: .chat),
                accountID: testAccountID
            )
            #expect(service.typingStates[testAccountID]?[contactJID] == .composing)

            await service.handleEvent(
                .chatStateChanged(from: .bare(contactJID), state: .active, messageType: .chat),
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
            await deliver(.chatStateChanged(from: .bare(contactJID), state: .composing, messageType: .chat))

            // The phone going away leaves the laptop, which may be the one typing and would not say so again.
            await deliver(.presenceUpdated(from: phone, presence: XMPPPresence(type: .unavailable)))
            #expect(environment.chatService.isPartnerTyping(jidString: contactJID.description, accountID: testAccountID))

            await deliver(.presenceUpdated(from: laptop, presence: XMPPPresence(type: .unavailable)))
            #expect(!environment.chatService.isPartnerTyping(jidString: contactJID.description, accountID: testAccountID))
        }
    }

    struct Outgoing {
        @Test
        @MainActor
        func `Two keystrokes send one composing`() async throws {
            let chat = try await ConnectedChat.make()

            await chat.typing(in: contactJID)
            await chat.typing(in: contactJID)

            #expect(await chat.sent(containing: "<composing").count == 1)
            await chat.disconnect()
        }

        @Test
        @MainActor
        func `Typing again after a message sends composing again`() async throws {
            let chat = try await ConnectedChat.make()

            await chat.typing(in: contactJID)
            try await chat.chatService.sendMessage(to: contactJID, body: "hello", accountID: chat.accountID)
            await chat.typing(in: contactJID)

            #expect(await chat.sent(containing: "<composing").count == 2)
            await chat.disconnect()
        }

        @Test
        @MainActor
        func `No paused follows a sent message`() async throws {
            let chat = try await ConnectedChat.make()

            await chat.typing(in: contactJID)
            try await chat.chatService.sendMessage(to: contactJID, body: "hello", accountID: chat.accountID)
            // A pause still pending would send `paused` once it runs out.
            for task in chat.chatService.takePendingTasks() {
                await task.value
            }

            #expect(await chat.sent(containing: "<paused").isEmpty)
            await chat.disconnect()
        }

        enum Retraction: CaseIterable {
            case chat, privateChat
        }

        /// A retraction is a content message, so it carries `<active/>` wherever chat states go.
        @Test(arguments: Retraction.allCases, [false, true])
        @MainActor
        func `A retraction carries active unless its peer sends no chat states`(_ kind: Retraction, peerSendsNone: Bool) async throws {
            let chat = try await ConnectedChat.make()
            switch kind {
            case .chat:
                try await chat.chatService.sendMessage(to: contactJID, body: "hello", accountID: chat.accountID)
                if peerSendsNone { await chat.receive(.messageReceived(contentMessage(from: contactPhone))) }
                let sent = try #require(await chat.transcripts.messages.first { $0.isOutgoing })
                let conversation = try await chat.chatService.openConversation(for: contactJID, accountID: chat.accountID)
                try await chat.chatService.retractMessage(sent, in: conversation, accountID: chat.accountID)
            case .privateChat:
                let privateChat = try await chat.chatService.openMUCPMConversation(roomJIDString: roomJID.description, nickname: "bob", accountID: chat.accountID)
                try await chat.chatService.sendMessage("hello", in: privateChat, accountID: chat.accountID)
                if peerSendsNone { await chat.receive(.mucPrivateMessageReceived(contentMessage(from: .full(occupant("bob")), isRoomPrivate: true))) }
                let sent = try #require(await chat.transcripts.messages.first { $0.isOutgoing })
                try await chat.chatService.retractMessage(sent, in: privateChat, accountID: chat.accountID)
            }

            let retraction = try #require(await chat.sent(containing: "<retract").first)
            #expect(retraction.contains("<active") == !peerSendsNone)
            await chat.disconnect()
        }

        @Test
        @MainActor
        func `Typing in a private chat sends composing to the occupant as chat`() async throws {
            let chat = try await ConnectedChat.make()

            await chat.typing(in: roomJID, occupantNickname: "bob")

            let composing = try #require(await chat.sent(containing: "<composing").first)
            #expect(composing.contains("to=\"room@conference.example.com/bob\""))
            #expect(composing.contains("type=\"chat\""))
            await chat.disconnect()
        }

        @Test
        @MainActor
        func `Typing in a room sends composing to the room as groupchat`() async throws {
            let chat = try await ConnectedChat.make()
            await chat.store.addConversation(Conversation(
                id: UUID(), accountID: chat.accountID, jid: roomJID, type: .groupchat,
                isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            try await chat.chatService.loadConversations(for: chat.accountID)

            await chat.typing(in: roomJID)

            let composing = try #require(await chat.sent(containing: "<composing").first)
            #expect(composing.contains("to=\"room@conference.example.com\""))
            #expect(composing.contains("type=\"groupchat\""))
            await chat.disconnect()
        }
    }

    struct LearnedUse {
        @Test
        @MainActor
        func `A reply without a chat state stops standalone and attached states`() async throws {
            let chat = try await ConnectedChat.make()

            await chat.receive(.messageReceived(contentMessage(from: contactPhone)))
            await chat.typing(in: contactJID)
            try await chat.chatService.sendMessage(to: contactJID, body: "hello", accountID: chat.accountID)

            #expect(await chat.sent(containing: "<composing").isEmpty)
            let message = try #require(await chat.sent(containing: "hello").first)
            #expect(!message.contains("<active"))
            await chat.disconnect()
        }

        @Test
        @MainActor
        func `A contact who sends no chat states gets none after the connection drops`() async throws {
            let chat = try await ConnectedChat.make()
            await chat.receive(.messageReceived(contentMessage(from: contactPhone)))

            await chat.receive(.disconnected(.connectionLost("reset")))
            await chat.typing(in: contactJID)

            #expect(await chat.sent(containing: "<composing").isEmpty)
            await chat.disconnect()
        }

        @Test
        @MainActor
        func `A chat state from the contact turns them back on`() async throws {
            let chat = try await ConnectedChat.make()
            await chat.receive(.messageReceived(contentMessage(from: contactPhone)))

            await chat.receive(.chatStateChanged(from: contactPhone, state: .composing, messageType: .chat))
            await chat.typing(in: contactJID)

            #expect(await chat.sent(containing: "<composing").count == 1)
            await chat.disconnect()
        }

        @Test(arguments: [false, true])
        @MainActor
        func `An occupant's reply without a chat state silences only their own private chat`(isCarbon: Bool) async throws {
            let chat = try await ConnectedChat.make()
            try await chat.store.upsertConversation(ConversationKind.room.conversation(accountID: chat.accountID))
            let reply = contentMessage(from: .full(occupant("alice")), isRoomPrivate: true)

            await chat.receive(isCarbon ? .messageCarbonReceived(ForwardedMessage(message: reply, timestamp: nil)) : .mucPrivateMessageReceived(reply))
            await chat.typing(in: roomJID, occupantNickname: "alice")
            await chat.typing(in: roomJID, occupantNickname: "bob")

            let composing = await chat.sent(containing: "<composing")
            #expect(composing.count == 1)
            #expect(composing.first?.contains("to=\"room@conference.example.com/bob\"") == true)
            await chat.disconnect()
        }
    }
}
