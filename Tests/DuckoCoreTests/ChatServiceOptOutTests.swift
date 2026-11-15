import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let bob = BareJID(localPart: "bob", domainPart: "example.com")!
private let room = BareJID(localPart: "room", domainPart: "conference.example.com")!
private let reason = "No OMEMO on this phone"

/// A contact's OMEMO opt-out (XEP-0384 §5.7) blocks encrypted sends until the user switches encryption off, and is
/// recorded once however often it arrives.
@MainActor
struct ChatServiceOptOutTests {
    /// The `<opt-out>` element, with `reason`.
    private static func optOutElement() -> DuckoXMPP.XMLElement {
        var optOut = DuckoXMPP.XMLElement(name: "opt-out", namespace: XMPPNamespaces.omemo)
        optOut.setChildText(named: "reason", to: reason)
        return optOut
    }

    /// The event for an encrypted message from `from`, decrypted to `body` (none when nil) and `elements`, which bob's
    /// device `senderDeviceID` encrypted.
    private static func decrypted(
        from: String, id: String, type: XMPPMessage.MessageType = .chat, body: String?, elements: [DuckoXMPP.XMLElement] = [],
        delayStamp: String? = nil, senderDeviceID: UInt32 = 200
    ) throws -> XMPPEvent {
        let sender = try #require(JID.parse(from))
        var stanza = makeEncryptedStanza(from: sender, id: id, type: type)
        if let delayStamp {
            stanza.element.addChild(DuckoXMPP.XMLElement(
                name: "delay", namespace: XMPPNamespaces.delay, attributes: ["from": room.description, "stamp": delayStamp]
            ))
        }
        var content = DuckoXMPP.XMLElement(name: "message", attributes: stanza.element.attributes)
        if let body {
            content.setChildText(named: "body", to: body)
        }
        for element in elements {
            content.addChild(element)
        }
        let message = OMEMODecryptedMessage(message: XMPPMessage(element: content), sentTime: nil, senderJID: bob, senderDeviceID: senderDeviceID)
        return .omemoEncryptedMessageReceived(message: stanza, outcome: .decrypted(message), roomAuthor: nil)
    }

    private static func optOut(
        from: String = "\(bob)/phone", id: String = "opt-1", type: XMPPMessage.MessageType = .chat, body: String? = nil, senderDeviceID: UInt32 = 200
    ) throws -> XMPPEvent {
        try decrypted(from: from, id: id, type: type, body: body, elements: [optOutElement()], senderDeviceID: senderDeviceID)
    }

    /// Records bob's device 300 as not trusted for encryption.
    private func distrustDevice300(in harness: EncryptedSendHarness) async throws {
        try await harness.omemoStore.saveTrust(OMEMOTrust(
            accountJID: testJIDString, peerJID: bob.description, deviceID: 300, fingerprint: "", trustLevel: .untrusted
        ))
    }

    private func conversation(_ jid: BareJID, in harness: EncryptedSendHarness) async throws -> Conversation {
        try #require(try await harness.chatService.store.fetchConversations(for: harness.accountID).first { $0.jid == jid })
    }

    private func notes(in conversation: Conversation, of harness: EncryptedSendHarness) async throws -> [TimelineNote] {
        try await harness.transcripts.fetchNotes(for: conversation.id, since: nil, before: nil)
    }

    private func expectBlocked(by requester: String, _ send: () async throws -> Void) async {
        let error = await #expect(throws: ChatService.ChatServiceError.self) { try await send() }
        guard case let .plaintextRequested(blockedBy, blockedReason)? = error else {
            Issue.record("Expected a plaintext request, got \(String(describing: error))")
            return
        }
        #expect(blockedBy == requester)
        #expect(blockedReason == reason)
    }

    /// The last message stanza the account sent.
    private func lastSentMessage(of harness: EncryptedSendHarness) async -> String? {
        await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }.last { $0.hasPrefix("<message") }
    }

    @Test func `an opt-out without a body is recorded with a note, and blocks the next encrypted send`() async throws {
        let harness = try await EncryptedSendHarness.connect()

        try await harness.omemoService.handleEvent(Self.optOut(), accountID: harness.accountID)

        let chat = try await conversation(bob, in: harness)
        #expect(chat.plaintextRequest == PlaintextRequest(requester: bob.description, reason: reason, isConfirmed: false))
        let notes = try await notes(in: chat, of: harness)
        #expect(notes.map(\.kind) == [.plaintextRequested])
        #expect(notes.first?.subject == nil)
        #expect(notes.first?.detail == reason)
        #expect(notes.first?.text(contactName: "Bob") == "Bob asked for unencrypted messages (\(reason))")
        await expectBlocked(by: bob.description) {
            try await harness.chatService.sendMessage(to: bob, body: "secret", accountID: harness.accountID)
        }
        #expect(await lastSentMessage(of: harness) == nil)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `once the user switches encryption off, the send goes out in plaintext`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        try await harness.omemoService.handleEvent(Self.optOut(), accountID: harness.accountID)
        let chat = try await conversation(bob, in: harness)

        try await harness.chatService.setEncryptionEnabled(false, for: chat.id, accountID: harness.accountID)
        try await harness.chatService.sendMessage(to: bob, body: "hello", accountID: harness.accountID)

        let sent = try #require(await lastSentMessage(of: harness))
        #expect(sent.contains("<body>hello</body>"))
        #expect(!sent.contains("<encrypted"))
        #expect(try await conversation(bob, in: harness).plaintextRequest?.isConfirmed == true)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `the contact's encrypted messages after the user confirmed leave one note and encryption off`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        try await harness.omemoService.handleEvent(Self.optOut(), accountID: harness.accountID)
        let chat = try await conversation(bob, in: harness)
        try await harness.chatService.setEncryptionEnabled(false, for: chat.id, accountID: harness.accountID)

        try await harness.omemoService.handleEvent(Self.decrypted(from: "\(bob)/phone", id: "m1", body: "back on OMEMO"), accountID: harness.accountID)
        try await harness.omemoService.handleEvent(Self.decrypted(from: "\(bob)/phone", id: "m2", body: "still here"), accountID: harness.accountID)

        let stored = try await conversation(bob, in: harness)
        #expect(stored.plaintextRequest == nil)
        #expect(!stored.encryptionEnabled)
        #expect(try await notes(in: chat, of: harness).map(\.kind) == [.plaintextRequested, .encryptionResumedByContact])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `a room member's opt-out blocks encrypted room sends`() async throws {
        let harness = try await EncryptedSendHarness.connect()

        try await harness.omemoService.handleEvent(Self.optOut(from: "\(room)/bob", type: .groupchat), accountID: harness.accountID)

        #expect(try await conversation(room, in: harness).plaintextRequest == PlaintextRequest(requester: "bob", reason: reason, isConfirmed: false))
        await expectBlocked(by: "bob") {
            try await harness.chatService.sendGroupMessage(to: room, body: "secret", accountID: harness.accountID)
        }
        #expect(await lastSentMessage(of: harness) == nil)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `an opt-out delivered again adds no second note, before or after the user confirmed`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        try await harness.omemoService.handleEvent(Self.optOut(), accountID: harness.accountID)
        try await harness.omemoService.handleEvent(Self.optOut(), accountID: harness.accountID)
        let chat = try await conversation(bob, in: harness)
        try await harness.chatService.setEncryptionEnabled(false, for: chat.id, accountID: harness.accountID)

        try await harness.omemoService.handleEvent(Self.optOut(), accountID: harness.accountID)

        #expect(try await notes(in: chat, of: harness).map(\.kind) == [.plaintextRequested])
        #expect(try await conversation(bob, in: harness).plaintextRequest?.isConfirmed == true)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// A room's history replayed on join carries the room's stamp, which a clock running ahead of this one makes later
    /// than when the opt-out arrived live, a minute ago. The user has answered it and switched encryption back on since.
    @Test func `once the user switched room encryption back on, a rejoin replaying the old opt-out leaves room sends unblocked`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let roomChat = try await conversation(room, in: harness)
        try await harness.transcripts.appendNote(TimelineNote(
            conversationID: roomChat.id, timestamp: Date().addingTimeInterval(-60), kind: .plaintextRequested, subject: "bob", detail: reason
        ))

        await harness.chatService.roomService.handleRoomJoined(
            room: room, occupancy: RoomOccupancy(nickname: "me", occupants: [], subject: nil), isNewlyCreated: false, accountID: harness.accountID
        )
        try await harness.omemoService.handleEvent(
            Self.decrypted(
                from: "\(room)/bob", id: "opt-1", type: .groupchat, body: nil, elements: [Self.optOutElement()],
                delayStamp: Date().addingTimeInterval(-30).formatted(.iso8601)
            ),
            accountID: harness.accountID
        )

        #expect(try await conversation(room, in: harness).plaintextRequest == nil)
        try await harness.chatService.sendGroupMessage(to: room, body: "secret", accountID: harness.accountID)
        #expect(await lastSentMessage(of: harness)?.contains("<encrypted") == true)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// A 1:1 chat's note names no subject, and a room's names the occupant, so each is found by what it names.
    @Test(arguments: [false, true])
    func `once the user switched encryption back on, a catch-up reading the old opt-out again leaves sends unblocked`(inRoom: Bool) async throws {
        let harness = try await EncryptedSendHarness.connect()
        let event = try inRoom ? Self.optOut(from: "\(room)/bob", type: .groupchat) : Self.optOut()
        try await harness.omemoService.handleEvent(event, accountID: harness.accountID)
        let chat = try await conversation(inRoom ? room : bob, in: harness)
        let noted = try #require(try await notes(in: chat, of: harness).first)
        try await harness.chatService.setEncryptionEnabled(false, for: chat.id, accountID: harness.accountID)
        try await harness.chatService.setEncryptionEnabled(true, for: chat.id, accountID: harness.accountID)

        let message = XMPPMessage(element: Self.optOutMessage())
        try await harness.chatService.noteOptOut(
            carriedBy: ReceivedDecryptedMessage(
                message: message, sender: inRoom ? "bob" : bob.description, sentTime: noted.timestamp, isFromUntrustedDevice: false
            ),
            in: conversation(inRoom ? room : bob, in: harness), accountID: harness.accountID
        )

        #expect(try await conversation(inRoom ? room : bob, in: harness).plaintextRequest == nil)
        #expect(try await notes(in: chat, of: harness).count == 1)
        if inRoom {
            try await harness.chatService.sendGroupMessage(to: room, body: "secret", accountID: harness.accountID)
        } else {
            try await harness.chatService.sendMessage(to: bob, body: "secret", accountID: harness.accountID)
        }
        #expect(await lastSentMessage(of: harness)?.contains("<encrypted") == true)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// A decrypted message carrying only an opt-out.
    private static func optOutMessage() -> DuckoXMPP.XMLElement {
        var message = DuckoXMPP.XMLElement(name: "message", attributes: ["type": "groupchat"])
        message.addChild(optOutElement())
        return message
    }

    @Test func `an encrypted message read by a catch-up after the user confirmed drops the request with one note`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        try await harness.omemoService.handleEvent(Self.optOut(), accountID: harness.accountID)
        let chat = try await conversation(bob, in: harness)
        try await harness.chatService.setEncryptionEnabled(false, for: chat.id, accountID: harness.accountID)

        let resumed = try await harness.chatService.noteResumedEncryption(in: conversation(bob, in: harness), accountID: harness.accountID)

        #expect(resumed)
        let stored = try await conversation(bob, in: harness)
        #expect(stored.plaintextRequest == nil)
        #expect(!stored.encryptionEnabled)
        #expect(try await notes(in: chat, of: harness).map(\.kind) == [.plaintextRequested, .encryptionResumedByContact])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `a second opt-out after the user confirmed adds no note of encryption resuming and keeps the request`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        try await harness.omemoService.handleEvent(Self.optOut(), accountID: harness.accountID)
        let chat = try await conversation(bob, in: harness)
        try await harness.chatService.setEncryptionEnabled(false, for: chat.id, accountID: harness.accountID)

        try await harness.omemoService.handleEvent(Self.optOut(id: "opt-2", body: "Please write unencrypted"), accountID: harness.accountID)

        #expect(try await notes(in: chat, of: harness).map(\.kind) == [.plaintextRequested])
        #expect(try await conversation(bob, in: harness).plaintextRequest?.isConfirmed == true)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `an opt-out with a body in a new chat leaves encryption off, and the contact's next encrypted message is noted once`() async throws {
        let harness = try await EncryptedSendHarness.connect(encryptionEnabled: false)

        try await harness.omemoService.handleEvent(Self.optOut(body: "Please write unencrypted"), accountID: harness.accountID)

        let chat = try await conversation(bob, in: harness)
        #expect(!chat.encryptionEnabled)
        #expect(chat.plaintextRequest?.isConfirmed == true)
        #expect(try await notes(in: chat, of: harness).map(\.kind) == [.plaintextRequested])

        try await harness.omemoService.handleEvent(Self.decrypted(from: "\(bob)/phone", id: "m1", body: "back on OMEMO"), accountID: harness.accountID)
        try await harness.omemoService.handleEvent(Self.decrypted(from: "\(bob)/phone", id: "m2", body: "still here"), accountID: harness.accountID)

        #expect(try await !conversation(bob, in: harness).encryptionEnabled)
        #expect(try await notes(in: chat, of: harness).map(\.kind) == [.plaintextRequested, .encryptionResumedByContact])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Decryption admits a device the user has not trusted, so its opt-out could otherwise block encrypted sends and
    /// offer plaintext in the contact's name.
    @Test(arguments: [false, true])
    func `an opt-out from a device not trusted for encryption records nothing, and sends stay encrypted`(inRoom: Bool) async throws {
        let harness = try await EncryptedSendHarness.connect()
        try await distrustDevice300(in: harness)

        let event = try inRoom ? Self.optOut(from: "\(room)/bob", type: .groupchat, senderDeviceID: 300) : Self.optOut(senderDeviceID: 300)
        await harness.omemoService.handleEvent(event, accountID: harness.accountID)

        let chat = try await conversation(inRoom ? room : bob, in: harness)
        #expect(chat.plaintextRequest == nil)
        #expect(try await notes(in: chat, of: harness).isEmpty)
        if inRoom {
            try await harness.chatService.sendGroupMessage(to: room, body: "secret", accountID: harness.accountID)
        } else {
            try await harness.chatService.sendMessage(to: bob, body: "secret", accountID: harness.accountID)
        }
        #expect(await lastSentMessage(of: harness)?.contains("<encrypted") == true)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `an encrypted message from a device not trusted for encryption leaves the answered request in place`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        try await harness.omemoService.handleEvent(Self.optOut(), accountID: harness.accountID)
        let chat = try await conversation(bob, in: harness)
        try await harness.chatService.setEncryptionEnabled(false, for: chat.id, accountID: harness.accountID)
        try await distrustDevice300(in: harness)

        try await harness.omemoService.handleEvent(
            Self.decrypted(from: "\(bob)/tablet", id: "m1", body: "back on OMEMO", senderDeviceID: 300), accountID: harness.accountID
        )

        let stored = try await conversation(bob, in: harness)
        #expect(stored.plaintextRequest?.isConfirmed == true)
        #expect(!stored.encryptionEnabled)
        #expect(try await notes(in: chat, of: harness).map(\.kind) == [.plaintextRequested])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `an opt-out the user sent from another device is not recorded as the contact's request`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        var stanza = try makeEncryptedStanza(from: #require(JID.parse("\(testJIDString)/phone")), id: "opt-1")
        stanza.to = JID.parse("\(bob)/phone")
        var content = XMPPMessage(type: .chat, id: "opt-1")
        content.element.addChild(Self.optOutElement())

        await harness.chatService.receiveEncryptedMessage(
            stanza, content: .decrypted(content, sentTime: nil, isFromUntrustedDevice: false), origin: .carbon(isOutgoing: true, sentTime: Date()),
            accountID: harness.accountID
        )

        let chat = try await conversation(bob, in: harness)
        #expect(chat.plaintextRequest == nil)
        #expect(try await notes(in: chat, of: harness).isEmpty)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `a held request keeps the contact's encrypted message from switching encryption on`() async throws {
        let harness = try await EncryptedSendHarness.connect(encryptionEnabled: false)
        let chat = try await conversation(bob, in: harness)
        try await harness.chatService.store.updateConversation(chat.id) {
            $0.plaintextRequest = PlaintextRequest(requester: bob.description, reason: nil, isConfirmed: true)
        }
        try await harness.chatService.loadConversations(for: harness.accountID)

        await harness.chatService.enableEncryptionForContact(in: chat, accountID: harness.accountID)

        #expect(try await !conversation(bob, in: harness).encryptionEnabled)
        #expect(try await notes(in: chat, of: harness).isEmpty)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }
}
