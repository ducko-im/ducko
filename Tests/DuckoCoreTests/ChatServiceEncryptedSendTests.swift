import DuckoTestSupport
import Foundation
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let contact = BareJID(localPart: "bob", domainPart: "example.com")!
private let room = BareJID(localPart: "room", domainPart: "conference.example.com")!
private let carol = BareJID(localPart: "carol", domainPart: "example.com")!

/// An encrypted message carries everything inside its envelope (XEP-0420). Only the payload, the method's name, and the
/// hints and ids stand next to it, and no plaintext body goes along (XEP-0384).
@MainActor
struct ChatServiceEncryptedSendTests {
    @Test(arguments: [false, true])
    func `an encrypted message carries no body or other content outside its envelope, and names OMEMO without a name`(inRoom: Bool) async throws {
        let harness = try await EncryptedSendHarness.connect()

        try await harness.send("secret", inRoom: inRoom)

        let sent = try parsed(#require(await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") }))
        #expect(outerShape(of: sent) == omemo2OuterShape)
        let encryption = try #require(sent.child(named: "encryption", namespace: XMPPNamespaces.eme))
        #expect(encryption.attributes == ["namespace": XMPPNamespaces.omemo])
        let inner = try #require(try harness.read(sent, asDeviceWith: harness.bob, of: contact))
        #expect(inner.body == "secret")
        #expect(inner.element.child(named: "markable", namespace: XMPPNamespaces.chatMarkers) != nil)
        #expect((inner.element.child(named: "request", namespace: XMPPNamespaces.receipts) != nil) == !inRoom)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// A retraction is a content message, so its envelope carries `<active/>` wherever chat states go (XEP-0085).
    @Test(arguments: [false, true])
    func `an encrypted retraction carries active inside its envelope unless the contact sends no chat states`(contactSendsNone: Bool) async throws {
        let harness = try await EncryptedSendHarness.connect()
        let chats = harness.chatService.openConversations
        let own = try #require(chats.first { $0.jid == contact })
        let original = ChatMessage(
            id: UUID(), conversationID: own.id, stanzaID: "m1", fromJID: contact.description, body: "secret", timestamp: Date(),
            isOutgoing: true, isDelivered: false, isEdited: false, type: "chat", isEncrypted: true
        )
        if contactSendsNone {
            harness.chatService.learnChatStateUse(of: .contact(contact), uses: false, accountID: harness.accountID)
        }

        try await harness.chatService.retractMessage(original, in: own, accountID: harness.accountID)

        let sent = try parsed(#require(await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") }))
        let retraction = try #require(try harness.readAsBob(sent))
        #expect(retraction.element.child(named: "retract", namespace: XMPPNamespaces.messageRetract) != nil)
        #expect((retraction.chatState == .active) == !contactSendsNone)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `an encrypted reply carries its reference and the marker of its quote inside its envelope`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact })
        let quoted = ChatMessage(
            id: UUID(), conversationID: chat.id, stanzaID: "q1", fromJID: contact.description, body: "secret", timestamp: Date(),
            isOutgoing: false, isDelivered: true, isEdited: false, type: "chat", isEncrypted: true
        )

        try await harness.chatService.sendMessage("ok", in: chat, replyingTo: quoted, accountID: harness.accountID)

        let sent = try parsed(#require(await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") }))
        let reply = try #require(try harness.readAsBob(sent))
        #expect(reply.body == "> secret\nok")
        #expect(reply.element.child(named: "reply", namespace: XMPPNamespaces.messageReply)?.attribute("id") == "q1")
        #expect(reply.replyFallbackRange(in: "> secret\nok") == 0 ..< 9)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `a reply sent encrypted is stored as encrypted`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact })
        let quoted = ChatMessage(
            id: UUID(), conversationID: chat.id, stanzaID: "q1", fromJID: contact.description, body: "secret", timestamp: Date(),
            isOutgoing: false, isDelivered: true, isEdited: false, type: "chat", isEncrypted: true
        )

        try await harness.chatService.sendMessage("ok", in: chat, replyingTo: quoted, accountID: harness.accountID)

        let stored = try #require(await harness.transcripts.messages.last)
        #expect(stored.replyToID == "q1")
        #expect(stored.isEncrypted)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// A correction re-sends everything the message carried (XEP-0308 §4), all of it inside the envelope.
    @Test func `an encrypted correction carries its reference, the reply and the attachment inside its envelope`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact })
        let link = "https://upload.example.com/photo.png"
        let original = ChatMessage(
            id: UUID(), conversationID: chat.id, stanzaID: "m1", fromJID: contact.description, body: "> secret\nLook", timestamp: Date(),
            isOutgoing: true, isDelivered: false, isEdited: false, type: "chat", replyToID: "q1", replyToJID: contact.description,
            replyFallbackRange: 0 ..< 9, isEncrypted: true, attachments: [Attachment(id: UUID(), url: link, fileName: "photo.png")]
        )
        await harness.transcripts.addMessage(original)

        try await harness.chatService.sendCorrection(of: original, newBody: "Look at this", in: chat, accountID: harness.accountID)

        let sent = try parsed(#require(await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") }))
        #expect(outerShape(of: sent) == omemo2OuterShape)
        let correction = try #require(try harness.readAsBob(sent))
        #expect(correction.body == "> secret\nLook at this")
        #expect(correction.element.child(named: "replace", namespace: XMPPNamespaces.messageCorrect)?.attribute("id") == "m1")
        #expect(correction.element.child(named: "reply", namespace: XMPPNamespaces.messageReply)?.attribute("id") == "q1")
        #expect(correction.replyFallbackRange(in: "> secret\nLook at this") == 0 ..< 9)
        #expect(correction.element.child(named: "x", namespace: XMPPNamespaces.oob)?.child(named: "url")?.textContent == link)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Ducko only applies the correction of an encrypted message when it is encrypted too.
    @Test(arguments: [false, true])
    func `the correction of an encrypted message is encrypted with encryption switched off`(inRoom: Bool) async throws {
        let harness = try await EncryptedSendHarness.connect(encryptionEnabled: false)
        let chat = try #require(harness.chatService.openConversations.first { $0.jid == (inRoom ? room : contact) })
        let original = ChatMessage(
            id: UUID(), conversationID: chat.id, stanzaID: "m1", serverID: inRoom ? "t1" : nil, fromJID: inRoom ? "me" : contact.description,
            body: "secret", timestamp: Date(), isOutgoing: true, isDelivered: false, isEdited: false, type: inRoom ? "groupchat" : "chat",
            isEncrypted: true
        )
        await harness.transcripts.addMessage(original)

        try await harness.chatService.sendCorrection(of: original, newBody: "fixed", in: chat, accountID: harness.accountID)

        let xml = try #require(await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }.last { $0.hasPrefix("<message") })
        let sent = try parsed(xml)
        #expect(sent.child(named: "encrypted", namespace: XMPPNamespaces.omemo) != nil)
        #expect(sent.child(named: "body") == nil)
        #expect(sent.child(named: "replace", namespace: XMPPNamespaces.messageCorrect) == nil)
        #expect(!xml.contains("fixed"))
        let stored = try #require(await harness.transcripts.fetchMessages(for: chat.id, before: nil, limit: 10).first { $0.id == original.id })
        #expect(stored.body == "fixed")
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Who would receive the message is unknown, so nothing goes out rather than missing one of their devices, whichever
    /// of the recipient's two lists fails.
    @Test(arguments: [false, true], [OMEMOWireFormat.omemo2, .legacy])
    func `an encrypted send is refused when a recipient's device list cannot be read`(inRoom: Bool, failingList: OMEMOWireFormat) async throws {
        let harness = try await EncryptedSendHarness.connect(failingContactList: failingList)

        await #expect {
            if inRoom {
                try await harness.chatService.sendGroupMessage(to: room, body: "secret", accountID: harness.accountID)
            } else {
                try await harness.chatService.sendMessage(to: contact, body: "secret", accountID: harness.accountID)
            }
        } throws: { error in
            if case ChatService.ChatServiceError.omemoDeviceListUnavailable(conversationJID: contact) = error { true } else { false }
        }

        let sent = await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        #expect(!sent.contains { $0.hasPrefix("<message") })
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The account's own JID on the room's member list is not a member to encrypt to, so its trusted other device does
    /// not stand in for the members who have none.
    @Test func `a room send is refused, naming the members, when no member but the user has a trusted device`() async throws {
        let account = try #require(BareJID.parse(testJIDString))
        let harness = try await EncryptedSendHarness.connect(otherOwnDevices: [101], roomMembers: [account, contact, carol])
        try await harness.omemoStore.saveTrust(OMEMOTrust(accountJID: testJIDString, peerJID: testJIDString, deviceID: 101, fingerprint: "", trustLevel: .trusted))
        try await harness.omemoStore.saveTrust(OMEMOTrust(
            accountJID: testJIDString, peerJID: contact.description, deviceID: 200, fingerprint: "", trustLevel: .untrusted
        ))

        await #expect {
            try await harness.chatService.sendGroupMessage(to: room, body: "secret", accountID: harness.accountID)
        } throws: { error in
            guard case let ChatService.ChatServiceError.omemoNoTrustedDevicesInRoom(roomJID, untrustedJIDs) = error else { return false }
            return roomJID == room && Set(untrustedJIDs) == [contact, carol]
        }

        let sent = await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        #expect(!sent.contains { $0.hasPrefix("<message") })
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test func `a room message is encrypted to the trusted devices of the members that have any, and to none of the others`() async throws {
        let harness = try await EncryptedSendHarness.connect(roomMembers: [contact, carol], deviceLists: [carol: [300]])
        try await harness.omemoStore.saveTrust(OMEMOTrust(
            accountJID: testJIDString, peerJID: carol.description, deviceID: 300, fingerprint: "", trustLevel: .untrusted
        ))

        try await harness.chatService.sendGroupMessage(to: room, body: "secret", accountID: harness.accountID)

        let sent = try parsed(#require(await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") }))
        let header = try #require(sent.child(named: "encrypted", namespace: XMPPNamespaces.omemo)?.child(named: "header"))
        let keys = Dictionary(
            header.children(named: "keys").map { ($0.attribute("jid") ?? "", $0.children(named: "key").compactMap { $0.attribute("rid") }) },
            uniquingKeysWith: +
        )
        #expect(keys[contact.description] == ["200"])
        #expect(keys[carol.description] == nil)
        let requests = await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        #expect(!requests.contains { $0.contains(XMPPNamespaces.omemoBundles) && $0.contains("<item id=\"300\"") })
        await harness.accountService.disconnect(accountID: harness.accountID)
    }
}

extension ChatServiceEncryptedSendTests {
    /// A send started while this new device's setup reads the account's list waits for it, and never goes out in the clear.
    @Test(arguments: [true, false])
    func `an encrypted send on a new device waits for its setup`(setupSucceeds: Bool) async throws {
        let harness = try await EncryptedSendHarness.connect(newDevice: true)
        await harness.transport.waitForBlockedSend()

        let send = Task { try await harness.chatService.sendMessage(to: contact, body: "secret", accountID: harness.accountID) }
        try await eventually { await harness.identityWaiters() == 1 }
        if setupSucceeds {
            await harness.transport.releaseBlockedSends()
            try await send.value
            #expect(await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") } != nil)
        } else {
            await harness.transport.failBlockedSends(with: XMPPClientError.sendFailed("The connection was closed"))
            await #expect(throws: (any Error).self) { try await send.value }
        }
        let sent = await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        #expect(!sent.contains { $0.hasPrefix("<message") && $0.contains("<body>secret</body>") })
        await harness.accountService.disconnect(accountID: harness.accountID)
    }
}

/// Each device receives a message in the newest OMEMO version it lists (XEP-0384). A legacy element encrypts the body
/// alone, so the requests and references a legacy device reads travel beside it, as legacy clients send them.
extension ChatServiceEncryptedSendTests {
    @Test(arguments: [false, true])
    func `a message to devices of both versions carries an element for each, and no body`(inRoom: Bool) async throws {
        let harness = try await EncryptedSendHarness.connect(legacyDeviceLists: [contact: [201]])

        try await harness.send("secret", inRoom: inRoom)

        let sent = try parsed(#require(await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") }))
        #expect(sent.child(named: "body") == nil)
        #expect(sent.child(named: "encryption", namespace: XMPPNamespaces.eme)?.attribute("namespace") == XMPPNamespaces.omemo)
        #expect(omemo2KeyRIDs(in: sent, for: contact) == ["200"])
        #expect(legacyKeyRIDs(in: sent) == ["201"])
        #expect(try harness.read(sent, asDeviceWith: harness.bob, of: contact)?.body == "secret")
        let legacy = try #require(try harness.readAsLegacyDevice(201, of: contact, sent))
        #expect(legacy.body == "secret")
        #expect(legacy.element.child(named: "markable", namespace: XMPPNamespaces.chatMarkers) != nil)
        #expect((legacy.element.child(named: "request", namespace: XMPPNamespaces.receipts) != nil) == !inRoom)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test(arguments: [false, true])
    func `a message to devices that list only legacy OMEMO names it and carries a fallback body`(inRoom: Bool) async throws {
        let harness = try await EncryptedSendHarness.connect(contactDevices: [], legacyDeviceLists: [contact: [201]])

        try await harness.send("secret", inRoom: inRoom)

        let sent = try parsed(#require(await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") }))
        #expect(sent.child(named: "encrypted", namespace: XMPPNamespaces.omemo) == nil)
        #expect(sent.child(named: "body")?.textContent == ChatService.legacyFallbackBody)
        #expect(sent.child(named: "encryption", namespace: XMPPNamespaces.eme)?.attribute("namespace") == XMPPNamespaces.omemoLegacy)
        #expect(sent.child(named: "store", namespace: XMPPNamespaces.processingHints) != nil)
        #expect(sent.children(named: "markable").count == 1)
        #expect(legacyKeyRIDs(in: sent) == ["201"])
        let legacy = try #require(try harness.readAsLegacyDevice(201, of: contact, sent))
        #expect(legacy.body == "secret")
        #expect(legacy.element.child(named: "markable", namespace: XMPPNamespaces.chatMarkers) != nil)
        #expect((legacy.chatState == .active) == !inRoom)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The user's own phone on a legacy client gets the message too, though the contact's device lists OMEMO 2.
    @Test func `the account's own legacy device receives a legacy element beside the contact's OMEMO 2 one`() async throws {
        let account = try #require(BareJID.parse(testJIDString))
        let harness = try await EncryptedSendHarness.connect(legacyDeviceLists: [account: [101]])

        try await harness.send("secret", inRoom: false)

        let sent = try parsed(#require(await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") }))
        #expect(sent.child(named: "body") == nil)
        #expect(omemo2KeyRIDs(in: sent, for: contact) == ["200"])
        #expect(legacyKeyRIDs(in: sent) == ["101"])
        #expect(try harness.readAsLegacyDevice(101, of: account, sent)?.body == "secret")
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The user's own devices never stand in for the contact's, so a message only they could read is not sent.
    @Test func `a send whose only device to receive it is the account's own legacy device fails`() async throws {
        let account = try #require(BareJID.parse(testJIDString))
        let harness = try await EncryptedSendHarness.connect(
            contactDevices: [], legacyDeviceLists: [contact: [201], account: [101]], missingLegacyBundles: [201]
        )

        await #expect(throws: OMEMOModuleError.noUsableRecipientDevices) {
            try await harness.send("secret", inRoom: false)
        }

        let sent = await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        #expect(!sent.contains { $0.hasPrefix("<message") })
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// A legacy client reads the correction and retraction references beside the payload, and applies them in place.
    @Test(arguments: [false, true])
    func `a correction or retraction to a legacy device names its message beside the payload`(isRetraction: Bool) async throws {
        let harness = try await EncryptedSendHarness.connect(contactDevices: [], legacyDeviceLists: [contact: [201]])
        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact })
        let original = ChatMessage(
            id: UUID(), conversationID: chat.id, stanzaID: "m1", fromJID: contact.description, body: "secret", timestamp: Date(),
            isOutgoing: true, isDelivered: false, isEdited: false, type: "chat", isEncrypted: true
        )
        await harness.transcripts.addMessage(original)

        if isRetraction {
            try await harness.chatService.retractMessage(original, in: chat, accountID: harness.accountID)
        } else {
            try await harness.chatService.sendCorrection(of: original, newBody: "fixed", in: chat, accountID: harness.accountID)
        }

        let sent = try parsed(#require(await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") }))
        #expect(sent.child(named: "body")?.textContent == ChatService.legacyFallbackBody)
        if isRetraction {
            #expect(sent.child(named: "retract", namespace: XMPPNamespaces.messageRetract)?.attribute("id") == "m1")
            #expect(sent.child(named: "fallback", namespace: XMPPNamespaces.fallbackIndication)?.attribute("for") == XMPPNamespaces.messageRetract)
        } else {
            #expect(sent.child(named: "replace", namespace: XMPPNamespaces.messageCorrect)?.attribute("id") == "m1")
        }
        let legacy = try #require(try harness.readAsLegacyDevice(201, of: contact, sent))
        #expect(legacy.body == (isRetraction ? retractionFallbackBody : "fixed"))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// A legacy client reads the reply reference and the marker of its quote beside the payload, which holds the quote.
    @Test func `a reply to a legacy device names the quoted message beside the payload`() async throws {
        let harness = try await EncryptedSendHarness.connect(contactDevices: [], legacyDeviceLists: [contact: [201]])
        let chat = try #require(harness.chatService.openConversations.first { $0.jid == contact })
        let quoted = ChatMessage(
            id: UUID(), conversationID: chat.id, stanzaID: "q1", fromJID: contact.description, body: "secret", timestamp: Date(),
            isOutgoing: false, isDelivered: true, isEdited: false, type: "chat", isEncrypted: true
        )

        try await harness.chatService.sendMessage("ok", in: chat, replyingTo: quoted, accountID: harness.accountID)

        let sent = try parsed(#require(await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") }))
        #expect(sent.child(named: "reply", namespace: XMPPNamespaces.messageReply)?.attribute("id") == "q1")
        #expect(sent.child(named: "fallback", namespace: XMPPNamespaces.fallbackIndication)?.attribute("for") == XMPPNamespaces.messageReply)
        #expect(try harness.readAsLegacyDevice(201, of: contact, sent)?.body == "> secret\nok")
        await harness.accountService.disconnect(accountID: harness.accountID)
    }
}

/// The namespace and name of each element `stanza` carries, sorted.
private func outerShape(of stanza: DuckoXMPP.XMLElement) -> [String] {
    stanza.children.compactMap { child in
        guard case let .element(element) = child else { return nil }
        return "\(element.namespace ?? "") \(element.name)"
    }.sorted()
}

/// What a message to devices that all list OMEMO 2 carries beside its envelope: its id, its element, the method's name
/// and the store hint, and no body, request, marker, chat state, reference or fallback.
private let omemo2OuterShape = [
    "\(XMPPNamespaces.eme) encryption", "\(XMPPNamespaces.processingHints) store", "\(XMPPNamespaces.omemo) encrypted",
    "\(XMPPNamespaces.stanzaID) origin-id"
].sorted()

/// The `rid` of each key the legacy element of `stanza` lists, which lists them by device alone.
private func legacyKeyRIDs(in stanza: DuckoXMPP.XMLElement) -> [String] {
    let header = stanza.child(named: "encrypted", namespace: XMPPNamespaces.omemoLegacy)?.child(named: "header")
    return header?.children(named: "key").compactMap { $0.attribute("rid") } ?? []
}

/// The `rid` of each key the OMEMO 2 element of `stanza` lists for `jid`.
private func omemo2KeyRIDs(in stanza: DuckoXMPP.XMLElement, for jid: BareJID) -> [String] {
    let header = stanza.child(named: "encrypted", namespace: XMPPNamespaces.omemo)?.child(named: "header")
    let keys = header?.children(named: "keys").first { $0.attribute("jid") == jid.description }
    return keys?.children(named: "key").compactMap { $0.attribute("rid") } ?? []
}

func parsed(_ xml: String) throws -> DuckoXMPP.XMLElement {
    let events = XMPPStreamParser().parse(Array((testServerStreamOpen + xml).utf8))
    for case let .stanzaReceived(element) in events {
        return element
    }
    throw XMPPClientError.unexpectedStreamState("No stanza in \(xml)")
}

/// A connected account, on device 100, whose OMEMO module talks to a server that answers every PubSub request. The
/// server lists `contactDevices` for bob (his device 200 by default) and hands out device 200's bundle. It lists
/// `roomMembers` (bob by default) as the members of the non-anonymous room.
/// - `archiving`: the account and the room keep archives the account can read.
/// - `otherOwnDevices`: the server lists these next to device 100 and hands out their bundles.
/// - `deviceLists`: the devices the server lists for other JIDs, whose bundles it hands out.
/// - `legacyDeviceLists`: the legacy device lists of any JID, the account's included. The server hands out a legacy
///   bundle for each listed device except those in `missingLegacyBundles`, listing no pre-key for those in
///   `legacyBundlesWithoutPreKeys`.
/// - `legacySharesBobsKey`: bob's device 200's legacy bundle carries the key of its OMEMO 2 one. Every other legacy
///   device has a key of its own.
/// - `failingContactList`: the server answers a read of bob's device list in that version with an error.
/// - `newDevice`: the account has no device yet, and its setup's read of the account's list is held until the test
///   releases or fails it.
/// - `holdsSetupRead`: that read is held the same way for device 100.
@MainActor
struct EncryptedSendHarness {
    let transport: MockTransport
    let accountService: AccountService
    let chatService: ChatService
    let transcripts: MockTranscriptStore
    /// Also held to keep ChatService.omemoService (a weak ref) alive.
    let omemoService: OMEMOService
    let omemoStore: MockOMEMOStore
    let accountID: UUID
    /// The keys of bob's device 200.
    let bob: OMEMOModule.OMEMOIdentityData
    /// The `<bundle>` of the account's device 100.
    let ownBundle: DuckoXMPP.XMLElement
    /// The keys of the account's device 100.
    let ownKeys: OMEMOModule.OMEMOIdentityData
    /// The keys of each device on a legacy list, by id.
    let legacyKeys: [UInt32: OMEMOModule.OMEMOIdentityData]

    static func connect(
        encryptionEnabled: Bool = true, archiving: Bool = false, otherOwnDevices: [UInt32] = [], roomMembers: [BareJID] = [contact],
        contactDevices: [UInt32] = [200], deviceLists: [BareJID: [UInt32]] = [:], legacyDeviceLists: [BareJID: [UInt32]] = [:],
        missingLegacyBundles: Set<UInt32> = [], legacyBundlesWithoutPreKeys: Set<UInt32> = [], legacySharesBobsKey: Bool = false,
        failingContactList: OMEMOWireFormat? = nil,
        newDevice: Bool = false, holdsSetupRead: Bool = false
    ) async throws -> EncryptedSendHarness {
        let store = MockPersistenceStore()
        let transport = MockTransport()
        let (bobsBundle, bob) = try device(200, preKeyID: 7)
        var bundles = ["200": bobsBundle.xmlString]
        for deviceID in otherOwnDevices + deviceLists.values.joined() {
            bundles["\(deviceID)"] = try device(deviceID, preKeyID: 1).bundle.xmlString
        }
        let (legacyKeys, legacyBundles) = try legacyDevices(
            Array(legacyDeviceLists.values.joined()), withoutBundle: missingLegacyBundles, withoutPreKeys: legacyBundlesWithoutPreKeys,
            sharing: legacySharesBobsKey ? [200: bob] : [:]
        )
        let ownDevices = otherOwnDevices.isEmpty ? nil : [100] + otherOwnDevices
        let server = ServerFixture(
            bundles: bundles, legacyBundles: legacyBundles, ownDevices: ownDevices, contactDevices: contactDevices, roomMembers: roomMembers.map(\.description),
            deviceLists: Dictionary(uniqueKeysWithValues: deviceLists.map { ($0.key.description, $0.value) }),
            legacyDeviceLists: Dictionary(uniqueKeysWithValues: legacyDeviceLists.map { ($0.key.description, $0.value) }),
            failingContactList: failingContactList
        )
        await transport.autoReply { stanza in reply(to: stanza, server: server) }
        let pepModule = PEPModule()
        let mucModule = MUCModule()
        let omemoModule = OMEMOModule(pepModule: pepModule, mucModule: mucModule)
        let (ownBundle, ownKeys) = try await installOwnDevice(on: omemoModule, transport: transport, newDevice: newDevice, holdsSetupRead: holdsSetupRead)
        let modules: [any XMPPModule] = [ChatModule(), mucModule, pepModule, omemoModule] + (archiving ? [MAMModule()] : [])
        let factory = MockXMPPClientFactory(transport: transport, modules: modules)
        let accountService = makeAccountService(store: store, clientFactory: factory)
        let transcripts = MockTranscriptStore()
        let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
        chatService.setAccountService(accountService)
        chatService.featureSource = archiving
            ? FixedFeatureSource.archiving(roomFeatures: [XMPPNamespaces.mucNonAnonymous])
            : FixedFeatureSource(roomFeatures: [XMPPNamespaces.mucNonAnonymous])
        let (omemoService, omemoStore) = makeOMEMOService(accountService: accountService, chatService: chatService)

        let connectTask = Task { @MainActor in
            try await accountService.createAndConnect(jidString: testJIDString, password: "secret", host: "example.com", port: 5222)
        }
        await simulateNoTLSConnect(transport)
        let accountID = try await connectTask.value
        try await omemoStore.saveTrust(OMEMOTrust(accountJID: testJIDString, peerJID: contact.description, deviceID: 200, fingerprint: "", trustLevel: .trusted))
        for (jid, type) in [(contact, Conversation.ConversationType.chat), (room, .groupchat)] {
            await store.addConversation(Conversation(
                id: UUID(), accountID: accountID, jid: jid, type: type, isPinned: false, isMuted: false, unreadCount: 0,
                roomNickname: type == .groupchat ? "me" : nil, encryptionEnabled: encryptionEnabled, createdAt: Date()
            ))
        }
        try await chatService.loadConversations(for: accountID)
        return EncryptedSendHarness(
            transport: transport, accountService: accountService, chatService: chatService, transcripts: transcripts, omemoService: omemoService,
            omemoStore: omemoStore, accountID: accountID, bob: bob, ownBundle: ownBundle, ownKeys: ownKeys, legacyKeys: legacyKeys
        )
    }

    /// Sends `body` to bob, or to the room when `inRoom`.
    func send(_ body: String, inRoom: Bool) async throws {
        if inRoom {
            try await chatService.sendGroupMessage(to: room, body: body, accountID: accountID)
        } else {
            try await chatService.sendMessage(to: contact, body: body, accountID: accountID)
        }
    }

    /// A read of the account's own device list carries no `to`.
    nonisolated static func isOwnListRead(_ stanza: String) -> Bool {
        stanza.contains(XMPPNamespaces.omemoDevices) && stanza.contains("<items") && !stanza.contains(" to=")
    }

    /// Encryptions and resets parked until the account's running setup attempt installs an identity.
    func identityWaiters() async -> Int {
        let module = await accountService.connectedClient(for: accountID)?.module(ofType: OMEMOModule.self)
        return module?.state.withLock { $0.identityWaiters.count } ?? 0
    }

    /// Returns device 100's `<bundle>` and keys, and gives the module device 100 unless `newDevice`. For a new device,
    /// or with `holdsSetupRead`, the setup's read of the account's list is held.
    private static func installOwnDevice(
        on module: OMEMOModule, transport: MockTransport, newDevice: Bool, holdsSetupRead: Bool
    ) async throws -> (bundle: DuckoXMPP.XMLElement, keys: OMEMOModule.OMEMOIdentityData) {
        let (ownBundle, ownKeys) = try device(100, preKeyID: 1)
        if newDevice || holdsSetupRead {
            await transport.blockSends(where: isOwnListRead)
        }
        if !newDevice {
            module.configureIdentity(ownKeys)
        }
        return (ownBundle, ownKeys)
    }

    /// An OMEMO service wired to the account and chat services, which takes in the account's setup events in order but
    /// handles no other events.
    private static func makeOMEMOService(accountService: AccountService, chatService: ChatService) -> (OMEMOService, MockOMEMOStore) {
        let omemoStore = MockOMEMOStore()
        let omemoService = OMEMOService(omemoStore: omemoStore)
        omemoService.setAccountService(accountService)
        omemoService.setChatService(chatService)
        chatService.setOMEMOService(omemoService)
        accountService.onEvent = { [weak omemoService] event, accountID in
            omemoService?.receiveSetupEvent(event, accountID: accountID)
        }
        return (omemoService, omemoStore)
    }

    /// The message inside the envelope of `stanza`, which the account sent, as bob's device reads it.
    func readAsBob(_ stanza: DuckoXMPP.XMLElement) throws -> XMPPMessage? {
        let events = OSAllocatedUnfairLock<[XMPPEvent]>(initialState: [])
        let context = ModuleContext(
            sendStanza: { _, onAccepted in onAccepted?() }, sendIQ: { _, _ in nil },
            emitEvent: { event in events.withLock { $0.append(event) } }, generateID: { "bob-1" },
            connectedJID: { FullJID.parse("\(contact)/desktop") }, domain: "example.com"
        )
        let pepModule = PEPModule()
        pepModule.setUp(context)
        let module = OMEMOModule(pepModule: pepModule)
        module.setUp(context)
        module.configureIdentity(bob)
        module.handleSessionEstablished(resumed: true)
        var message = XMPPMessage(element: stanza)
        message.from = JID.parse("\(testJIDString)/ducko")
        try module.handleMessage(message)
        return events.withLock { $0 }.lazy.compactMap { event -> XMPPMessage? in
            guard case let .omemoEncryptedMessageReceived(_, .decrypted(decrypted), _) = event else { return nil }
            return decrypted.message
        }.first
    }

    /// The message inside `stanza`, which the account sent, as `jid`'s device with `keys` reads it: the envelope of the
    /// OMEMO 2 element when that has a key for the device, else the legacy element's body and what beside it a legacy
    /// device takes in. It is read as an archive returns it, naming the account as its sender, so a room's message needs
    /// no occupants to be read. A room's message comes from the room's echo of the account, any other from the account.
    func read(_ stanza: DuckoXMPP.XMLElement, asDeviceWith keys: OMEMOModule.OMEMOIdentityData, of jid: BareJID) throws -> XMPPMessage? {
        let context = ModuleContext(
            sendStanza: { _, onAccepted in onAccepted?() }, sendIQ: { _, _ in nil }, emitEvent: { _ in }, generateID: { "legacy-1" },
            connectedJID: { FullJID.parse("\(jid)/legacy") }, domain: "example.com"
        )
        let pepModule = PEPModule()
        pepModule.setUp(context)
        let module = OMEMOModule(pepModule: pepModule)
        module.setUp(context)
        module.configureIdentity(keys)
        module.handleSessionEstablished(resumed: true)
        var message = XMPPMessage(element: stanza)
        message.from = message.messageType == .groupchat ? JID.parse("\(room)/me") : JID.parse("\(testJIDString)/ducko")
        let account = try #require(BareJID.parse(testJIDString))
        guard case let .decrypted(decrypted) = module.receiveArchivedMessage(
            message, sender: account, isRoomPrivateMessage: false, allowsKeyExchange: true
        ) else { return nil }
        return decrypted.message
    }

    /// `stanza` as the legacy device `deviceID` of `jid` reads it, as `read` reads it.
    func readAsLegacyDevice(_ deviceID: UInt32, of jid: BareJID, _ stanza: DuckoXMPP.XMLElement) throws -> XMPPMessage? {
        try read(stanza, asDeviceWith: #require(legacyKeys[deviceID]), of: jid)
    }

    /// A chat message from bob's desktop to the account, which bob's device 200 encrypted for the account's device 100.
    func sentByBob(_ text: String, id: String) async throws -> XMPPMessage {
        let bundle = ownBundle
        let context = ModuleContext(
            sendStanza: { _, onAccepted in onAccepted?() },
            sendIQ: { _, _ in
                var item = DuckoXMPP.XMLElement(name: "item", attributes: ["id": "100"])
                item.addChild(bundle)
                var items = DuckoXMPP.XMLElement(name: "items", attributes: ["node": XMPPNamespaces.omemoBundles])
                items.addChild(item)
                var pubsub = DuckoXMPP.XMLElement(name: "pubsub", namespace: XMPPNamespaces.pubsub)
                pubsub.addChild(items)
                return pubsub
            },
            emitEvent: { _ in }, generateID: { "bob-1" }, connectedJID: { FullJID.parse("\(contact)/desktop") }, domain: "example.com"
        )
        let pepModule = PEPModule()
        pepModule.setUp(context)
        let module = OMEMOModule(pepModule: pepModule)
        module.setUp(context)
        module.configureIdentity(bob)
        module.handleSessionEstablished(resumed: true)
        var body = DuckoXMPP.XMLElement(name: "body")
        body.addText(text)
        let account = try #require(BareJID.parse(testJIDString))
        let encrypted = try await module.encryptMessage(
            content: [body], legacyBody: nil, time: Date().formatted(.iso8601), to: account, recipientDeviceIDs: [100], ownDeviceIDs: []
        ).omemo2
        var message = XMPPMessage(type: .chat, to: JID.parse("\(testJIDString)/ducko"), id: id)
        message.from = JID.parse("\(contact)/desktop")
        message.element.addChild(encrypted)
        return message
    }

    /// The `<bundle>` of device `deviceID`, with one pre-key `preKeyID`, and its keys.
    static func device(_ deviceID: UInt32, preKeyID: UInt32) throws -> (bundle: DuckoXMPP.XMLElement, keys: OMEMOModule.OMEMOIdentityData) {
        let identity = OMEMOIdentityKeyPair()
        let signedPreKey = try OMEMOPreKeyManager.generateSignedPreKey(keyID: 1, identityKey: identity)
        let preKey = OMEMOPreKey(keyID: preKeyID)
        let bundle = OMEMOPreKeyManager.buildBundle(
            deviceID: OMEMODeviceID(value: deviceID), identityKeyPair: identity, signedPreKey: signedPreKey, preKeys: [preKey]
        )
        let keys = OMEMOModule.OMEMOIdentityData(
            deviceID: deviceID, identityKeyRaw: identity.rawRepresentation, signedPreKeyID: 1,
            signedPreKeyRaw: signedPreKey.rawRepresentation, signedPreKeySignature: signedPreKey.signature,
            preKeys: [.init(keyID: preKeyID, keyRaw: preKey.rawRepresentation)]
        )
        return (OMEMOModule(pepModule: PEPModule()).buildBundleElement(bundle), keys)
    }

    /// The keys of each of `deviceIDs`, those in `sharing` or new ones, and the legacy `<bundle>` of each but those
    /// `withoutBundle`, by id, listing no pre-key for those `withoutPreKeys`.
    private static func legacyDevices(
        _ deviceIDs: [UInt32], withoutBundle: Set<UInt32>, withoutPreKeys: Set<UInt32>, sharing: [UInt32: OMEMOModule.OMEMOIdentityData]
    ) throws -> (keys: [UInt32: OMEMOModule.OMEMOIdentityData], bundles: [String: String]) {
        var keys: [UInt32: OMEMOModule.OMEMOIdentityData] = [:]
        var bundles: [String: String] = [:]
        for deviceID in deviceIDs {
            let deviceKeys = try sharing[deviceID] ?? device(deviceID, preKeyID: 1).keys
            keys[deviceID] = deviceKeys
            if !withoutBundle.contains(deviceID) {
                bundles["\(deviceID)"] = try legacyBundle(of: deviceKeys, listsPreKeys: !withoutPreKeys.contains(deviceID)).xmlString
            }
        }
        return (keys, bundles)
    }

    /// The legacy `<bundle>` of the device with `keys`, listing its pre-keys unless `listsPreKeys` is false.
    static func legacyBundle(of keys: OMEMOModule.OMEMOIdentityData, listsPreKeys: Bool = true) throws -> DuckoXMPP.XMLElement {
        let bundle = try OMEMOPreKeyManager.buildLegacyBundle(
            deviceID: OMEMODeviceID(value: keys.deviceID), identityKeyPair: OMEMOIdentityKeyPair(rawRepresentation: keys.identityKeyRaw),
            signedPreKey: OMEMOSignedPreKey(keyID: keys.signedPreKeyID, rawRepresentation: keys.signedPreKeyRaw, signature: keys.signedPreKeySignature),
            preKeys: listsPreKeys ? keys.preKeys.map { try OMEMOPreKey(keyID: $0.keyID, rawRepresentation: $0.keyRaw) } : []
        )
        return OMEMOModule(pepModule: PEPModule()).buildLegacyBundleElement(bundle)
    }

    /// What the server answers with. `bundles` and `legacyBundles` hold each device's `<bundle>` in that version by its
    /// id. `ownDevices` is the account's device list, or nil to answer it with no items. `deviceLists` holds other JIDs'
    /// device lists by JID, and `legacyDeviceLists` any JID's legacy one. A JID without a list is answered with no items.
    private struct ServerFixture {
        let bundles: [String: String]
        let legacyBundles: [String: String]
        let ownDevices: [UInt32]?
        let contactDevices: [UInt32]
        let roomMembers: [String]
        let deviceLists: [String: [UInt32]]
        let legacyDeviceLists: [String: [UInt32]]
        let failingContactList: OMEMOWireFormat?
    }

    /// The server's answer to a PubSub or room-affiliation request; nil for anything else.
    private nonisolated static func reply(to stanza: String, server: ServerFixture) -> String? {
        guard stanza.hasPrefix("<iq"), let id = attribute("id", in: stanza) else { return nil }
        let to = attribute("to", in: stanza)
        let from = to.map { " from=\"\($0)\"" } ?? ""
        if stanza.contains(XMPPNamespaces.omemoBundles), stanza.contains("<items"), let itemID = value(after: "<item id=\"", in: stanza),
           let bundle = server.bundles[itemID] {
            return "<iq type=\"result\" id=\"\(id)\"\(from)><pubsub xmlns=\"\(XMPPNamespaces.pubsub)\"><items node=\"\(XMPPNamespaces.omemoBundles)\">"
                + "<item id=\"\(itemID)\">\(bundle)</item></items></pubsub></iq>"
        }
        if stanza.contains("\(XMPPNamespaces.omemoLegacy).bundles:"), stanza.contains("<items"),
           let deviceID = value(after: ".bundles:", in: stanza), let bundle = server.legacyBundles[deviceID] {
            return "<iq type=\"result\" id=\"\(id)\"\(from)><pubsub xmlns=\"\(XMPPNamespaces.pubsub)\"><items node=\"\(XMPPNamespaces.omemoLegacy).bundles:\(deviceID)\">"
                + "<item id=\"current\">\(bundle)</item></items></pubsub></iq>"
        }
        let failingNode = server.failingContactList.map { $0 == .omemo2 ? XMPPNamespaces.omemoDevices : XMPPNamespaces.omemoLegacyDeviceList }
        if let failingNode, to == contact.description, stanza.contains(failingNode) {
            return "<iq type=\"error\" id=\"\(id)\"\(from)><error type=\"cancel\">"
                + "<internal-server-error xmlns=\"urn:ietf:params:xml:ns:xmpp-stanzas\"/></error></iq>"
        }
        if stanza.contains(XMPPNamespaces.omemoLegacyDeviceList), stanza.contains("<items"), let listed = server.legacyDeviceLists[to ?? testJIDString] {
            let devices = listed.map { "<device id=\"\($0)\"/>" }.joined()
            return "<iq type=\"result\" id=\"\(id)\"\(from)><pubsub xmlns=\"\(XMPPNamespaces.pubsub)\"><items node=\"\(XMPPNamespaces.omemoLegacyDeviceList)\">"
                + "<item id=\"current\"><list xmlns=\"\(XMPPNamespaces.omemoLegacy)\">\(devices)</list></item></items></pubsub></iq>"
        }
        let listed: [UInt32]? = if to == contact.description {
            server.contactDevices
        } else if to == nil || to == testJIDString {
            server.ownDevices
        } else {
            to.flatMap { server.deviceLists[$0] }
        }
        if stanza.contains(XMPPNamespaces.omemoDevices), stanza.contains("<items"), let listed {
            let devices = listed.map { "<device id=\"\($0)\"/>" }.joined()
            return "<iq type=\"result\" id=\"\(id)\"\(from)><pubsub xmlns=\"\(XMPPNamespaces.pubsub)\"><items node=\"\(XMPPNamespaces.omemoDevices)\">"
                + "<item id=\"current\"><devices xmlns=\"\(XMPPNamespaces.omemo)\">\(devices)</devices></item></items></pubsub></iq>"
        }
        if stanza.contains(XMPPNamespaces.pubsub) {
            return "<iq type=\"result\" id=\"\(id)\"\(from)/>"
        }
        if stanza.contains("muc#admin") {
            let members = stanza.contains("affiliation=\"member\"")
                ? server.roomMembers.map { "<item affiliation=\"member\" jid=\"\($0)\"/>" }.joined() : ""
            return "<iq type=\"result\" id=\"\(id)\"\(from)><query xmlns=\"http://jabber.org/protocol/muc#admin\">\(members)</query></iq>"
        }
        return nil
    }

    /// The first value of `name` in `stanza`, which is the outermost element's for an attribute it carries.
    private nonisolated static func attribute(_ name: String, in stanza: String) -> String? {
        value(after: " \(name)=\"", in: stanza)
    }

    /// The text from the first `prefix` in `stanza` up to the next quote.
    private nonisolated static func value(after prefix: String, in stanza: String) -> String? {
        guard let start = stanza.range(of: prefix), let end = stanza[start.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(stanza[start.upperBound ..< end])
    }
}
