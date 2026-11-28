import DuckoTestSupport
import Foundation
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let contact = BareJID(localPart: "bob", domainPart: "example.com")!
private let room = BareJID(localPart: "room", domainPart: "conference.example.com")!
private let account = BareJID.parse(testJIDString)!
/// When the archive stored its entries.
private let archiveStamp = "2026-03-01T10:00:00Z"

/// Encrypted entries of the account's and the room's archives are decrypted as they are read: catch-up in archive order,
/// key exchanges included, and scrollback only on sessions that exist.
@MainActor
struct ChatServiceArchiveDecryptionTests {
    /// A key exchange without a payload, such as a session reset sends, belongs in no chat, yet the messages after it
    /// are encrypted with the session it starts. A message that came live while this device missed the key exchange
    /// shows a notice until then, which its archived copy replaces.
    @Test(arguments: [false, true])
    func `catch-up takes up a key exchange without a payload and decrypts the message after it, answering once`(cameLive: Bool) async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        let bob = TestDevice(keys: harness.bob, jid: "\(contact)/desktop", peerBundle: harness.ownBundle)
        let keyExchange = try await bob.keyExchange()
        bob.confirmSession()
        let message = try await bob.message([bodyElement("after the reset")], id: "m2")
        try #require(message.element.child(named: "encrypted").map(isKeyExchange) == false)
        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact && $0.isDirectChat })
        if cameLive {
            let module = try #require(await harness.accountService.client(for: harness.accountID)?.module(ofType: OMEMOModule.self))
            let outcome = try #require(module.receiveForwardedMessage(message))
            await harness.omemoService.handleEvent(
                .omemoEncryptedMessageReceived(message: message, outcome: outcome, roomAuthor: nil), accountID: harness.accountID
            )
            try #require(try await harness.transcripts.fetchMessages(for: chat.id, before: nil, limit: 10).first?.isUndecryptable == true)
        }

        try await harness.catchUp(account: [("A1", keyExchange), ("A2", message)])

        let stored = try await harness.storedMessage(archiveID: "A2", in: contact)
        #expect(stored?.body == "after the reset")
        #expect(stored?.isUndecryptable == false)
        #expect(try await harness.transcripts.fetchMessages(for: chat.id, before: nil, limit: 10).count == 1)
        try await awaitSent(on: harness.transport, matching: Self.isEmptyMessage(to: contact))
        #expect(await harness.transport.sentStrings.count(where: Self.isEmptyMessage(to: contact)) == 1)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// XEP-0420 bounds how far an envelope's time may be from when its message was sent, archived or not.
    @Test(arguments: [0, 2 * 60 * 60])
    func `catch-up stores a key exchange's message decrypted, unless its envelope is stamped far off its archive time`(
        offset: TimeInterval
    ) async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        let bob = TestDevice(keys: harness.bob, jid: "\(contact)/desktop", peerBundle: harness.ownBundle)
        let sentAt = try Date.ISO8601FormatStyle().parse(archiveStamp).addingTimeInterval(offset)
        let message = try await bob.message([bodyElement("hi")], id: "m1", time: sentAt.formatted(.iso8601))

        try await harness.catchUp(account: [("A1", message)])

        let stored = try #require(try await harness.storedMessage(archiveID: "A1", in: contact))
        if offset == 0 {
            #expect(stored.body == "hi")
            #expect(!stored.isUndecryptable)
        } else {
            #expect(stored.isUndecryptable)
            #expect(stored.undecryptableReason == .mismatchedEnvelope)
        }
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The room's archive records who wrote each entry, which the live occupant list may no longer show.
    @Test func `a room archive entry decrypts with the session of the real JID its archive records`() async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        let bob = TestDevice(keys: harness.bob, jid: "\(contact)/desktop", peerBundle: harness.ownBundle)
        var message = try await bob.roomMessage("hello room", id: "g1")
        var item = DuckoXMPP.XMLElement(name: "x", namespace: XMPPNamespaces.mucUser)
        item.addChild(DuckoXMPP.XMLElement(name: "item", attributes: ["jid": "\(contact)/desktop"]))
        message.element.addChild(item)

        try await harness.catchUp(account: [], room: [("R1", message)])

        let stored = try await harness.storedMessage(archiveID: "R1", in: room)
        #expect(stored?.body == "hello room")
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Legacy clients encrypt only the body, and leave their fallback text beside the payload.
    @Test(arguments: [false, true])
    func `catch-up decrypts a legacy message from the account's archive and the room's`(isRoom: Bool) async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        var sender = try LegacyOMEMOSender(identity: OMEMOIdentityKeyPair(), deviceID: 300, to: harness.ownKeys)
        var message = XMPPMessage(type: isRoom ? .groupchat : .chat, to: JID.parse("\(testJIDString)/ducko"), id: "l1")
        message.from = JID.parse(isRoom ? "\(room)/bobby" : "\(contact)/desktop")
        message.body = "I sent you an OMEMO encrypted message but your client doesn't seem to support that."
        try message.element.addChild(sender.encrypted("from legacy"))
        if isRoom {
            var item = DuckoXMPP.XMLElement(name: "x", namespace: XMPPNamespaces.mucUser)
            item.addChild(DuckoXMPP.XMLElement(name: "item", attributes: ["jid": "\(contact)/desktop"]))
            message.element.addChild(item)
        }

        try await harness.catchUp(account: isRoom ? [] : [("A1", message)], room: isRoom ? [("R1", message)] : [])

        let stored = try await harness.storedMessage(archiveID: isRoom ? "R1" : "A1", in: isRoom ? room : contact)
        #expect(stored?.body == "from legacy")
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The account's archive records no occupant's real JID, and a private message must not be taken for a 1:1 message
    /// from the room's address.
    @Test func `an archived room private message read before the room is joined stays a notice and starts no session with the room`() async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        let bob = TestDevice(keys: harness.bob, jid: "\(room)/bobby", peerBundle: harness.ownBundle)
        let message = try await bob.message([bodyElement("psst")], id: "p1")

        try await harness.catchUp(account: [("A1", message)])

        let privateChat = try #require(harness.chatService.openConversations.first { $0.jid == room && $0.occupantNickname == "bobby" })
        let stored = try #require(try await harness.transcripts.findMessage(serverID: "A1", conversationID: privateChat.id))
        #expect(stored.isUndecryptable)
        let module = try #require(await harness.accountService.client(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        #expect(module.state.withLock { $0.sessions.keys.allSatisfy { $0.jid != room } })
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Scrollback reads older entries, whose key exchanges can be older than the sessions in use.
    @Test func `scrollback leaves a key exchange a notice and decrypts a message on an existing session`() async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        let bob = try await harness.liveSession()
        let otherKeys = try EncryptedSendHarness.device(300, preKeyID: 9).keys
        try await harness.omemoStore.saveTrust(OMEMOTrust(
            accountJID: testJIDString, peerJID: contact.description, deviceID: 300, fingerprint: "", trustLevel: .trusted
        ))
        let otherDevice = TestDevice(keys: otherKeys, jid: "\(contact)/tablet", peerBundle: harness.ownBundle)
        let keyExchange = try await otherDevice.message([bodyElement("from the tablet")], id: "k1")
        let message = try await bob.message([bodyElement("on the session")], id: "m1")

        _ = try await harness.scrollBack([("A1", keyExchange), ("A2", message)])

        let notice = try await harness.storedMessage(archiveID: "A1", in: contact)
        #expect(notice?.isUndecryptable == true)
        let decrypted = try await harness.storedMessage(archiveID: "A2", in: contact)
        #expect(decrypted?.body == "on the session")
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// A notice scrollback stored, because it took up no key exchange, is read again by catch-up, which can.
    @Test func `catch-up decrypts an entry scrollback stored as a notice, and upgrades the notice`() async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        let bob = TestDevice(keys: harness.bob, jid: "\(contact)/desktop", peerBundle: harness.ownBundle)
        let message = try await bob.message([bodyElement("hi")], id: "m1")
        _ = try await harness.scrollBack([("A1", message)])
        let notice = try #require(try await harness.storedMessage(archiveID: "A1", in: contact))
        try #require(notice.isUndecryptable)

        try await harness.catchUp(account: [("A1", message)])

        let upgraded = try #require(try await harness.storedMessage(archiveID: "A1", in: contact))
        #expect(upgraded.id == notice.id)
        #expect(upgraded.body == "hi")
        #expect(!upgraded.isUndecryptable)
        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact && $0.isDirectChat })
        #expect(try await harness.transcripts.fetchMessages(for: chat.id, before: nil, limit: 10).count(where: { $0.serverID == "A1" }) == 1)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Scrollback can read an opt-out weeks old, which the contact may since have taken back. Catch-up reads only what
    /// came since the last connection.
    @Test(arguments: [true, false])
    func `an archived opt-out is recorded by catch-up and not by scrollback`(isCatchUp: Bool) async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        let bob = try await harness.liveSession()
        let message = try await bob.message([bodyElement("please write unencrypted"), optOutElement()], id: "o1")

        if isCatchUp {
            try await harness.catchUp(account: [("A1", message)])
        } else {
            _ = try await harness.scrollBack([("A1", message)])
        }

        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact && $0.isDirectChat })
        #expect(try await harness.storedMessage(archiveID: "A1", in: contact)?.body == "please write unencrypted")
        #expect((chat.plaintextRequest != nil) == isCatchUp)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Decryption admits a device the user has not trusted, so its archived opt-out could otherwise block encrypted sends
    /// and offer plaintext in the contact's name.
    @Test func `an archived opt-out from a device not trusted for encryption is not recorded by catch-up, and sends stay encrypted`() async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        try await harness.omemoStore.saveTrust(OMEMOTrust(
            accountJID: testJIDString, peerJID: contact.description, deviceID: 300, fingerprint: "", trustLevel: .untrusted
        ))
        let tablet = try TestDevice(keys: EncryptedSendHarness.device(300, preKeyID: 9).keys, jid: "\(contact)/tablet", peerBundle: harness.ownBundle)
        let message = try await tablet.message([bodyElement("please write unencrypted"), optOutElement()], id: "o1")

        try await harness.catchUp(account: [("A1", message)])
        try await awaitSent(on: harness.transport, matching: Self.isEmptyMessage(to: contact))

        let stored = try #require(try await harness.storedMessage(archiveID: "A1", in: contact))
        #expect(stored.body == "please write unencrypted")
        #expect(stored.isFromUntrustedDevice)
        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact && $0.isDirectChat })
        #expect(chat.plaintextRequest == nil)
        #expect(try await !harness.transcripts.fetchNotes(for: chat.id, since: nil, before: nil).contains { $0.kind == .plaintextRequested })
        try await harness.chatService.sendMessage(to: contact, body: "secret", accountID: harness.accountID)
        let sent = try #require(await harness.transport.sentStrings.last { $0.hasPrefix("<message") })
        #expect(sent.contains("<payload"))
        #expect(!sent.contains("<body"))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Contacts often write while the user is offline, so catch-up is where their return to encryption shows.
    @Test func `an encrypted message catch-up reads after the user answered an opt-out drops the request with a note`() async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        let bob = try await harness.liveSession()
        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact && $0.isDirectChat })
        var optOut = XMPPMessage(type: .chat, id: "o1")
        optOut.element.addChild(optOutElement())
        await harness.chatService.noteOptOut(
            carriedBy: ReceivedDecryptedMessage(message: optOut, sender: contact.description, sentTime: Date(), isFromUntrustedDevice: false),
            in: chat, accountID: harness.accountID
        )
        try await harness.chatService.setEncryptionEnabled(false, for: chat.id, accountID: harness.accountID)
        let message = try await bob.message([bodyElement("back to encrypting")], id: "m1")

        try await harness.catchUp(account: [("A1", message)])

        let stored = try #require(harness.chatService.openConversations.first { $0.id == chat.id })
        #expect(stored.plaintextRequest == nil)
        #expect(!stored.encryptionEnabled)
        let notes = try await harness.transcripts.fetchNotes(for: chat.id, since: nil, before: nil)
        #expect(notes.map(\.kind) == [.plaintextRequested, .encryptionResumedByContact])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// A contact often writes first while the user is offline, and the user's reply must not go out in plaintext.
    @Test func `the contact's first encrypted message read by catch-up switches encryption on, and the reply goes out encrypted`() async throws {
        let harness = try await EncryptedSendHarness.connect(encryptionEnabled: false, archiving: true)
        let bob = TestDevice(keys: harness.bob, jid: "\(contact)/desktop", peerBundle: harness.ownBundle)
        let message = try await bob.message([bodyElement("hi")], id: "m1")

        try await harness.catchUp(account: [("A1", message)])
        try await awaitSent(on: harness.transport, matching: Self.isEmptyMessage(to: contact))

        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact && $0.isDirectChat })
        #expect(chat.encryptionEnabled)
        #expect(try await harness.transcripts.fetchNotes(for: chat.id, since: nil, before: nil).map(\.kind) == [.encryptionEnabledByContact])
        try await harness.chatService.sendMessage(to: contact, body: "hello", accountID: harness.accountID)
        let reply = try #require(await harness.transport.sentStrings.last { $0.hasPrefix("<message") })
        #expect(reply.contains("<payload"))
        #expect(!reply.contains("<body"))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Scrollback stores a key exchange it does not take up as a notice, which catch-up then replaces with the message,
    /// new to the user, so the reply must not go out in plaintext either.
    @Test func `the contact's message read by catch-up over a notice switches encryption on, and the reply goes out encrypted`() async throws {
        let harness = try await EncryptedSendHarness.connect(encryptionEnabled: false, archiving: true)
        let bob = TestDevice(keys: harness.bob, jid: "\(contact)/desktop", peerBundle: harness.ownBundle)
        let message = try await bob.message([bodyElement("hi")], id: "m1")
        _ = try await harness.scrollBack([("A1", message)])
        try #require(try await harness.storedMessage(archiveID: "A1", in: contact)?.isUndecryptable == true)

        try await harness.catchUp(account: [("A1", message)])
        try await awaitSent(on: harness.transport, matching: Self.isEmptyMessage(to: contact))

        #expect(try await harness.storedMessage(archiveID: "A1", in: contact)?.isUndecryptable == false)
        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact && $0.isDirectChat })
        #expect(chat.encryptionEnabled)
        #expect(try await harness.transcripts.fetchNotes(for: chat.id, since: nil, before: nil).map(\.kind) == [.encryptionEnabledByContact])
        try await harness.chatService.sendMessage(to: contact, body: "hello", accountID: harness.accountID)
        let reply = try #require(await harness.transport.sentStrings.last { $0.hasPrefix("<message") })
        #expect(reply.contains("<payload"))
        #expect(!reply.contains("<body"))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// A notice catch-up replaces can stand for a message sent before the user answered the request, so only a new
    /// message counts as the contact sending encrypted messages again.
    @Test func `the contact's message read by catch-up over a notice after the user answered an opt-out keeps the request`() async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact && $0.isDirectChat })
        try await holdAnsweredRequest(in: chat, of: harness)
        let bob = TestDevice(keys: harness.bob, jid: "\(contact)/desktop", peerBundle: harness.ownBundle)
        let message = try await bob.message([bodyElement("hi")], id: "m1")
        _ = try await harness.scrollBack([("A1", message)])
        try #require(try await harness.storedMessage(archiveID: "A1", in: contact)?.isUndecryptable == true)

        try await harness.catchUp(account: [("A1", message)])

        #expect(try await harness.storedMessage(archiveID: "A1", in: contact)?.isUndecryptable == false)
        let stored = try #require(harness.chatService.openConversations.first { $0.id == chat.id })
        #expect(stored.plaintextRequest?.isConfirmed == true)
        #expect(!stored.encryptionEnabled)
        #expect(try await harness.transcripts.fetchNotes(for: chat.id, since: nil, before: nil).map(\.kind) == [.plaintextRequested])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `an encrypted message catch-up reads from a device not trusted for encryption leaves the answered request in place`() async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact && $0.isDirectChat })
        try await holdAnsweredRequest(in: chat, of: harness)
        try await harness.omemoStore.saveTrust(OMEMOTrust(
            accountJID: testJIDString, peerJID: contact.description, deviceID: 300, fingerprint: "", trustLevel: .untrusted
        ))
        let tablet = try TestDevice(keys: EncryptedSendHarness.device(300, preKeyID: 9).keys, jid: "\(contact)/tablet", peerBundle: harness.ownBundle)
        let message = try await tablet.message([bodyElement("back to encrypting")], id: "m1")

        try await harness.catchUp(account: [("A1", message)])

        #expect(try await harness.storedMessage(archiveID: "A1", in: contact)?.isFromUntrustedDevice == true)
        let stored = try #require(harness.chatService.openConversations.first { $0.id == chat.id })
        #expect(stored.plaintextRequest?.isConfirmed == true)
        #expect(!stored.encryptionEnabled)
        #expect(try await harness.transcripts.fetchNotes(for: chat.id, since: nil, before: nil).map(\.kind) == [.plaintextRequested])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Records the contact's opt-out in `chat`, which the user then answers by switching encryption off.
    private func holdAnsweredRequest(in chat: Conversation, of harness: EncryptedSendHarness) async throws {
        var optOut = XMPPMessage(type: .chat, id: "o1")
        optOut.element.addChild(optOutElement())
        await harness.chatService.noteOptOut(
            carriedBy: ReceivedDecryptedMessage(message: optOut, sender: contact.description, sentTime: Date(), isFromUntrustedDevice: false),
            in: chat, accountID: harness.accountID
        )
        try await harness.chatService.setEncryptionEnabled(false, for: chat.id, accountID: harness.accountID)
        try #require(harness.chatService.openConversations.first { $0.id == chat.id }?.plaintextRequest?.isConfirmed == true)
    }

    /// Catch-up loads the account's conversations only once its whole archive is read, so the chat it makes for the
    /// contact's first message is not loaded yet when that message switches encryption on.
    @Test func `the contact's first encrypted message read by catch-up switches on encryption in the chat catch-up makes for it`() async throws {
        let harness = try await EncryptedSendHarness.connect(encryptionEnabled: false, archiving: true)
        let seeded = try #require(harness.chatService.openConversations.first { $0.jid == contact && $0.isDirectChat })
        try await harness.chatService.store.deleteConversation(seeded.id)
        try await harness.chatService.loadConversations(for: harness.accountID)
        let bob = TestDevice(keys: harness.bob, jid: "\(contact)/desktop", peerBundle: harness.ownBundle)
        let message = try await bob.message([bodyElement("hi")], id: "m1")

        try await harness.catchUp(account: [("A1", message)])
        try await awaitSent(on: harness.transport, matching: Self.isEmptyMessage(to: contact))

        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact && $0.isDirectChat })
        #expect(chat.id != seeded.id)
        #expect(chat.encryptionEnabled)
        #expect(try await harness.transcripts.fetchNotes(for: chat.id, since: nil, before: nil).map(\.kind) == [.encryptionEnabledByContact])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test(arguments: [OMEMOTrustLevel.trusted, .untrusted])
    func `a message catch-up decrypts is marked when its sending device's trust row does not allow encrypting to it`(
        trust: OMEMOTrustLevel
    ) async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        try await harness.omemoStore.saveTrust(OMEMOTrust(
            accountJID: testJIDString, peerJID: contact.description, deviceID: 200, fingerprint: "", trustLevel: trust
        ))
        let bob = TestDevice(keys: harness.bob, jid: "\(contact)/desktop", peerBundle: harness.ownBundle)
        let message = try await bob.message([bodyElement("hi")], id: "m1")

        try await harness.catchUp(account: [("A1", message)])

        let stored = try #require(try await harness.storedMessage(archiveID: "A1", in: contact))
        #expect(stored.body == "hi")
        #expect(stored.isFromUntrustedDevice == (trust == .untrusted))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `an encrypted correction catch-up decrypts stores no row of its own`() async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        let bob = TestDevice(keys: harness.bob, jid: "\(contact)/desktop", peerBundle: harness.ownBundle)
        let original = try await bob.message([bodyElement("helo")], id: "m1")
        bob.confirmSession()
        let replace = DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": "m1"])
        let correction = try await bob.message([bodyElement("hello"), replace], id: "m2")

        try await harness.catchUp(account: [("A1", original), ("A2", correction)])

        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact && $0.isDirectChat })
        #expect(try await harness.transcripts.fetchMessages(for: chat.id, before: nil, limit: 10).map(\.serverID) == ["A1"])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The account's archive holds what the user sent from their other devices, which encrypt for this one too.
    @Test func `catch-up stores a message the user sent from another device decrypted, in the chat with its recipient`() async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        try await harness.omemoStore.saveTrust(OMEMOTrust(
            accountJID: testJIDString, peerJID: testJIDString, deviceID: 101, fingerprint: "", trustLevel: .trusted
        ))
        let phone = try TestDevice(keys: EncryptedSendHarness.device(101, preKeyID: 3).keys, jid: "\(account)/phone", peerBundle: harness.ownBundle)
        let message = try await phone.ownMessage("from my phone", id: "o1")

        try await harness.catchUp(account: [("A1", message)])

        let stored = try #require(try await harness.storedMessage(archiveID: "A1", in: contact))
        #expect(stored.body == "from my phone")
        #expect(stored.isOutgoing)
        #expect(!stored.isUndecryptable)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The chat that holds what the user sent is the recipient's, so that is where a copy stored decrypted already is
    /// looked for. Decrypting it again would take up its key exchange a second time.
    @Test func `catch-up does not decrypt again a message the user sent from another device that the chat with its recipient stores decrypted`() async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        try await harness.omemoStore.saveTrust(OMEMOTrust(
            accountJID: testJIDString, peerJID: testJIDString, deviceID: 101, fingerprint: "", trustLevel: .trusted
        ))
        let phone = try TestDevice(keys: EncryptedSendHarness.device(101, preKeyID: 3).keys, jid: "\(account)/phone", peerBundle: harness.ownBundle)
        let message = try await phone.ownMessage("from my phone", id: "o1")
        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact && $0.isDirectChat })
        let copy = ChatMessage(
            id: UUID(), conversationID: chat.id, stanzaID: "o1", serverID: "A1", fromJID: testJIDString, body: "from my phone",
            timestamp: Date(), isOutgoing: true, isDelivered: true, isEdited: false, type: "chat", isEncrypted: true
        )
        await harness.transcripts.addMessage(copy)

        try await harness.catchUp(account: [("A1", message)])

        let module = try #require(await harness.accountService.client(for: harness.accountID)?.module(ofType: OMEMOModule.self))
        #expect(module.state.withLock { $0.sessions.keys.allSatisfy { $0.jid != account } })
        #expect(try await harness.transcripts.fetchMessages(for: chat.id, before: nil, limit: 10).map(\.id) == [copy.id])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The account's archive records no occupant's real JID, but the user's own private message is the user's.
    @Test func `catch-up stores a room private message the user sent from another device decrypted, in the private chat with its recipient`() async throws {
        let harness = try await EncryptedSendHarness.connect(archiving: true)
        try await harness.omemoStore.saveTrust(OMEMOTrust(
            accountJID: testJIDString, peerJID: testJIDString, deviceID: 101, fingerprint: "", trustLevel: .trusted
        ))
        let phone = try TestDevice(keys: EncryptedSendHarness.device(101, preKeyID: 3).keys, jid: "\(account)/phone", peerBundle: harness.ownBundle)
        let message = try await phone.ownPrivateMessage("psst", id: "p1", to: "bobby")

        try await harness.catchUp(account: [("A1", message)])

        let privateChat = try #require(harness.chatService.openConversations.first { $0.jid == room && $0.occupantNickname == "bobby" })
        let stored = try #require(try await harness.transcripts.findMessage(serverID: "A1", conversationID: privateChat.id))
        #expect(stored.body == "psst")
        #expect(stored.isOutgoing)
        #expect(!stored.isUndecryptable)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    private static func isEmptyMessage(to jid: BareJID) -> @Sendable (String) -> Bool {
        { $0.hasPrefix("<message") && $0.contains("to=\"\(jid)\"") && $0.contains(XMPPNamespaces.omemo) && !$0.contains("<payload") }
    }
}

private func optOutElement() -> DuckoXMPP.XMLElement {
    DuckoXMPP.XMLElement(name: "opt-out", namespace: XMPPNamespaces.omemo)
}

/// An OMEMO device of `jid`'s, which keeps its sessions across the messages it writes, and is told that the account
/// lists device 100, whose bundle is `peerBundle`.
private struct TestDevice {
    let module: OMEMOModule
    let jid: String
    private let sentStanzas: OSAllocatedUnfairLock<[XMPPMessage]>

    init(keys: OMEMOModule.OMEMOIdentityData, jid: String, peerBundle: DuckoXMPP.XMLElement?) {
        let sentStanzas = OSAllocatedUnfairLock<[XMPPMessage]>(initialState: [])
        let context = ModuleContext(
            sendStanza: { stanza, onAccepted in
                onAccepted?()
                sentStanzas.withLock { $0.append(XMPPMessage(element: stanza.element)) }
            },
            sendIQ: { iq, _ in
                guard let peerBundle else { return nil }
                let isListFetch = iq.element.child(named: "pubsub")?.child(named: "items")?.attribute("node") == XMPPNamespaces.omemoDevices
                var item = DuckoXMPP.XMLElement(name: "item", attributes: ["id": isListFetch ? "current" : "100"])
                item.addChild(isListFetch ? OMEMOModule(pepModule: PEPModule()).buildDeviceListElement([100]) : peerBundle)
                var items = DuckoXMPP.XMLElement(name: "items", attributes: ["node": isListFetch ? XMPPNamespaces.omemoDevices : XMPPNamespaces.omemoBundles])
                items.addChild(item)
                var pubsub = DuckoXMPP.XMLElement(name: "pubsub", namespace: XMPPNamespaces.pubsub)
                pubsub.addChild(items)
                return pubsub
            },
            emitEvent: { _ in }, generateID: { UUID().uuidString }, connectedJID: { FullJID.parse(jid) }, domain: "example.com"
        )
        let pepModule = PEPModule()
        pepModule.setUp(context)
        let module = OMEMOModule(pepModule: pepModule)
        module.setUp(context)
        module.configureIdentity(keys)
        module.handleSessionEstablished(resumed: true)
        self.module = module
        self.jid = jid
        self.sentStanzas = sentStanzas
    }

    /// What the device sent, each addressed as from it.
    var sent: [XMPPMessage] {
        sentStanzas.withLock { $0 }.map { message in
            var message = message
            message.from = JID.parse(jid)
            return message
        }
    }

    /// A chat message to the account, its envelope stamped `time`.
    func message(_ content: [DuckoXMPP.XMLElement], id: String, time: String = archiveStamp) async throws -> XMPPMessage {
        let encrypted = try await module.encryptMessage(content: content, legacyBody: nil, time: time, to: account, recipientDeviceIDs: [100], ownDeviceIDs: []).omemo2
        return addressed(encrypted, type: .chat, id: id)
    }

    /// A chat message from the account to bob, as another of the account's devices sends it, encrypted for bob's device
    /// 200 and the account's device 100. The device is handed `peerBundle` for bob's device too, which encrypts its key
    /// to bob with keys bob's device lacks, but this device reads only its own.
    func ownMessage(_ text: String, id: String) async throws -> XMPPMessage {
        let encrypted = try await module.encryptMessage(
            content: [bodyElement(text)], legacyBody: nil, time: archiveStamp, to: contact, recipientDeviceIDs: [200], ownDeviceIDs: [100]
        ).omemo2
        var message = XMPPMessage(type: .chat, to: JID.parse(contact.description), id: id)
        message.from = JID.parse(jid)
        message.element.addChild(encrypted)
        return message
    }

    /// A private message from the account to the room's occupant `nickname`, as another of the account's devices sends
    /// it, encrypted for bob's device 200 and the account's device 100, its envelope naming the room as its recipient.
    func ownPrivateMessage(_ text: String, id: String, to nickname: String) async throws -> XMPPMessage {
        let encrypted = try await module.encryptGroupMessage(
            content: [bodyElement(text)], legacyBody: nil, time: archiveStamp, roomJID: room, recipients: [(contact, [200])], ownDeviceIDs: [100]
        ).omemo2
        var message = XMPPMessage(type: .chat, to: JID.parse("\(room)/\(nickname)"), id: id)
        message.from = JID.parse(jid)
        message.element.addChild(encrypted)
        return message
    }

    /// A message to the room, from bob under the nickname `bobby`, encrypted for the account's device 100.
    func roomMessage(_ text: String, id: String) async throws -> XMPPMessage {
        let encrypted = try await module.encryptGroupMessage(
            content: [bodyElement(text)], legacyBody: nil, time: archiveStamp, roomJID: room, recipients: [(account, [100])], ownDeviceIDs: []
        ).omemo2
        var message = addressed(encrypted, type: .groupchat, id: id)
        message.from = JID.parse("\(room)/bobby")
        return message
    }

    /// An empty key exchange to the account's device 100, as a session reset sends it.
    func keyExchange() async throws -> XMPPMessage {
        try #require(await module.resetSession(jid: account, deviceID: 100, versions: [.omemo2]).outcomes == [.omemo2: .rebuilt])
        return try #require(sent.last)
    }

    /// Takes the session with the account's device 100 as answered, as a message from it would, without moving the
    /// ratchet on, so the next message repeats no key exchange.
    func confirmSession() {
        module.state.withLock { state in
            let key = SessionKey(jid: account, deviceID: 100, version: .omemo2)
            guard let session = state.sessions[key], let header = session.pendingKeyExchange else { return }
            state.sessions[key] = OMEMOSession(ratchet: session.ratchet, associatedData: session.associatedData, start: .sent(header, isConfirmed: true))
        }
    }

    /// Reads `message`, which the account's device sent.
    func read(_ message: XMPPMessage) throws {
        var message = message
        message.from = JID.parse("\(account)/ducko")
        _ = module.receiveForwardedMessage(message)
    }

    private func addressed(_ encrypted: DuckoXMPP.XMLElement, type: XMPPMessage.MessageType, id: String) -> XMPPMessage {
        var message = XMPPMessage(type: type, to: JID.parse("\(testJIDString)/ducko"), id: id)
        message.from = JID.parse(jid)
        message.element.addChild(encrypted)
        return message
    }
}

private func bodyElement(_ text: String) -> DuckoXMPP.XMLElement {
    var body = DuckoXMPP.XMLElement(name: "body")
    body.addText(text)
    return body
}

private func isKeyExchange(_ encrypted: DuckoXMPP.XMLElement) -> Bool {
    encrypted.child(named: "header")?.child(named: "keys")?.children(named: "key").first?.attribute("kex") == "true"
}

private extension MockTransport {
    var sentStrings: [String] {
        sentBytes.map { String(decoding: $0, as: UTF8.self) }
    }
}

private extension EncryptedSendHarness {
    /// Bob's device 200, whose key exchange the account took up live, and which then read the account's empty answer,
    /// so its next messages are no key exchanges.
    func liveSession() async throws -> TestDevice {
        let bob = TestDevice(keys: bob, jid: "\(contact)/desktop", peerBundle: ownBundle)
        let first = try await bob.message([bodyElement("hello")], id: "live-1", time: Date().formatted(.iso8601))
        await transport.simulateReceive(first.element.xmlString)
        let isReply: @Sendable (String) -> Bool = { stanza in stanza.hasPrefix("<message") && stanza.contains("to=\"\(contact)\"") && stanza.contains(XMPPNamespaces.omemo) }
        try await bob.read(parsedMessage(awaitSent(on: transport, matching: isReply)))
        return bob
    }

    /// Runs catch-up, answering the account archive's query with `accountEntries` and the room archive's with
    /// `roomEntries`, each an archive id and the archived message.
    func catchUp(account accountEntries: [(String, XMPPMessage)], room roomEntries: [(String, XMPPMessage)] = []) async throws {
        await transport.clearSentBytes()
        await chatService.handleEvent(
            .rosterUpdated(RosterUpdate(receipt: 1, origin: .initial, contents: .snapshot([]), version: nil)), accountID: accountID
        )
        let tasks = chatService.takePendingTasks()
        var answered: Set<String> = []
        for (entries, archive) in [(accountEntries, nil), (roomEntries, room)] {
            let query = try await nextArchiveQuery(on: transport, answered: &answered)
            try await answer(query, with: entries, from: archive)
        }
        try #require(try await boundedOutcome {
            for task in tasks {
                await task.value
            }
        } != nil)
    }

    /// Reads the chat with bob's archive back from before now, answering its query with `entries`.
    func scrollBack(_ entries: [(String, XMPPMessage)]) async throws -> [ChatMessage] {
        await transport.clearSentBytes()
        let fetch = Task { try await chatService.fetchServerHistory(jid: contact, accountID: accountID, before: nil, limit: 50) }
        var answered: Set<String> = []
        try await answer(nextArchiveQuery(on: transport, answered: &answered), with: entries, from: nil)
        return try await fetch.value.messages
    }

    /// What the chat with `jid`, or the room `jid`, stores under the archive id `archiveID`.
    func storedMessage(archiveID: String, in jid: BareJID) async throws -> ChatMessage? {
        let conversation = try #require(chatService.openConversations.first { $0.jid == jid && $0.occupantNickname == nil })
        return try await transcripts.findMessage(serverID: archiveID, conversationID: conversation.id)
    }

    private func answer(_ query: ArchiveQuery, with entries: [(String, XMPPMessage)], from archive: BareJID?) async throws {
        let from = archive.map { " from='\($0)'" } ?? ""
        for (archiveID, message) in entries {
            await transport.simulateReceive(
                "<message\(from)><result xmlns='urn:xmpp:mam:2' queryid='\(query.queryID)' id='\(archiveID)'>"
                    + "<forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='\(archiveStamp)'/>\(message.element.xmlString)</forwarded>"
                    + "</result></message>"
            )
        }
        await transport.simulateReceive("<iq type='result' id='\(query.iqID)'\(from)><fin xmlns='urn:xmpp:mam:2' complete='true'/></iq>")
    }

    private func parsedMessage(_ xml: String) throws -> XMPPMessage {
        let events = XMPPStreamParser().parse(Array((testServerStreamOpen + xml).utf8))
        for case let .stanzaReceived(element) in events {
            return XMPPMessage(element: element)
        }
        throw XMPPClientError.unexpectedStreamState("No stanza in \(xml)")
    }
}
