import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let contact = BareJID(localPart: "bob", domainPart: "example.com")!
private let room = BareJID(localPart: "room", domainPart: "conference.example.com")!

/// Where encrypted messages land: carbons in the chat with their peer, room messages under the occupant's nickname,
/// and every message that cannot be read as a notice saying why.
@MainActor
struct ChatServiceEncryptedRoutingTests {
    private let store = MockPersistenceStore()
    private let transcripts = MockTranscriptStore()
    /// Held here, since the services hold it weakly.
    private let accountService: AccountService
    private let chatService: ChatService
    private let omemoService: OMEMOService
    private let accountID: UUID
    private let chat: Conversation
    private let roomChat: Conversation

    init() async throws {
        let account = try Account(id: UUID(), jid: #require(BareJID.parse(testJIDString)), isEnabled: true, connectOnLaunch: false, createdAt: Date())
        await store.addAccount(account)
        self.chat = Conversation(
            id: UUID(), accountID: account.id, jid: contact, type: .chat, isPinned: false, isMuted: false, unreadCount: 0,
            encryptionEnabled: false, createdAt: Date()
        )
        self.roomChat = Conversation(
            id: UUID(), accountID: account.id, jid: room, type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0,
            roomNickname: "me", encryptionEnabled: true, createdAt: Date()
        )
        await store.addConversation(chat)
        await store.addConversation(roomChat)
        self.accountService = makeAccountService(store: store)
        try await accountService.loadAccounts()
        self.chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
        chatService.setAccountService(accountService)
        self.omemoService = OMEMOService(omemoStore: MockOMEMOStore())
        omemoService.setAccountService(accountService)
        omemoService.setChatService(chatService)
        chatService.setOMEMOService(omemoService)
        self.accountID = account.id
    }

    /// Oldest first.
    private func messages(in conversation: Conversation) async throws -> [ChatMessage] {
        try await transcripts.fetchMessages(for: conversation.id, before: nil, limit: 50).reversed()
    }

    /// An encrypted message the user sent to the contact under `stanzaID`.
    private func ownEncryptedMessage(stanzaID: String) -> ChatMessage {
        ChatMessage(
            id: UUID(), conversationID: chat.id, stanzaID: stanzaID, fromJID: contact.description, body: "helo", timestamp: Date(),
            isOutgoing: true, isDelivered: false, isEdited: false, type: "chat", isEncrypted: true
        )
    }

    // MARK: - Carbons

    @Test(arguments: [true, false])
    func `an encrypted carbon lands in the chat with the recipient of a sent one and the sender of a received one`(isOutgoing: Bool) async throws {
        let stanza = isOutgoing
            ? encryptedStanza(from: "\(testJIDString)/phone", to: "\(contact)/desktop", id: "c1")
            : encryptedStanza(from: "\(contact)/desktop", to: "\(testJIDString)/phone", id: "c1")
        let sentTime = try #require(Date(xmppTimestamp: "2026-03-01T10:00:00Z"))

        await chatService.receiveEncryptedMessage(
            stanza, content: EncryptedContent(encryptedOutcome(of: stanza, body: "hi")),
            origin: .carbon(isOutgoing: isOutgoing, sentTime: sentTime), accountID: accountID
        )

        let message = try #require(try await messages(in: chat).first)
        #expect(message.body == "hi")
        #expect(message.isOutgoing == isOutgoing)
        #expect(message.fromJID == contact.description)
        #expect(message.timestamp == sentTime)
    }

    @Test(arguments: [true, false])
    func `an encrypted sent carbon's correction or retraction applies in the recipient's chat`(isRetraction: Bool) async throws {
        let own = ChatMessage(
            id: UUID(), conversationID: chat.id, stanzaID: "m1", fromJID: contact.description, body: "helo", timestamp: Date(),
            isOutgoing: true, isDelivered: false, isEdited: false, type: "chat", isEncrypted: true
        )
        await transcripts.addMessage(own)
        let stanza = encryptedStanza(from: "\(testJIDString)/phone", to: contact.description, id: "c2")
        let amendment = isRetraction
            ? DuckoXMPP.XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": "m1"])
            : DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": "m1"])

        await chatService.receiveEncryptedMessage(
            stanza, content: EncryptedContent(encryptedOutcome(of: stanza, body: isRetraction ? "retracted" : "hello", elements: [amendment])),
            origin: .carbon(isOutgoing: true, sentTime: Date()), accountID: accountID
        )

        let stored = try #require(try await messages(in: chat).first)
        #expect(try await messages(in: chat).count == 1)
        #expect(isRetraction ? stored.isRetracted : stored.body == "hello")
    }

    @Test(arguments: [true, false])
    func `an applied encrypted correction or retraction is reported as the event a plaintext one comes in`(isRetraction: Bool) async throws {
        await transcripts.addMessage(ownEncryptedMessage(stanzaID: "m1"))
        let reported = EventLog()
        chatService.onDecryptedAmendment = { event, _ in reported.events.append(event) }
        let stanza = encryptedStanza(from: "\(testJIDString)/phone", to: contact.description, id: "c5")

        await chatService.receiveEncryptedMessage(
            stanza, content: EncryptedContent(encryptedOutcome(of: stanza, body: "hello", elements: [amendment(of: "m1", isRetraction: isRetraction)])),
            origin: .carbon(isOutgoing: true, sentTime: Date()), accountID: accountID
        )

        let event = try #require(reported.events.first)
        #expect(reported.events.count == 1)
        if case let .messageCorrected(originalID, newBody, _, _, _) = event {
            #expect(!isRetraction && originalID == "m1" && newBody == "hello")
        } else if case let .messageRetracted(originalID, _, _) = event {
            #expect(isRetraction && originalID == "m1")
        } else {
            Issue.record("Reported \(event)")
        }
    }

    /// A plaintext correction's own event already shows it, so a report from the encrypted path would show it twice.
    @Test func `a plaintext carbon's correction is not reported as an encrypted one`() async throws {
        await transcripts.addMessage(ChatMessage(
            id: UUID(), conversationID: chat.id, stanzaID: "m1", fromJID: contact.description, body: "helo", timestamp: Date(),
            isOutgoing: true, isDelivered: false, isEdited: false, type: "chat"
        ))
        let reported = EventLog()
        chatService.onDecryptedAmendment = { event, _ in reported.events.append(event) }
        let correction = plaintextAmendment(of: "m1", body: "hello", from: "\(testJIDString)/phone", to: contact.description)

        await chatService.handleEvent(.messageCarbonSent(ForwardedMessage(message: correction, timestamp: nil)), accountID: accountID)

        #expect(try await messages(in: chat).first?.body == "hello")
        #expect(reported.events.isEmpty)
    }

    @Test func `an encrypted carbon's correction is dated by the carbon`() async throws {
        await transcripts.addMessage(ownEncryptedMessage(stanzaID: "m1"))
        let stanza = encryptedStanza(from: "\(testJIDString)/phone", to: contact.description, id: "c6")
        let sentTime = try #require(Date(xmppTimestamp: "2026-03-01T10:00:00Z"))

        await chatService.receiveEncryptedMessage(
            stanza, content: EncryptedContent(encryptedOutcome(of: stanza, body: "hello", elements: [amendment(of: "m1", isRetraction: false)])),
            origin: .carbon(isOutgoing: true, sentTime: sentTime), accountID: accountID
        )

        #expect(try await messages(in: chat).first?.editedAt == sentTime)
    }

    enum PlaintextOrigin: CaseIterable {
        case live, carbon, archive
    }

    /// Text the server could read must never show as encrypted, and the server must not take an encrypted message
    /// away.
    @Test(arguments: PlaintextOrigin.allCases, [false, true])
    func `a correction or retraction in the clear leaves an encrypted message as it is`(origin: PlaintextOrigin, isRetraction: Bool) async throws {
        await transcripts.addMessage(ChatMessage(
            id: UUID(), conversationID: chat.id, stanzaID: "m1", fromJID: contact.description, body: "secret", timestamp: Date(),
            isOutgoing: false, isDelivered: false, isEdited: false, type: "chat", isEncrypted: true
        ))
        let amendment = plaintextAmendment(of: "m1", isRetraction: isRetraction, from: "\(contact)/desktop", to: testJIDString)

        switch origin {
        case .live:
            let from = try #require(amendment.from)
            let event: XMPPEvent = isRetraction
                ? .messageRetracted(originalID: "m1", from: from, messageType: .chat)
                : .messageCorrected(originalID: "m1", newBody: "injected", replyFallbackRange: nil, from: from, messageType: .chat)
            await chatService.handleEvent(event, accountID: accountID)
        case .carbon:
            await chatService.handleEvent(.messageCarbonReceived(ForwardedMessage(message: amendment, timestamp: nil)), accountID: accountID)
        case .archive:
            let archived = ArchivedMessage(messageID: "a9", serverID: nil, forwarded: ForwardedMessage(message: amendment, timestamp: "2026-03-01T10:00:00Z"))
            let converted = try await chatService.convertAndDedup(
                archived: [archived], conversation: chat, accountJID: #require(BareJID.parse(testJIDString)), accountID: accountID
            )
            await chatService.applyArchivedAmendments(converted.amendments, in: chat, accountID: accountID)
        }

        let stored = try #require(try await messages(in: chat).first)
        #expect(stored.body == "secret")
        #expect(!stored.isEdited)
        #expect(!stored.isRetracted)
    }

    @Test func `a correction and body in the clear next to an unreadable carbon change nothing but its notice`() async throws {
        let original = ChatMessage(
            id: UUID(), conversationID: chat.id, stanzaID: "m1", fromJID: contact.description, body: "keep", timestamp: Date(),
            isOutgoing: false, isDelivered: false, isEdited: false, type: "chat"
        )
        await transcripts.addMessage(original)
        var stanza = encryptedStanza(from: "\(contact)/desktop", to: testJIDString, id: "c3")
        stanza.body = "injected"
        stanza.element.addChild(DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": "m1"]))

        await chatService.receiveEncryptedMessage(
            stanza, content: .undecryptable(.notForThisDevice), origin: .carbon(isOutgoing: false, sentTime: Date()), accountID: accountID
        )

        let stored = try await messages(in: chat)
        #expect(stored.map(\.body) == ["keep", ""])
        #expect(stored.last?.undecryptableReason == .notForThisDevice)
    }

    @Test func `a carbon encrypted with another method shows a notice naming it in the chat with its peer`() async throws {
        var message = XMPPMessage(type: .chat, to: .bare(contact), id: "c4")
        message.from = try .full(#require(FullJID.parse("\(testJIDString)/phone")))
        message.body = "This message is encrypted with OpenPGP"
        message.element.addChild(openPGPEncryption)

        await chatService.handleEvent(.messageCarbonSent(ForwardedMessage(message: message, timestamp: nil)), accountID: accountID)

        let stored = try #require(try await messages(in: chat).first)
        #expect(stored.isOutgoing)
        #expect(stored.body.isEmpty)
        #expect(stored.undecryptableReason == .otherMethod(name: "OpenPGP for XMPP"))
    }

    // MARK: - Notices

    enum NoticeOrigin: CaseIterable {
        case chat, room, archive
    }

    @Test(arguments: NoticeOrigin.allCases, [true, false])
    func `a message not for this device or encrypted with another method shows a notice`(origin: NoticeOrigin, isOMEMO: Bool) async throws {
        let type: XMPPMessage.MessageType = origin == .room ? .groupchat : .chat
        var stanza = encryptedStanza(type: type, from: origin == .room ? "\(room)/carol" : "\(contact)/desktop", to: testJIDString, id: "n1")
        if !isOMEMO {
            stanza.element.children.removeAll()
            stanza.body = "This message is encrypted with OpenPGP"
            stanza.element.addChild(openPGPEncryption)
        }

        switch origin {
        case .archive:
            let archived = ArchivedMessage(messageID: "a1", serverID: nil, forwarded: ForwardedMessage(message: stanza, timestamp: "2026-03-01T10:00:00Z"))
            _ = try await chatService.convertAndDedup(
                archived: [archived], conversation: chat, accountJID: #require(BareJID.parse(testJIDString)), accountID: accountID
            )
        case .chat, .room:
            if isOMEMO {
                await omemoService.handleEvent(encryptedMessageEvent(stanza, body: nil, reason: .notForThisDevice), accountID: accountID)
            } else {
                await chatService.handleEvent(origin == .room ? .roomMessageReceived(stanza) : .messageReceived(stanza), accountID: accountID)
            }
        }

        let stored = try #require(try await messages(in: origin == .room ? roomChat : chat).first)
        #expect(stored.isUndecryptable)
        #expect(stored.body.isEmpty)
        // The archive is not decrypted yet, so its OMEMO message is undecryptable with no reason given.
        let expected: UndecryptableReason? = isOMEMO ? (origin == .archive ? nil : .notForThisDevice) : .otherMethod(name: "OpenPGP for XMPP")
        #expect(stored.undecryptableReason == expected)
    }

    @Test func `a headline encrypted with another method shows its notice in the chat with its sender`() async throws {
        var stanza = XMPPMessage(type: .headline, to: .bare(contact), id: "h1")
        stanza.from = try .full(#require(FullJID.parse("\(contact)/desktop")))
        stanza.body = "This message is encrypted with OpenPGP"
        stanza.element.addChild(openPGPEncryption)

        await chatService.handleEvent(.messageReceived(stanza), accountID: accountID)

        let stored = try #require(try await messages(in: chat).first)
        #expect(stored.body.isEmpty)
        #expect(stored.undecryptableReason == .otherMethod(name: "OpenPGP for XMPP"))
    }

    enum PayloadlessOrigin: CaseIterable {
        case chat, room, carbon, archive
    }

    @Test(arguments: PayloadlessOrigin.allCases)
    func `a message naming OMEMO without its payload shows a notice`(origin: PayloadlessOrigin) async throws {
        var stanza = XMPPMessage(type: origin == .room ? .groupchat : .chat, to: JID.parse(testJIDString), id: "p1")
        stanza.from = JID.parse(origin == .room ? "\(room)/carol" : "\(contact)/desktop")
        stanza.element.addChild(DuckoXMPP.XMLElement(name: "encryption", namespace: XMPPNamespaces.eme, attributes: ["namespace": XMPPNamespaces.omemo]))

        switch origin {
        case .chat: await chatService.handleEvent(.messageReceived(stanza), accountID: accountID)
        case .room: await chatService.handleEvent(.roomMessageReceived(stanza), accountID: accountID)
        case .carbon: await chatService.handleEvent(.messageCarbonReceived(ForwardedMessage(message: stanza, timestamp: nil)), accountID: accountID)
        case .archive:
            let archived = ArchivedMessage(messageID: "a4", serverID: nil, forwarded: ForwardedMessage(message: stanza, timestamp: "2026-03-01T10:00:00Z"))
            _ = try await chatService.convertAndDedup(
                archived: [archived], conversation: chat, accountJID: #require(BareJID.parse(testJIDString)), accountID: accountID
            )
        }

        let stored = try #require(try await messages(in: origin == .room ? roomChat : chat).first)
        #expect(stored.body.isEmpty)
        #expect(stored.undecryptableReason == .decryptionFailed)
    }

    /// Only the encrypted payload is the message, and the archive path cannot read it yet.
    @Test func `an archived OMEMO message takes no reply or file from next to its payload`() async throws {
        var stanza = encryptedStanza(from: "\(contact)/desktop", to: testJIDString, id: "x1")
        stanza.element.addChild(DuckoXMPP.XMLElement(name: "reply", namespace: XMPPNamespaces.messageReply, attributes: ["id": "m0", "to": testJIDString]))
        var oob = DuckoXMPP.XMLElement(name: "x", namespace: XMPPNamespaces.oob)
        oob.setChildText(named: "url", to: "https://example.com/injected.png")
        stanza.element.addChild(oob)
        let archived = ArchivedMessage(messageID: "a3", serverID: nil, forwarded: ForwardedMessage(message: stanza, timestamp: "2026-03-01T10:00:00Z"))

        _ = try await chatService.convertAndDedup(
            archived: [archived], conversation: chat, accountJID: #require(BareJID.parse(testJIDString)), accountID: accountID
        )

        let stored = try #require(try await messages(in: chat).first)
        #expect(stored.isUndecryptable)
        #expect(stored.replyToID == nil)
        #expect(stored.replyToJID == nil)
        #expect(stored.attachments.isEmpty)
    }

    @Test func `an archived OMEMO message carrying only key material stores nothing`() async throws {
        var stanza = try XMPPMessage(type: .chat, to: .bare(#require(BareJID.parse(testJIDString))), id: "k1")
        stanza.from = .bare(contact)
        stanza.element.addChild(DuckoXMPP.XMLElement(name: "encrypted", namespace: XMPPNamespaces.omemo))
        let archived = ArchivedMessage(messageID: "a2", serverID: nil, forwarded: ForwardedMessage(message: stanza, timestamp: nil))

        let converted = try await chatService.convertAndDedup(
            archived: [archived], conversation: chat, accountJID: #require(BareJID.parse(testJIDString)), accountID: accountID
        )

        #expect(converted.messages.isEmpty)
        #expect(try await messages(in: chat).isEmpty)
    }

    // MARK: - Envelope Time

    enum EnvelopeTime: CaseIterable {
        /// Held offline: the server's delay and the envelope agree on a time hours ago.
        case delayedAndStampedAlike
        /// The envelope names another time than the server's delay.
        case stampedHoursOffItsDelay
        /// An old message replayed without a delay to vouch for it.
        case oldWithoutDelay
    }

    @Test(arguments: EnvelopeTime.allCases)
    func `a message's envelope time has to match when it was sent`(time: EnvelopeTime) async throws {
        let sentAt = Date(timeIntervalSinceNow: -5 * 3600).formatted(.iso8601)
        var stanza = encryptedStanza(from: "\(contact)/desktop", to: testJIDString, id: "t1")
        if time != .oldWithoutDelay {
            stanza.element.addChild(DuckoXMPP.XMLElement(name: "delay", namespace: XMPPNamespaces.delay, attributes: ["from": "example.com", "stamp": sentAt]))
        }
        let envelopeTime = time == .stampedHoursOffItsDelay ? Date().formatted(.iso8601) : sentAt

        await omemoService.handleEvent(
            .omemoEncryptedMessageReceived(message: stanza, outcome: encryptedOutcome(of: stanza, body: "late", sentTime: envelopeTime)),
            accountID: accountID
        )

        let stored = try #require(try await messages(in: chat).first)
        if time == .delayedAndStampedAlike {
            #expect(stored.body == "late")
            #expect(stored.timestamp == Date(xmppTimestamp: sentAt))
        } else {
            #expect(stored.undecryptableReason == .mismatchedEnvelope)
        }
    }

    // MARK: - Chat States

    /// The stanza around an encrypted message tells nothing; the chat state inside its envelope does.
    @Test(arguments: [true, false])
    func `an encrypted reply keeps chat states going only when its envelope carries one`(carriesState: Bool) async {
        var stanza = encryptedStanza(from: "\(contact)/desktop", to: testJIDString, id: "s1")
        stanza.element.addChild(DuckoXMPP.XMLElement(name: "active", namespace: XMPPNamespaces.chatStates))
        let reply = DuckoXMPP.XMLElement(name: "reply", namespace: XMPPNamespaces.messageReply, attributes: ["id": "m0", "to": testJIDString])
        let state = DuckoXMPP.XMLElement(name: "active", namespace: XMPPNamespaces.chatStates)

        await omemoService.handleEvent(encryptedMessageEvent(stanza, body: "sure", elements: carriesState ? [reply, state] : [reply]), accountID: accountID)

        #expect(chatService.sendsChatStates(to: .contact(contact), accountID: accountID) == carriesState)
    }

    // MARK: - Rooms

    @Test func `an encrypted room message is stored under the occupant's nickname, and one the room hides the sender of as its notice`() async throws {
        let readable = encryptedStanza(type: .groupchat, from: "\(room)/carol", to: testJIDString, id: "r1")
        let hidden = encryptedStanza(type: .groupchat, from: "\(room)/dave", to: testJIDString, id: "r2")

        await omemoService.handleEvent(encryptedMessageEvent(readable, body: "hello room"), accountID: accountID)
        await omemoService.handleEvent(encryptedMessageEvent(hidden, body: nil, reason: .senderHidden), accountID: accountID)

        let stored = try await messages(in: roomChat)
        #expect(stored.map(\.fromJID) == ["carol", "dave"])
        #expect(stored.map(\.type) == ["groupchat", "groupchat"])
        #expect(stored.first?.body == "hello room")
        #expect(stored.last?.undecryptableReason == .senderHidden)
    }

    /// A room's correction names the message by its own id, and a retraction by the stanza-id the room assigned to it.
    @Test(arguments: [true, false])
    func `a decrypted room correction or retraction applies to the occupant's encrypted message and is reported`(isRetraction: Bool) async throws {
        await transcripts.addMessage(ChatMessage(
            id: UUID(), conversationID: roomChat.id, stanzaID: "m1", serverID: "R1", fromJID: "carol", body: "helo", timestamp: Date(),
            isOutgoing: false, isDelivered: false, isEdited: false, type: "groupchat", isEncrypted: true
        ))
        let reported = EventLog()
        chatService.onDecryptedAmendment = { event, _ in reported.events.append(event) }
        let stanza = encryptedStanza(type: .groupchat, from: "\(room)/carol", to: testJIDString, id: "r7")

        await chatService.receiveEncryptedMessage(
            stanza,
            content: EncryptedContent(encryptedOutcome(of: stanza, body: "hello", elements: [amendment(of: isRetraction ? "R1" : "m1", isRetraction: isRetraction)])),
            origin: .live, accountID: accountID
        )

        let stored = try await messages(in: roomChat)
        #expect(stored.count == 1)
        #expect(isRetraction ? stored.first?.isRetracted == true : stored.first?.body == "hello")
        #expect(reported.events.count == 1)
    }

    @Test func `encrypted join history is stored without counting as unread`() async throws {
        await chatService.handleEvent(.roomJoined(room: room, occupancy: RoomOccupancy(nickname: "me", occupants: [], subject: nil), isNewlyCreated: false), accountID: accountID)
        var stanza = encryptedStanza(type: .groupchat, from: "\(room)/carol", to: testJIDString, id: "h1")
        stanza.element.addChild(DuckoXMPP.XMLElement(name: "delay", namespace: XMPPNamespaces.delay, attributes: ["from": room.description, "stamp": "2026-03-01T10:00:00Z"]))

        await omemoService.handleEvent(encryptedMessageEvent(stanza, body: "earlier"), accountID: accountID)

        let stored = try #require(try await messages(in: roomChat).first)
        #expect(stored.timestamp == Date(xmppTimestamp: "2026-03-01T10:00:00Z"))
        #expect(try await store.fetchConversations(for: accountID).first { $0.id == roomChat.id }?.unreadCount == 0)
    }

    @Test func `an encrypted message claiming to come from a room the user is not in creates nothing`() async throws {
        let stanza = encryptedStanza(type: .groupchat, from: "other@conference.example.com/carol", to: testJIDString, id: "u1")

        await omemoService.handleEvent(encryptedMessageEvent(stanza, body: "hello"), accountID: accountID)

        #expect(try await Set(store.fetchConversations(for: accountID).map(\.id)) == [chat.id, roomChat.id])
        #expect(await transcripts.messages.isEmpty)
    }

    /// The private chat with one occupant outlives the room, and still marks its address as a room's.
    @Test func `once its room is gone, an encrypted private message still lands in a private chat`() async throws {
        try await store.deleteConversation(roomChat.id)
        await store.addConversation(Conversation(
            id: UUID(), accountID: accountID, jid: room, type: .chat, isPinned: false, isMuted: false, unreadCount: 0,
            occupantNickname: "bob", createdAt: Date()
        ))
        let stanza = encryptedStanza(from: "\(room)/carol", to: "\(testJIDString)/laptop", id: "p2")

        await omemoService.handleEvent(encryptedMessageEvent(stanza, body: "psst"), accountID: accountID)

        let conversations = try await store.fetchConversations(for: accountID).filter { $0.jid == room }
        let privateChat = try #require(conversations.first { $0.occupantNickname == "carol" })
        #expect(conversations.count == 2)
        #expect(try await messages(in: privateChat).map(\.body) == ["psst"])
    }

    @Test func `an encrypted room private message lands in the private chat with the occupant`() async throws {
        let stanza = encryptedStanza(from: "\(room)/carol", to: "\(testJIDString)/laptop", id: "p1")

        await omemoService.handleEvent(encryptedMessageEvent(stanza, body: "psst"), accountID: accountID)

        let conversations = try await store.fetchConversations(for: accountID)
        let privateChat = try #require(conversations.first { $0.jid == room && $0.occupantNickname == "carol" })
        #expect(try await messages(in: privateChat).map(\.body) == ["psst"])
        #expect(try await messages(in: roomChat).isEmpty)
    }

    /// The device that sent a room message never encrypts it for itself, so the room's echo cannot be read here.
    @Test func `the room's echo of the user's own encrypted message records its stanza-id on the sent row and adds none`() async throws {
        let own = ChatMessage(
            id: UUID(), conversationID: roomChat.id, stanzaID: "e1", fromJID: room.description, body: "mine", timestamp: Date(),
            isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat", isEncrypted: true
        )
        await transcripts.addMessage(own)
        var echo = encryptedStanza(type: .groupchat, from: "\(room)/me", to: testJIDString, id: "e1")
        echo.element.addChild(DuckoXMPP.XMLElement(name: "stanza-id", namespace: XMPPNamespaces.stanzaID, attributes: ["id": "R9", "by": room.description]))

        await omemoService.handleEvent(encryptedMessageEvent(echo, body: nil, reason: .notForThisDevice), accountID: accountID)

        let stored = try await messages(in: roomChat)
        #expect(stored.map(\.id) == [own.id])
        #expect(stored.first?.serverID == "R9")
    }

    /// Another of the user's devices, writing under the same nickname, did not encrypt for this one.
    @Test func `an unreadable room message under the user's nickname that this device did not send shows its notice`() async throws {
        var echo = encryptedStanza(type: .groupchat, from: "\(room)/me", to: testJIDString, id: "o1")
        echo.element.addChild(DuckoXMPP.XMLElement(name: "stanza-id", namespace: XMPPNamespaces.stanzaID, attributes: ["id": "R10", "by": room.description]))

        await omemoService.handleEvent(encryptedMessageEvent(echo, body: nil, reason: .notForThisDevice), accountID: accountID)

        let stored = try #require(try await messages(in: roomChat).first)
        #expect(stored.isOutgoing)
        #expect(stored.serverID == "R10")
        #expect(stored.undecryptableReason == .notForThisDevice)
    }
}

// MARK: - Helpers

/// The events `onDecryptedAmendment` reported.
private final class EventLog {
    var events: [XMPPEvent] = []
}

private func amendment(of originalID: String, isRetraction: Bool) -> DuckoXMPP.XMLElement {
    isRetraction
        ? DuckoXMPP.XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": originalID])
        : DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": originalID])
}

private func plaintextAmendment(of originalID: String, isRetraction: Bool = false, body: String = "injected", from: String, to recipient: String) -> XMPPMessage {
    var message = XMPPMessage(type: .chat, to: JID.parse(recipient)!, id: "fix-\(originalID)")
    message.from = JID.parse(from)
    message.body = body
    message.element.addChild(amendment(of: originalID, isRetraction: isRetraction))
    return message
}

private let openPGPEncryption = DuckoXMPP.XMLElement(
    name: "encryption", namespace: XMPPNamespaces.eme, attributes: ["namespace": "urn:xmpp:openpgp:0", "name": "Something else"]
)

private func encryptedStanza(type: XMPPMessage.MessageType = .chat, from: String, to: String, id: String) -> XMPPMessage {
    var message = makeEncryptedStanza(from: JID.parse(from)!, id: id, type: type)
    message.to = JID.parse(to)
    return message
}
