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

        if inRoom {
            try await harness.chatService.sendGroupMessage(to: room, body: "secret", accountID: harness.accountID)
        } else {
            try await harness.chatService.sendMessage(to: contact, body: "secret", accountID: harness.accountID)
        }

        let sent = try parsed(#require(await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") }))
        let children = sent.children.compactMap { if case let .element(child) = $0 { child } else { nil } }
        #expect(sent.child(named: "body") == nil)
        #expect(children.map(\.name).sorted() == ["encrypted", "encryption", "origin-id", "store"])
        let encryption = try #require(sent.child(named: "encryption", namespace: XMPPNamespaces.eme))
        #expect(encryption.attributes == ["namespace": XMPPNamespaces.omemo])
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

    /// Who would receive the message is unknown, so nothing goes out rather than missing one of their devices.
    @Test(arguments: [false, true])
    func `an encrypted send is refused when a recipient's device list cannot be read`(inRoom: Bool) async throws {
        let harness = try await EncryptedSendHarness.connect(contactsDeviceListFails: true)

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

private func parsed(_ xml: String) throws -> DuckoXMPP.XMLElement {
    let events = XMPPStreamParser().parse(Array((testServerStreamOpen + xml).utf8))
    for case let .stanzaReceived(element) in events {
        return element
    }
    throw XMPPClientError.unexpectedStreamState("No stanza in \(xml)")
}

/// A connected account, on device 100, whose OMEMO module talks to a server that answers every PubSub request, lists
/// and hands out bob's device, and lists `roomMembers`, bob by default, as the members of the non-anonymous room. With
/// `archiving`, the account and the room keep archives the account can read. With `otherOwnDevices`, the server lists
/// those devices next to device 100 and hands them out too. `deviceLists` holds the devices the server lists for other
/// JIDs, which it hands out too. With `contactsDeviceListFails`, the server answers a read of bob's device list with an
/// error.
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

    static func connect(
        encryptionEnabled: Bool = true, archiving: Bool = false, otherOwnDevices: [UInt32] = [], roomMembers: [BareJID] = [contact],
        deviceLists: [BareJID: [UInt32]] = [:], contactsDeviceListFails: Bool = false
    ) async throws -> EncryptedSendHarness {
        let store = MockPersistenceStore()
        let transport = MockTransport()
        let (bobsBundle, bob) = try device(200, preKeyID: 7)
        var bundles = ["200": bobsBundle.xmlString]
        for deviceID in otherOwnDevices + deviceLists.values.joined() {
            bundles["\(deviceID)"] = try device(deviceID, preKeyID: 1).bundle.xmlString
        }
        let ownDevices = otherOwnDevices.isEmpty ? nil : [100] + otherOwnDevices
        let server = ServerFixture(
            bundles: bundles, ownDevices: ownDevices, roomMembers: roomMembers.map(\.description),
            deviceLists: Dictionary(uniqueKeysWithValues: deviceLists.map { ($0.key.description, $0.value) }), contactsDeviceListFails: contactsDeviceListFails
        )
        await transport.autoReply { stanza in reply(to: stanza, server: server) }
        let pepModule = PEPModule()
        let mucModule = MUCModule()
        let omemoModule = OMEMOModule(pepModule: pepModule, mucModule: mucModule)
        let (ownBundle, ownKeys) = try device(100, preKeyID: 1)
        omemoModule.configureIdentity(ownKeys)
        let modules: [any XMPPModule] = [ChatModule(), mucModule, pepModule, omemoModule] + (archiving ? [MAMModule()] : [])
        let factory = MockXMPPClientFactory(transport: transport, modules: modules)
        let accountService = makeAccountService(store: store, clientFactory: factory)
        let transcripts = MockTranscriptStore()
        let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
        chatService.setAccountService(accountService)
        chatService.featureSource = archiving
            ? FixedFeatureSource.archiving(roomFeatures: [XMPPNamespaces.mucNonAnonymous])
            : FixedFeatureSource(roomFeatures: [XMPPNamespaces.mucNonAnonymous])
        let omemoStore = MockOMEMOStore()
        let omemoService = OMEMOService(omemoStore: omemoStore)
        omemoService.setAccountService(accountService)
        omemoService.setChatService(chatService)
        chatService.setOMEMOService(omemoService)

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
            omemoStore: omemoStore, accountID: accountID, bob: bob, ownBundle: ownBundle
        )
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
            content: [body], time: Date().formatted(.iso8601), to: account, recipientDeviceIDs: [100], ownDeviceIDs: []
        ).encrypted
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

    /// What the server answers with. `bundles` holds each device's `<bundle>` by its id. `ownDevices` is the account's
    /// device list, or nil to answer it with no items. `deviceLists` holds other JIDs' device lists by JID, and a JID
    /// without one is answered with no items.
    private struct ServerFixture {
        let bundles: [String: String]
        let ownDevices: [UInt32]?
        let roomMembers: [String]
        let deviceLists: [String: [UInt32]]
        let contactsDeviceListFails: Bool
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
        if server.contactsDeviceListFails, to == contact.description, stanza.contains(XMPPNamespaces.omemoDevices) {
            return "<iq type=\"error\" id=\"\(id)\"\(from)><error type=\"cancel\">"
                + "<internal-server-error xmlns=\"urn:ietf:params:xml:ns:xmpp-stanzas\"/></error></iq>"
        }
        let listed: [UInt32]? = if to == contact.description {
            [200]
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
