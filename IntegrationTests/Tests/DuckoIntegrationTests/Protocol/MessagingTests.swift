import DuckoCore
import DuckoXMPP
import Foundation
import struct os.OSAllocatedUnfairLock
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct MessagingTests {
        // MARK: - Protocol Layer

        @Test @MainActor func `Alice sends a direct message to Bob via raw module`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let bob = try #require(harness.accounts["bob"])
                let chat = try await harness.module(ChatModule.self, for: "alice")
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await chat.sendMessage(to: .bare(bobJID), body: body)

                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == body {
                        return true
                    }
                    return false
                }
            }
        }

        @Test(.timeLimit(.minutes(1))) @MainActor func `A burst of large concurrent messages arrives intact over TLS`() async throws {
            // The sends share one TLS session with its reads. Whether a write actually waits for the socket depends on
            // how fast the server drains it, so this doesn't reliably cover the would-block path.
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let bob = try #require(harness.accounts["bob"])
                let chat = try await harness.module(ChatModule.self, for: "alice")
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let marker = "burst-\(UUID().uuidString.prefix(8))"
                let bodies = (0 ..< 32).map { "\(marker)-\($0)-" + String(repeating: "x", count: 16000) }
                try await withThrowingTaskGroup { group in
                    for body in bodies {
                        group.addTask { try await chat.sendMessage(to: .bare(bobJID), body: body) }
                    }
                    try await group.waitForAll()
                }

                let pending = OSAllocatedUnfairLock(initialState: Set(bodies))
                _ = try await bob.waitForEvent { event in
                    guard case let .messageReceived(m) = event, let body = m.body else { return false }
                    return pending.withLock { pending in
                        pending.remove(body)
                        return pending.isEmpty
                    }
                }
            }
        }

        @Test @MainActor func `Outgoing message id round-trips to receiver`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let bob = try #require(harness.accounts["bob"])
                let alice = try #require(harness.accounts["alice"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let chat = try await harness.module(ChatModule.self, for: "alice")
                let body = "msg-\(UUID().uuidString.prefix(8))"
                let id = aliceClient.generateID()
                try await chat.sendMessage(to: .bare(bobJID), body: body, id: id)

                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.id == id {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Delivery receipt is auto-echoed for markable messages`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let chat = try await harness.module(ChatModule.self, for: "alice")
                let body = "msg-\(UUID().uuidString.prefix(8))"
                let stanzaID = aliceClient.generateID()
                try await chat.sendMessage(
                    to: .bare(bobJID),
                    body: body,
                    id: stanzaID,
                    requestReceipt: true,
                    markable: true
                )

                // Bob's ReceiptsModule auto-echoes the receipt. Alice waits immediately
                // after sendMessage — do not interpose a Bob-side waitForEvent.
                _ = try await alice.waitForEvent { event in
                    if case let .deliveryReceiptReceived(messageID, from: _) = event,
                       messageID == stanzaID {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Chat marker displayed is delivered`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let aliceJID = try harness.jid(for: TestCredentials.alice)
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let aliceChat = try await harness.module(ChatModule.self, for: "alice")
                let body = "msg-\(UUID().uuidString.prefix(8))"
                let stanzaID = aliceClient.generateID()
                try await aliceChat.sendMessage(to: .bare(bobJID), body: body, id: stanzaID, markable: true)

                // Bob receives the message.
                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == body {
                        return true
                    }
                    return false
                }

                // Bob sends a displayed marker.
                let bobReceipts = try await harness.module(ReceiptsModule.self, for: "bob")
                try await bobReceipts.sendDisplayedMarker(to: .bare(aliceJID), messageID: stanzaID)

                // Alice sees the chat marker.
                _ = try await alice.waitForEvent { event in
                    if case let .chatMarkerReceived(messageID, type, from: _) = event,
                       messageID == stanzaID, type == .displayed {
                        return true
                    }
                    return false
                }
            }
        }

        @Test(arguments: ChatState.allCases) @MainActor func `Chat state reaches the peer`(chatState: ChatState) async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let bob = try #require(harness.accounts["bob"])
                let aliceBareJID = try harness.jid(for: TestCredentials.alice)
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let states = try await harness.module(ChatStatesModule.self, for: "alice")
                try await states.sendChatState(chatState, to: .bare(bobJID))

                _ = try await bob.waitForEvent { event in
                    if case let .chatStateChanged(from, state, _) = event,
                       from.bareJID == aliceBareJID, state == chatState {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Message correction replaces the original`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let bob = try #require(harness.accounts["bob"])
                let alice = try #require(harness.accounts["alice"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let chat = try await harness.module(ChatModule.self, for: "alice")
                let originalBody = "msg-\(UUID().uuidString.prefix(8))"
                let originalID = aliceClient.generateID()
                try await chat.sendMessage(to: .bare(bobJID), body: originalBody, id: originalID)

                // Bob receives the original.
                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == originalBody {
                        return true
                    }
                    return false
                }

                // Alice sends a correction.
                let newBody = "msg-\(UUID().uuidString.prefix(8))"
                try await chat.sendCorrection(to: .bare(bobJID), body: newBody, replacingID: originalID)

                // Bob sees the correction.
                _ = try await bob.waitForEvent { event in
                    if case let .messageCorrected(origID, correctedBody, _, from: _, messageType: _) = event,
                       origID == originalID, correctedBody == newBody {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Message retraction propagates`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let bob = try #require(harness.accounts["bob"])
                let alice = try #require(harness.accounts["alice"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let chat = try await harness.module(ChatModule.self, for: "alice")
                let body = "msg-\(UUID().uuidString.prefix(8))"
                let stanzaID = aliceClient.generateID()
                try await chat.sendMessage(to: .bare(bobJID), body: body, id: stanzaID)

                // Bob receives the message.
                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == body {
                        return true
                    }
                    return false
                }

                // Alice retracts it.
                try await chat.sendRetraction(to: .bare(bobJID), originalID: stanzaID)

                // Bob sees the retraction.
                _ = try await bob.waitForEvent { event in
                    if case let .messageRetracted(origID, from: _, messageType: _) = event, origID == stanzaID {
                        return true
                    }
                    return false
                }
            }
        }

        // MARK: - Service Layer

        @Test @MainActor func `Service sendMessage delivers to peer`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(
                    to: bobJID,
                    body: body,
                    accountID: alice.accountID
                )

                _ = try await bob.waitForEvent { event in
                    if case let .messageReceived(m) = event, m.body == body {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Service sendCorrection round-trips via transcript store`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let initialBody = "msg-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(
                    to: bobJID,
                    body: initialBody,
                    accountID: alice.accountID
                )

                // Bob receives the original and captures its id.
                let receivedMessage = try await bob.waitForEvent(extracting: { event in
                    if case let .messageReceived(m) = event, m.body == initialBody {
                        return m
                    }
                    return nil
                })
                let capturedID = try #require(receivedMessage.id)

                let updatedBody = "msg-\(UUID().uuidString.prefix(8))"
                let aliceConvForCorrection = try await harness.environment.chatService.openConversation(for: bobJID, accountID: alice.accountID)
                let original = try #require(try await harness.environment.transcripts.findMessage(stanzaID: capturedID, conversationID: aliceConvForCorrection.id))
                try await harness.environment.chatService.sendCorrection(
                    of: original,
                    newBody: updatedBody,
                    in: aliceConvForCorrection,
                    accountID: alice.accountID
                )

                // Bob sees the correction.
                _ = try await bob.waitForEvent { event in
                    if case let .messageCorrected(origID, newBody, _, from: _, messageType: _) = event,
                       origID == capturedID, newBody == updatedBody {
                        return true
                    }
                    return false
                }

                // Verify Alice's transcript persists the edit.
                let aliceConversation = try await harness.environment.chatService.openConversation(for: bobJID, accountID: alice.accountID)
                let messages = await harness.environment.chatService.loadMessages(for: aliceConversation.id)
                try #require(!messages.isEmpty)
                let edited = try #require(messages.first { $0.stanzaID == capturedID })
                #expect(edited.isEdited)
                #expect(edited.body == updatedBody)
            }
        }

        @Test @MainActor func `Service retractMessage propagates to peer`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(
                    to: bobJID,
                    body: body,
                    accountID: alice.accountID
                )

                // Bob receives and captures the id.
                let receivedMessage = try await bob.waitForEvent(extracting: { event in
                    if case let .messageReceived(m) = event, m.body == body {
                        return m
                    }
                    return nil
                })
                let capturedID = try #require(receivedMessage.id)

                let aliceConvForRetract = try await harness.environment.chatService.openConversation(for: bobJID, accountID: alice.accountID)
                let originalToRetract = try #require(try await harness.environment.transcripts.findMessage(stanzaID: capturedID, conversationID: aliceConvForRetract.id))
                try await harness.environment.chatService.retractMessage(
                    originalToRetract,
                    in: aliceConvForRetract,
                    accountID: alice.accountID
                )

                // Bob sees the retraction.
                _ = try await bob.waitForEvent { event in
                    if case let .messageRetracted(origID, from: _, messageType: _) = event, origID == capturedID {
                        return true
                    }
                    return false
                }

                // Verify Alice's transcript persists the retraction.
                let aliceConversation = try await harness.environment.chatService.openConversation(for: bobJID, accountID: alice.accountID)
                let messages = await harness.environment.chatService.loadMessages(for: aliceConversation.id)
                try #require(!messages.isEmpty)
                let retracted = try #require(messages.first { $0.stanzaID == capturedID })
                #expect(retracted.isRetracted)
            }
        }

        @Test @MainActor func `Service reply carries the reply marker`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let initialBody = "msg-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(
                    to: bobJID,
                    body: initialBody,
                    accountID: alice.accountID
                )

                // Bob receives and captures the id.
                let receivedMessage = try await bob.waitForEvent(extracting: { event in
                    if case let .messageReceived(m) = event, m.body == initialBody {
                        return m
                    }
                    return nil
                })
                let originalID = try #require(receivedMessage.id)

                // Alice replies to her own message via service.
                let replyBody = "msg-\(UUID().uuidString.prefix(8))"
                let aliceConversation = try await harness.environment.chatService.openConversation(for: bobJID, accountID: alice.accountID)
                let original = try #require(try await harness.environment.transcripts.findMessage(stanzaID: originalID, conversationID: aliceConversation.id))
                try await harness.environment.chatService.sendMessage(
                    replyBody,
                    in: aliceConversation,
                    replyingTo: original,
                    accountID: alice.accountID
                )

                // Bob receives the reply with the <reply/> marker, after a quote of the original.
                let replyMessage = try await bob.waitForEvent(extracting: { event in
                    if case let .messageReceived(m) = event, m.body?.hasSuffix(replyBody) == true {
                        return m
                    }
                    return nil
                })
                #expect(replyMessage.element.child(named: "reply", namespace: XMPPNamespaces.messageReply) != nil)
                #expect(replyMessage.body == "> \(initialBody)\n\(replyBody)")
            }
        }

        @Test @MainActor func `Service sendDisplayedMarker notifies peer`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let aliceJID = try harness.jid(for: TestCredentials.alice)
                let bobJID = try harness.jid(for: TestCredentials.bob)

                // Alice sends a message via service.
                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(
                    to: bobJID,
                    body: body,
                    accountID: alice.accountID
                )

                // Bob receives and captures the id.
                let receivedMessage = try await bob.waitForEvent(extracting: { event in
                    if case let .messageReceived(m) = event, m.body == body {
                        return m
                    }
                    return nil
                })
                let stanzaID = try #require(receivedMessage.id)

                // Bob sends a displayed marker via service.
                try await harness.environment.chatService.sendDisplayedMarker(
                    to: aliceJID,
                    messageStanzaID: stanzaID,
                    accountID: bob.accountID
                )

                // Alice sees the chat marker.
                _ = try await alice.waitForEvent { event in
                    if case let .chatMarkerReceived(messageID, type, from: _) = event,
                       messageID == stanzaID, type == .displayed {
                        return true
                    }
                    return false
                }
            }
        }
    }
}
