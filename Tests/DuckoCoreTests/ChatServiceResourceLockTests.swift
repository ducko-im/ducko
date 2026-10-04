import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// RFC 6121 §5.1 resource-lock coverage. Sends run through a real `XMPPClient` over `MockTransport`
// (via `MockXMPPClientFactory` + `simulateNoTLSConnect`) so the serialized `to=` of the captured
// outbound bytes can be asserted directly. Inbound `XMPPMessage`s are built inline so the resource
// can vary per case — `makeIncomingMessage` (ChatServiceTests) hardcodes `resourcePart: "res"` and
// takes only a `BareJID`, so it can't drive the per-resource and bare-`from` cases.
//
// Locking is wired only into the two accepted-live-1:1 inbound paths (`handleMessageReceived` and
// `OMEMOService.handleEncryptedMessageReceived`). MAM ingest, carbons, and MUC private messages never
// call `learnResourceLock`, so they cannot move the live lock by construction — there is no hook to
// drive that negative through, so the cut is documented here rather than asserted.

private let accountJID = BareJID(localPart: "alice", domainPart: "example.com")!
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!

private func full(_ bare: BareJID, _ resource: String) -> JID {
    .full(FullJID(bareJID: bare, resourcePart: resource)!)
}

private func makeInbound(from: JID, body: String, id: String?) -> XMPPMessage {
    var message = XMPPMessage(type: .chat, to: .bare(accountJID), id: id)
    message.from = from
    message.body = body
    return message
}

@MainActor
private struct LockHarness {
    let store: MockPersistenceStore
    let transcripts: MockTranscriptStore
    let chatService: ChatService
    let transport: MockTransport
    let accountID: UUID
    let accountService: AccountService
}

@MainActor
private func makeConnectedHarness(modules: [any XMPPModule]) async throws -> LockHarness {
    let store = MockPersistenceStore()
    let transcripts = MockTranscriptStore()
    let transport = MockTransport()
    let factory = MockXMPPClientFactory(transport: transport, modules: modules)
    let accountService = makeAccountService(store: store, clientFactory: factory)
    let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
    chatService.setAccountService(accountService)

    let connectTask = Task { @MainActor in
        try await accountService.createAndConnect(
            jidString: testJIDString, password: "secret",
            host: "example.com", port: 5222
        )
    }
    await simulateNoTLSConnect(transport)
    let accountID = try await connectTask.value
    return LockHarness(
        store: store, transcripts: transcripts, chatService: chatService,
        transport: transport, accountID: accountID, accountService: accountService
    )
}

private func displayedMarkersSent(_ transport: MockTransport) async -> Int {
    await transport.sentBytes.count { String(decoding: $0, as: UTF8.self).contains("<displayed") }
}

/// An inbound message carrying the server's own id for it, which is what tells two messages apart that share the id
/// their sender gave them.
private func makeStampedInbound(from: JID, body: String, id: String, serverID: String) -> XMPPMessage {
    var message = makeInbound(from: from, body: body, id: id)
    var stamp = DuckoXMPP.XMLElement(name: "stanza-id", namespace: XMPPNamespaces.stanzaID)
    stamp.setAttribute("id", value: serverID)
    stamp.setAttribute("by", value: accountJID.description)
    message.element.addChild(stamp)
    return message
}

/// The most recently serialized outbound stanza. Each `chatService` send awaits the transport write,
/// so the bytes are present once the send call returns — no explicit `waitForSent` is needed.
private func lastSent(_ transport: MockTransport) async -> String {
    let sent = await transport.sentBytes
    return String(decoding: sent.last ?? [], as: UTF8.self)
}

/// Seeds an outgoing message (with `stanzaID`) into `conversation` so a correction/retraction has a
/// matching original to amend.
@MainActor
private func seedOutgoing(_ transcripts: MockTranscriptStore, conversation: Conversation, stanzaID: String) async -> ChatMessage {
    let message = ChatMessage(
        id: UUID(), conversationID: conversation.id, stanzaID: stanzaID,
        fromJID: contactJID.description, body: "original",
        timestamp: Date(), isOutgoing: true,
        isDelivered: false, isEdited: false, type: "chat"
    )
    await transcripts.addMessage(message)
    return message
}

// MARK: - Tests

enum ChatServiceResourceLockTests {
    struct SendAddressing {
        @Test
        @MainActor
        func `Send targets the full JID after an inbound message from that resource`() async throws {
            let harness = try await makeConnectedHarness(modules: [ChatModule()])

            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "in-1")),
                accountID: harness.accountID
            )
            try await harness.chatService.sendMessage(to: contactJID, body: "reply", accountID: harness.accountID)

            let raw = await lastSent(harness.transport)
            #expect(raw.contains("to=\"contact@example.com/phone\""))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `Send targets the bare JID when no inbound message has been seen`() async throws {
            let harness = try await makeConnectedHarness(modules: [ChatModule()])

            try await harness.chatService.sendMessage(to: contactJID, body: "reply", accountID: harness.accountID)

            let raw = await lastSent(harness.transport)
            #expect(raw.contains("to=\"contact@example.com\""))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct Invalidation {
        @Test
        @MainActor
        func `Send falls back to bare after the locked resource goes unavailable`() async throws {
            let harness = try await makeConnectedHarness(modules: [ChatModule()])

            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "in-1")),
                accountID: harness.accountID
            )
            await harness.chatService.handleEvent(
                .presenceUpdated(from: full(contactJID, "phone"), presence: XMPPPresence(type: .unavailable)),
                accountID: harness.accountID
            )
            try await harness.chatService.sendMessage(to: contactJID, body: "reply", accountID: harness.accountID)

            let raw = await lastSent(harness.transport)
            #expect(raw.contains("to=\"contact@example.com\""))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `Unavailable presence from a non-locked resource does not release the lock`() async throws {
            let harness = try await makeConnectedHarness(modules: [ChatModule()])

            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "in-1")),
                accountID: harness.accountID
            )
            await harness.chatService.handleEvent(
                .presenceUpdated(from: full(contactJID, "laptop"), presence: XMPPPresence(type: .unavailable)),
                accountID: harness.accountID
            )
            try await harness.chatService.sendMessage(to: contactJID, body: "reply", accountID: harness.accountID)

            let raw = await lastSent(harness.transport)
            #expect(raw.contains("to=\"contact@example.com/phone\""))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `Inbound message from the bare JID releases the lock`() async throws {
            let harness = try await makeConnectedHarness(modules: [ChatModule()])

            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "in-1")),
                accountID: harness.accountID
            )
            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: .bare(contactJID), body: "from bare", id: "in-2")),
                accountID: harness.accountID
            )
            try await harness.chatService.sendMessage(to: contactJID, body: "reply", accountID: harness.accountID)

            let raw = await lastSent(harness.transport)
            #expect(raw.contains("to=\"contact@example.com\""))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct ReLock {
        @Test
        @MainActor
        func `Inbound from a different resource re-locks and the next send follows it`() async throws {
            let harness = try await makeConnectedHarness(modules: [ChatModule()])

            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "in-1")),
                accountID: harness.accountID
            )
            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "laptop"), body: "hi again", id: "in-2")),
                accountID: harness.accountID
            )
            try await harness.chatService.sendMessage(to: contactJID, body: "reply", accountID: harness.accountID)

            let raw = await lastSent(harness.transport)
            #expect(raw.contains("to=\"contact@example.com/laptop\""))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct CorrectionAndRetraction {
        @Test
        @MainActor
        func `Correction and retraction follow the current lock`() async throws {
            let harness = try await makeConnectedHarness(modules: [ChatModule()])
            let conversation = try await harness.chatService.openConversation(for: contactJID, accountID: harness.accountID)
            let original = await seedOutgoing(harness.transcripts, conversation: conversation, stanzaID: "out-1")

            // Lock /phone, then correct → correction targets /phone.
            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "in-1")),
                accountID: harness.accountID
            )
            try await harness.chatService.sendCorrection(
                original: original, to: contactJID, newBody: "fixed", accountID: harness.accountID
            )
            #expect(await lastSent(harness.transport).contains("to=\"contact@example.com/phone\""))

            // Peer re-locks to /laptop before the retraction → retraction targets the *current* lock.
            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "laptop"), body: "switched", id: "in-2")),
                accountID: harness.accountID
            )
            try await harness.chatService.retractMessage(
                original: original, to: contactJID, accountID: harness.accountID
            )
            #expect(await lastSent(harness.transport).contains("to=\"contact@example.com/laptop\""))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct EncryptedInbound {
        @Test
        @MainActor
        func `OMEMO-encrypted inbound establishes the lock`() async throws {
            let harness = try await makeConnectedHarness(modules: [ChatModule()])
            let omemoService = OMEMOService(omemoStore: MockOMEMOStore())
            omemoService.setChatService(harness.chatService)

            // The event carries a decrypted body, so no real crypto is needed; this drives the real
            // OMEMOService → ChatService.learnResourceLock wiring rather than calling the hook directly.
            await omemoService.handleEvent(
                .omemoEncryptedMessageReceived(
                    from: full(contactJID, "phone"), decryptedBody: "secret",
                    senderDeviceID: 1, stanzaID: "omemo-1"
                ),
                accountID: harness.accountID
            )
            // The encrypted message switched the chat's encryption on. Switching it off again keeps the reply a
            // plaintext send, which needs no OMEMO wiring and still consults the same shared lock.
            let conversationID = try #require(harness.chatService.openConversations.first { $0.jid == contactJID }?.id)
            try await harness.chatService.setEncryptionEnabled(false, for: conversationID, accountID: harness.accountID)
            try await harness.chatService.sendMessage(to: contactJID, body: "reply", accountID: harness.accountID)

            let raw = await lastSent(harness.transport)
            #expect(raw.contains("to=\"contact@example.com/phone\""))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `A failed OMEMO decrypt (nil body) does not establish the lock`() async throws {
            let harness = try await makeConnectedHarness(modules: [ChatModule()])
            let omemoService = OMEMOService(omemoStore: MockOMEMOStore())
            omemoService.setChatService(harness.chatService)

            // A nil decryptedBody is a failed/unauthenticated decrypt — it must not steer routing.
            await omemoService.handleEvent(
                .omemoEncryptedMessageReceived(
                    from: full(contactJID, "phone"), decryptedBody: nil,
                    senderDeviceID: 0, stanzaID: "omemo-bad"
                ),
                accountID: harness.accountID
            )
            try await harness.chatService.sendMessage(to: contactJID, body: "reply", accountID: harness.accountID)

            let raw = await lastSent(harness.transport)
            #expect(raw.contains("to=\"contact@example.com\""))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `An OMEMO message from a groupchat sender does not move the 1:1 lock`() async throws {
            let harness = try await makeConnectedHarness(modules: [ChatModule()])
            let roomJID = try #require(BareJID(localPart: "room", domainPart: "conference.example.com"))
            // Seed a joined-room (groupchat) conversation so the groupchat guard in learnResourceLock fires.
            await harness.store.addConversation(Conversation(
                id: UUID(), accountID: harness.accountID, jid: roomJID,
                type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            ))
            try await harness.chatService.loadConversations(for: harness.accountID)

            let omemoService = OMEMOService(omemoStore: MockOMEMOStore())
            omemoService.setChatService(harness.chatService)
            await omemoService.handleEvent(
                .omemoEncryptedMessageReceived(
                    from: full(roomJID, "nick"), decryptedBody: "group msg",
                    senderDeviceID: 1, stanzaID: "omemo-group"
                ),
                accountID: harness.accountID
            )
            // A subsequent send to the room JID stays bare — the groupchat sender never locked it.
            try await harness.chatService.sendMessage(to: roomJID, body: "x", accountID: harness.accountID)

            let raw = await lastSent(harness.transport)
            #expect(raw.contains("to=\"room@conference.example.com\""))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct AccountIsolation {
        @Test
        @MainActor
        func `Locks are isolated per account`() async throws {
            let harness = try await makeConnectedHarness(modules: [ChatModule()])
            let otherAccountID = UUID()

            // Lock the connected account to /phone and a different account (same bare peer) to /laptop.
            harness.chatService.learnResourceLock(
                from: full(contactJID, "phone"), accountID: harness.accountID,
                sequence: harness.chatService.nextLockSequence()
            )
            harness.chatService.learnResourceLock(
                from: full(contactJID, "laptop"), accountID: otherAccountID,
                sequence: harness.chatService.nextLockSequence()
            )

            // The connected account's send follows its own lock, unaffected by the other account's.
            try await harness.chatService.sendMessage(to: contactJID, body: "reply", accountID: harness.accountID)

            let raw = await lastSent(harness.transport)
            #expect(raw.contains("to=\"contact@example.com/phone\""))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct ArrivalOrder {
        @Test
        @MainActor
        func `An arrival-older inbound does not overwrite a newer lock`() async throws {
            let harness = try await makeConnectedHarness(modules: [ChatModule()])

            // Simulate interleaved handlers resuming out of order: the newer message (higher sequence) learns
            // first, then the older one (lower sequence) tries to learn and must be dropped.
            harness.chatService.learnResourceLock(from: full(contactJID, "laptop"), accountID: harness.accountID, sequence: 5)
            harness.chatService.learnResourceLock(from: full(contactJID, "phone"), accountID: harness.accountID, sequence: 3)

            try await harness.chatService.sendMessage(to: contactJID, body: "reply", accountID: harness.accountID)

            let raw = await lastSent(harness.transport)
            #expect(raw.contains("to=\"contact@example.com/laptop\""))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct Lifecycle {
        @Test
        @MainActor
        func `Disconnect clears the locks`() async throws {
            let harness = try await makeConnectedHarness(modules: [ChatModule()])

            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "in-1")),
                accountID: harness.accountID
            )
            // The disconnect event clears the lock map; the transport stays up so the next send is observable.
            await harness.chatService.handleEvent(.disconnected(.requested), accountID: harness.accountID)
            try await harness.chatService.sendMessage(to: contactJID, body: "reply", accountID: harness.accountID)

            let raw = await lastSent(harness.transport)
            #expect(raw.contains("to=\"contact@example.com\""))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct MarkerAddressing {
        @Test
        @MainActor
        func `Displayed marker targets the full JID for a chat conversation but the bare room for groupchat`() async throws {
            let harness = try await makeConnectedHarness(modules: [ReceiptsModule()])

            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "in-1")),
                accountID: harness.accountID
            )

            // A 1:1 marker follows the lock.
            try await harness.chatService.sendDisplayedMarker(
                to: contactJID, messageStanzaID: "in-1", accountID: harness.accountID, messageType: .chat
            )
            #expect(await lastSent(harness.transport).contains("to=\"contact@example.com/phone\""))

            // A groupchat marker stays room-addressed even when a lock exists for the same bare JID.
            try await harness.chatService.sendDisplayedMarker(
                to: contactJID, messageStanzaID: "srv-1", accountID: harness.accountID, messageType: .groupchat
            )
            #expect(await lastSent(harness.transport).contains("to=\"contact@example.com\""))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `Looking at a chat again sends no second displayed marker for the same message`() async throws {
            let harness = try await makeConnectedHarness(modules: [ReceiptsModule()])
            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "in-1")),
                accountID: harness.accountID
            )
            let conversationID = try #require(harness.chatService.openConversations.first?.id)
            func markersSent() async -> Int {
                await displayedMarkersSent(harness.transport)
            }

            await harness.chatService.selectConversation(conversationID, accountID: harness.accountID)
            // Armed: the first look does send the marker.
            #expect(await markersSent() == 1)

            await harness.chatService.selectConversation(nil)
            await harness.chatService.selectConversation(conversationID, accountID: harness.accountID)
            #expect(await markersSent() == 1)

            // A newer message arriving in the chat in view gets a marker of its own.
            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "more", id: "in-2")),
                accountID: harness.accountID
            )
            #expect(await markersSent() == 2)

            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `A later message that reuses an earlier one's id gets a displayed marker of its own`() async throws {
            let harness = try await makeConnectedHarness(modules: [ReceiptsModule()])
            let phone = full(contactJID, "phone")
            await harness.chatService.handleEvent(
                .messageReceived(makeStampedInbound(from: phone, body: "hi", id: "ducko-3", serverID: "server-1")),
                accountID: harness.accountID
            )
            let conversationID = try #require(harness.chatService.openConversations.first?.id)
            await harness.chatService.selectConversation(conversationID, accountID: harness.accountID)
            try #require(await displayedMarkersSent(harness.transport) == 1)
            await harness.chatService.selectConversation(nil)

            // The contact's client started over and numbers its messages from the beginning again.
            await harness.chatService.handleEvent(
                .messageReceived(makeStampedInbound(from: phone, body: "again", id: "ducko-3", serverID: "server-2")),
                accountID: harness.accountID
            )
            // Armed: the second message was kept as a message of its own.
            try #require(await harness.transcripts.messages.count == 2)
            await harness.chatService.selectConversation(conversationID, accountID: harness.accountID)

            #expect(await displayedMarkersSent(harness.transport) == 2)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `A displayed marker that could not be sent goes out the next time the chat is looked at`() async throws {
            let harness = try await makeConnectedHarness(modules: [ReceiptsModule()])
            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "in-1")),
                accountID: harness.accountID
            )
            let conversationID = try #require(harness.chatService.openConversations.first?.id)
            func markersSent() async -> Int {
                await displayedMarkersSent(harness.transport)
            }

            await harness.transport.failNextSend(matching: "<displayed", error: XMPPClientError.sendFailed("The connection was closed"))
            await harness.chatService.selectConversation(conversationID, accountID: harness.accountID)
            // Armed: the first look did not get its marker out.
            #expect(await markersSent() == 0)

            await harness.chatService.selectConversation(nil)
            await harness.chatService.selectConversation(conversationID, accountID: harness.accountID)
            #expect(await markersSent() == 1)

            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `Standalone chat-state send targets the locked full JID`() async throws {
            let harness = try await makeConnectedHarness(modules: [ChatStatesModule()])

            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "in-1")),
                accountID: harness.accountID
            )
            await harness.chatService.userIsTyping(in: contactJID, accountID: harness.accountID)

            let raw = await lastSent(harness.transport)
            #expect(raw.contains("to=\"contact@example.com/phone\""))

            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }
}

/// A displayed marker and a read count both say the chat was looked at, so they are decided together.
extension ChatServiceResourceLockTests {
    struct MarkerDecision {
        private let otherJID = BareJID(localPart: "other", domainPart: "example.com")!

        /// The count the tab chip shows, which is the published conversation's.
        @MainActor
        private func publishedUnreadCount(_ harness: LockHarness, _ conversationID: UUID) -> Int? {
            harness.chatService.openConversations.first { $0.id == conversationID }?.unreadCount
        }

        @MainActor
        private func conversationID(_ harness: LockHarness, with jid: BareJID) throws -> UUID {
            try #require(harness.chatService.openConversations.first { $0.jid == jid }?.id)
        }

        private func markers(_ transport: MockTransport, naming messageID: String) async -> Int {
            await transport.sentBytes.count {
                let stanza = String(decoding: $0, as: UTF8.self)
                return stanza.contains("<displayed") && stanza.contains("id=\"\(messageID)\"")
            }
        }

        @Test
        @MainActor
        func `A selection overtaken by another sends no marker of its own`() async throws {
            let harness = try await makeConnectedHarness(modules: [ReceiptsModule()])
            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "a-1")), accountID: harness.accountID
            )
            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(otherJID, "phone"), body: "hello", id: "b-1")), accountID: harness.accountID
            )
            let first = try conversationID(harness, with: contactJID)
            let second = try conversationID(harness, with: otherJID)

            let entered = AsyncSemaphore()
            let release = AsyncSemaphore()
            await harness.store.installMarkConversationReadGate(entered: entered, release: release)
            let overtaken = Task { @MainActor in
                await harness.chatService.selectConversation(first, accountID: harness.accountID)
            }
            await entered.wait()
            await harness.chatService.selectConversation(second, accountID: harness.accountID)
            // Armed: the later selection sent its marker.
            try #require(await markers(harness.transport, naming: "b-1") == 1)
            await release.signal()
            await overtaken.value

            #expect(await displayedMarkersSent(harness.transport) == 1)
            #expect(await markers(harness.transport, naming: "a-1") == 0)
            #expect(publishedUnreadCount(harness, second) == 0)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `A selection that finishes while a later one is still loading sends no marker for its own chat`() async throws {
            let harness = try await makeConnectedHarness(modules: [ReceiptsModule()])
            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "a-1")), accountID: harness.accountID
            )
            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(otherJID, "phone"), body: "hello", id: "b-1")), accountID: harness.accountID
            )
            let first = try conversationID(harness, with: contactJID)
            let second = try conversationID(harness, with: otherJID)

            let (markEntered, markRelease) = (AsyncSemaphore(), AsyncSemaphore())
            await harness.store.installMarkConversationReadGate(entered: markEntered, release: markRelease)
            let overtaken = Task { @MainActor in
                await harness.chatService.selectConversation(first, accountID: harness.accountID)
            }
            await markEntered.wait()
            let (loadEntered, loadRelease) = (AsyncSemaphore(), AsyncSemaphore())
            await harness.transcripts.installFetchMessagesGate(entered: loadEntered, release: loadRelease)
            let later = Task { @MainActor in
                await harness.chatService.selectConversation(second, accountID: harness.accountID)
            }
            await loadEntered.wait()
            // The loaded messages are still the first chat's, and the second chat is the active one.
            await markRelease.signal()
            await overtaken.value

            #expect(await markers(harness.transport, naming: "a-1") == 0)
            await loadRelease.signal()
            await later.value
            #expect(await markers(harness.transport, naming: "b-1") == 1)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `A selection that finishes while its chat is loading again names no other chat's message`() async throws {
            let harness = try await makeConnectedHarness(modules: [ReceiptsModule()])
            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "a-1")), accountID: harness.accountID
            )
            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(otherJID, "phone"), body: "hello", id: "b-1")), accountID: harness.accountID
            )
            let first = try conversationID(harness, with: contactJID)
            let second = try conversationID(harness, with: otherJID)

            let (markEntered, markRelease) = (AsyncSemaphore(), AsyncSemaphore())
            await harness.store.installMarkConversationReadGate(entered: markEntered, release: markRelease)
            let overtaken = Task { @MainActor in
                await harness.chatService.selectConversation(first, accountID: harness.accountID)
            }
            await markEntered.wait()
            await harness.chatService.selectConversation(second, accountID: harness.accountID)
            try #require(await markers(harness.transport, naming: "b-1") == 1)
            let (loadEntered, loadRelease) = (AsyncSemaphore(), AsyncSemaphore())
            await harness.transcripts.installFetchMessagesGate(entered: loadEntered, release: loadRelease)
            let again = Task { @MainActor in
                await harness.chatService.selectConversation(first, accountID: harness.accountID)
            }
            await loadEntered.wait()
            // The first chat is the active one again, and the loaded messages are still the second chat's.
            await markRelease.signal()
            await overtaken.value

            #expect(await markers(harness.transport, naming: "b-1") == 1)
            await loadRelease.signal()
            await again.value
            #expect(await markers(harness.transport, naming: "a-1") == 1)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `A message stored after its chat went out of view counts as unread and sends no marker`() async throws {
            let harness = try await makeConnectedHarness(modules: [ReceiptsModule()])
            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "in-1")), accountID: harness.accountID
            )
            let id = try conversationID(harness, with: contactJID)
            await harness.chatService.selectConversation(id, accountID: harness.accountID)
            try #require(publishedUnreadCount(harness, id) == 0)

            let entered = AsyncSemaphore()
            let release = AsyncSemaphore()
            await harness.store.installConversationWriteGate(entered: entered, release: release)
            let delivery = Task { @MainActor in
                await harness.chatService.handleEvent(
                    .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "more", id: "in-2")), accountID: harness.accountID
                )
            }
            await entered.wait()
            await harness.chatService.selectConversation(nil)
            await release.signal()
            await delivery.value

            #expect(await markers(harness.transport, naming: "in-2") == 0)
            #expect(publishedUnreadCount(harness, id) == 1)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `A message stored after its chat came into view ends read with one marker`() async throws {
            let harness = try await makeConnectedHarness(modules: [ReceiptsModule()])
            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "in-1")), accountID: harness.accountID
            )
            let id = try conversationID(harness, with: contactJID)
            try #require(publishedUnreadCount(harness, id) == 1)

            let entered = AsyncSemaphore()
            let release = AsyncSemaphore()
            await harness.store.installConversationWriteGate(entered: entered, release: release)
            let delivery = Task { @MainActor in
                await harness.chatService.handleEvent(
                    .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "more", id: "in-2")), accountID: harness.accountID
                )
            }
            await entered.wait()
            await harness.chatService.selectConversation(id, accountID: harness.accountID)
            await release.signal()
            await delivery.value

            #expect(await markers(harness.transport, naming: "in-2") == 1)
            #expect(publishedUnreadCount(harness, id) == 0)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `A message whose marker went out stays read when its chat goes out of view right after`() async throws {
            let harness = try await makeConnectedHarness(modules: [ReceiptsModule()])
            await harness.chatService.handleEvent(
                .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "hi", id: "in-1")), accountID: harness.accountID
            )
            let id = try conversationID(harness, with: contactJID)
            await harness.chatService.selectConversation(id, accountID: harness.accountID)

            let entered = AsyncSemaphore()
            let release = AsyncSemaphore()
            await harness.store.installMarkConversationReadGate(entered: entered, release: release)
            let delivery = Task { @MainActor in
                await harness.chatService.handleEvent(
                    .messageReceived(makeInbound(from: full(contactJID, "phone"), body: "more", id: "in-2")), accountID: harness.accountID
                )
            }
            await entered.wait()
            // The marker went out before the read count was written.
            #expect(await markers(harness.transport, naming: "in-2") == 1)
            await harness.chatService.selectConversation(nil)
            await release.signal()
            await delivery.value

            #expect(publishedUnreadCount(harness, id) == 0)
            let stored = try await harness.store.fetchConversations(for: harness.accountID).first { $0.id == id }
            #expect(stored?.unreadCount == 0)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }
}
