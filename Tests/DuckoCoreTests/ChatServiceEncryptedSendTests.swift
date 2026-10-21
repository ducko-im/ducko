import DuckoTestSupport
import Foundation
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let contact = BareJID(localPart: "bob", domainPart: "example.com")!
private let room = BareJID(localPart: "room", domainPart: "conference.example.com")!

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
}

private func parsed(_ xml: String) throws -> DuckoXMPP.XMLElement {
    let events = XMPPStreamParser().parse(Array((testServerStreamOpen + xml).utf8))
    for case let .stanzaReceived(element) in events {
        return element
    }
    throw XMPPClientError.unexpectedStreamState("No stanza in \(xml)")
}

/// A connected account whose OMEMO module talks to a server that answers every PubSub request, hands out bob's bundle,
/// and lists bob as the room's only member.
@MainActor
private struct EncryptedSendHarness {
    let transport: MockTransport
    let accountService: AccountService
    let chatService: ChatService
    let transcripts: MockTranscriptStore
    // periphery:ignore - Held only to keep ChatService.omemoService (a weak ref) alive
    let omemoService: OMEMOService
    let accountID: UUID
    /// The keys of bob's device 200.
    let bob: OMEMOModule.OMEMOIdentityData

    static func connect(encryptionEnabled: Bool = true) async throws -> EncryptedSendHarness {
        let store = MockPersistenceStore()
        let transport = MockTransport()
        let (bundle, bob) = try bobsDevice()
        await transport.autoReply { stanza in reply(to: stanza, bundle: bundle) }
        let pepModule = PEPModule()
        let mucModule = MUCModule()
        let omemoModule = OMEMOModule(pepModule: pepModule, mucModule: mucModule)
        try omemoModule.configureIdentity(ownIdentity())
        let factory = MockXMPPClientFactory(transport: transport, modules: [ChatModule(), mucModule, pepModule, omemoModule])
        let accountService = makeAccountService(store: store, clientFactory: factory)
        let transcripts = MockTranscriptStore()
        let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
        chatService.setAccountService(accountService)
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
            accountID: accountID,
            bob: bob
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
            guard case let .omemoEncryptedMessageReceived(_, .decrypted(decrypted)) = event else { return nil }
            return decrypted.message
        }.first
    }

    private static func ownIdentity() throws -> OMEMOModule.OMEMOIdentityData {
        let identity = OMEMOIdentityKeyPair()
        let signedPreKey = try OMEMOPreKeyManager.generateSignedPreKey(keyID: 1, identityKey: identity)
        return OMEMOModule.OMEMOIdentityData(
            deviceID: 100, identityKeyRaw: identity.rawRepresentation, signedPreKeyID: 1,
            signedPreKeyRaw: signedPreKey.rawRepresentation, signedPreKeySignature: signedPreKey.signature,
            preKeys: [.init(keyID: 1, keyRaw: OMEMOPreKey(keyID: 1).rawRepresentation)]
        )
    }

    /// The `<bundle>` of bob's device 200, and its keys.
    private static func bobsDevice() throws -> (bundle: String, keys: OMEMOModule.OMEMOIdentityData) {
        let identity = OMEMOIdentityKeyPair()
        let signedPreKey = try OMEMOPreKeyManager.generateSignedPreKey(keyID: 1, identityKey: identity)
        let preKey = OMEMOPreKey(keyID: 7)
        let bundle = OMEMOPreKeyManager.buildBundle(
            deviceID: OMEMODeviceID(value: 200), identityKeyPair: identity, signedPreKey: signedPreKey, preKeys: [preKey]
        )
        let keys = OMEMOModule.OMEMOIdentityData(
            deviceID: 200, identityKeyRaw: identity.rawRepresentation, signedPreKeyID: 1,
            signedPreKeyRaw: signedPreKey.rawRepresentation, signedPreKeySignature: signedPreKey.signature,
            preKeys: [.init(keyID: 7, keyRaw: preKey.rawRepresentation)]
        )
        return (OMEMOModule(pepModule: PEPModule()).buildBundleElement(bundle).xmlString, keys)
    }

    /// The server's answer to a PubSub or room-affiliation request; nil for anything else.
    private nonisolated static func reply(to stanza: String, bundle: String) -> String? {
        guard stanza.hasPrefix("<iq"), let id = attribute("id", in: stanza) else { return nil }
        let from = attribute("to", in: stanza).map { " from=\"\($0)\"" } ?? ""
        if stanza.contains(XMPPNamespaces.omemoBundles), stanza.contains("<items") {
            return "<iq type=\"result\" id=\"\(id)\"\(from)><pubsub xmlns=\"\(XMPPNamespaces.pubsub)\"><items node=\"\(XMPPNamespaces.omemoBundles)\">"
                + "<item id=\"200\">\(bundle)</item></items></pubsub></iq>"
        }
        if stanza.contains(XMPPNamespaces.pubsub) {
            return "<iq type=\"result\" id=\"\(id)\"\(from)/>"
        }
        if stanza.contains("muc#admin") {
            let member = stanza.contains("affiliation=\"member\"") ? "<item affiliation=\"member\" jid=\"\(contact)\"/>" : ""
            return "<iq type=\"result\" id=\"\(id)\"\(from)><query xmlns=\"http://jabber.org/protocol/muc#admin\">\(member)</query></iq>"
        }
        return nil
    }

    /// The first value of `name` in `stanza`, which is the outermost element's for an attribute it carries.
    private nonisolated static func attribute(_ name: String, in stanza: String) -> String? {
        guard let start = stanza.range(of: " \(name)=\""), let end = stanza[start.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(stanza[start.upperBound ..< end])
    }
}
