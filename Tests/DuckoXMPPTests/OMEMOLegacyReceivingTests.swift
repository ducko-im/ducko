import DuckoTestSupport
import Testing
@testable import DuckoXMPP

/// Reading legacy OMEMO messages: which `<encrypted>` element a stanza is read from, the key exchanges and sessions
/// behind them, the empty messages owed for them, and what of the stanza reaches the decrypted message.
struct OMEMOLegacyReceivingTests {
    private let aliceJID = BareJID(localPart: "alice", domainPart: "example.com")!
    private let bobJID = BareJID(localPart: "bob", domainPart: "example.com")!
    private let aliceIdentity: TestOMEMOIdentity
    private let bobIdentity: TestOMEMOIdentity
    private let recorder: OMEMOMessageRecorder
    private let bob: OMEMOModule
    private let mucModule: MUCModule

    init() throws {
        let aliceIdentity = try makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1])
        self.aliceIdentity = aliceIdentity
        self.bobIdentity = try makeTestOMEMOIdentity(deviceID: 200, preKeyIDs: [7])
        self.recorder = try OMEMOMessageRecorder(account: #require(FullJID.parse("bob@example.com/laptop"))) { _ in bundleItems(for: aliceIdentity) }
        self.mucModule = MUCModule()
        mucModule.setUp(recorder.context)
        self.bob = recorder.installedModule(identity: bobIdentity.data, mucModule: mucModule)
    }

    // MARK: - The Reference's Messages

    @Test func `the reference's key exchange and the messages repeating it read once each, and exact copies show nothing`() throws {
        let reference = try ReferenceBob()

        for index in [0, 1, 1, 0] {
            try reference.module.handleMessage(reference.message(index))
        }

        #expect(reference.recorder.decryptedEvents.map(\.message.body) == [0, 1].map { reference.conversation.messages[$0].body })
        #expect(reference.recorder.outcomes.count == 2)
        let established = reference.recorder.events.compactMap { event -> OMEMOWireFormat? in
            if case let .omemoSessionEstablished(_, _, version, _, _) = event { version } else { nil }
        }
        #expect(established == [.legacy])
        #expect(reference.module.allSessionEntries().map(\.version) == [.legacy])
    }

    /// The reference's later messages answer bob's reply, so its ratchet stands in for the one bob's own reply drew.
    @Test func `the reference's later messages read in the order they arrive, a 16-byte IV and a padded body among them`() throws {
        let reference = try ReferenceBob()
        let conversation = reference.conversation
        try reference.module.handleMessage(reference.message(0))
        let reply = try #require(conversation.events.first { $0.party == "bob" && $0.action == "send" })
        let ratchet = try OMEMODoubleRatchetSession(legacyReference: reply.ratchet)
        let sessionKey = try SessionKey(jid: #require(BareJID.parse("alice@example.org")), deviceID: 31_415_926, version: .legacy)
        reference.module.state.withLock { $0.sessions[sessionKey]?.ratchet = ratchet }
        let order = conversation.events.filter { $0.party == "bob" && $0.action == "receive" }.map(\.message).dropFirst()

        for index in order {
            try reference.module.handleMessage(reference.message(index))
        }

        #expect(Array(order) == [1, 4, 6, 5, 2])
        #expect(conversation.messages[4].iv.count == 16)
        #expect(conversation.messages[5].plaintext != conversation.messages[5].body)
        #expect(reference.recorder.decryptedEvents.map(\.message.body) == ([0] + order).map { conversation.messages[$0].body })
    }

    enum Arrival: CaseIterable {
        case live, carbon, catchUp, scrollback
    }

    @Test(arguments: Arrival.allCases)
    func `the reference's key exchange reads live, from a carbon and at catch-up, and builds nothing in scrollback`(arrival: Arrival) throws {
        let reference = try ReferenceBob()
        let message = try reference.message(0)

        let outcome: OMEMOReceiveOutcome?
        switch arrival {
        case .live:
            try reference.module.handleMessage(message)
            outcome = reference.recorder.outcomes.first
        case .carbon:
            outcome = reference.module.receiveForwardedMessage(message)
        case .catchUp, .scrollback:
            outcome = reference.module.receiveArchivedMessage(message, sender: nil, isRoomPrivateMessage: false, allowsKeyExchange: arrival == .catchUp)
        }

        let body: String? = if case let .decrypted(decrypted)? = outcome { decrypted.message.body } else { nil }
        #expect(body == (arrival == .scrollback ? nil : reference.conversation.messages[0].body))
        #expect(reference.module.allSessionEntries().isEmpty == (arrival == .scrollback))
    }

    enum Tampering: CaseIterable {
        case mac, versionByte
    }

    @Test(arguments: Tampering.allCases)
    func `a reference key exchange altered on the way shows a notice and builds nothing, and the genuine one reads after it`(tampering: Tampering) throws {
        let reference = try ReferenceBob()
        let fixture = reference.conversation.messages[0]
        let keyExchange = try OMEMOLegacyKeyExchange(serialized: Array(#require(fixture.keyExchange).bytes))
        var altered = switch tampering {
        case .mac:
            OMEMOLegacyKeyExchange(keyExchange.header, message: OMEMOLegacyMessage(content: keyExchange.message.content, mac: flippingLastBit(of: keyExchange.message.mac))).serialized
        case .versionByte:
            keyExchange.serialized
        }
        if tampering == .versionByte { altered[0] = 0x34 }
        let elements = reference.module
        let encrypted = try elements.buildLegacyEncryptedElement(
            keys: [elements.buildLegacyKeyElement(deviceID: 27_182_818, data: altered, isPreKey: true)],
            iv: Array(fixture.iv), payload: Base64.decode(#require(fixture.payload)), senderDeviceID: 31_415_926
        )

        try reference.module.handleMessage(reference.message(encrypted))
        #expect(reference.module.allSessionEntries().isEmpty)
        try reference.module.handleMessage(reference.message(0))

        #expect(reference.recorder.outcomes.first?.reason == .decryptionFailed)
        #expect(reference.recorder.decryptedEvents.map(\.message.body) == [fixture.body])
    }

    // MARK: - Sessions

    @Test func `a message on a session whose MAC or version byte was altered shows a notice, and the genuine one reads after it`() async throws {
        var sender = try await confirmedSender()
        for tampering in Tampering.allCases {
            let genuine = try sender.encrypted("genuine")
            let altered = try mappingLegacyKey(in: genuine) { data in
                switch tampering {
                case .mac: flippingLastBit(of: data)
                case .versionByte: [0x34] + data.dropFirst()
                }
            }

            try bob.handleMessage(chatMessage(altered, id: "altered"))
            try bob.handleMessage(chatMessage(genuine, id: "genuine"))
        }

        #expect(recorder.outcomes.map(\.reason) == [nil, .decryptionFailed, nil, .decryptionFailed, nil])
        #expect(recorder.decryptedEvents.map(\.message.body) == ["one", "genuine", "genuine"])
    }

    /// The session moves on before the payload is checked, so only that message is lost, and its fallback body is never
    /// shown in its place.
    @Test func `a payload whose tag does not match shows a notice, never the fallback body, and the next message reads`() async throws {
        var sender = try await confirmedSender()
        var encrypted = try sender.encrypted("genuine")
        try encrypted.mapChild(named: "payload") { payload in
            let text = try #require(payload.textContent)
            var bytes = try #require(Base64.decode(text))
            bytes[0] ^= 1
            var altered = XMLElement(name: "payload")
            altered.addText(Base64.encode(bytes))
            return altered
        }
        var message = chatMessage(encrypted, id: "altered")
        message.body = "I sent you an OMEMO encrypted message but your client doesn't seem to support that."

        try bob.handleMessage(message)
        try bob.handleMessage(chatMessage(sender.encrypted("next"), id: "next"))

        #expect(recorder.outcomes.map(\.reason) == [nil, .decryptionFailed, nil])
        #expect(recorder.decryptedEvents.map(\.message.body) == ["one", "next"])
    }

    /// An archived key exchange can be older than the session this connection took up live in its version, and only
    /// that version's session counts.
    @Test(arguments: [OMEMOWireFormat.omemo2, .legacy])
    func `an archived legacy key exchange is taken up unless this connection took up a legacy session live`(liveVersion: OMEMOWireFormat) async throws {
        switch liveVersion {
        case .omemo2:
            try await bob.handleMessage(aliceSendsOMEMO2("live"))
        case .legacy:
            var live = try legacySender()
            try bob.handleMessage(chatMessage(live.encrypted("live")))
        }
        var archived = try legacySender()

        let outcome = try bob.receiveArchivedMessage(
            chatMessage(archived.encrypted("archived"), id: "a1"), sender: nil, isRoomPrivateMessage: false, allowsKeyExchange: true
        )

        let body: String? = if case let .decrypted(decrypted)? = outcome { decrypted.message.body } else { nil }
        #expect(body == (liveVersion == .omemo2 ? "archived" : nil))
    }

    /// The pre-keys are one pool for both versions, and the reuse rule follows the pool: a pre-key an earlier connection
    /// took up is refused, and one this connection took up stays open.
    @Test(arguments: [OMEMOWireFormat.omemo2, .legacy], [false, true])
    func `a pre-key one version took up is refused to the other on a later connection and stays open on the same one`(
        firstVersion: OMEMOWireFormat, sameConnection: Bool
    ) async throws {
        let trustGuard = OMEMOTrustGuard()
        bob.configureTrustGuard(trustGuard)
        let first: XMPPMessage = switch firstVersion {
        case .omemo2: try await aliceSendsOMEMO2("first")
        case .legacy: try legacySenderMessage("first")
        }
        let second: XMPPMessage = switch firstVersion {
        case .omemo2: try legacySenderMessage("second")
        case .legacy: try await aliceSendsOMEMO2("second")
        }
        _ = bob.receiveForwardedMessage(first)
        let reader = sameConnection ? bob : recorder.installedModule(identity: bobIdentity.data)
        reader.configureTrustGuard(trustGuard)

        let outcome = reader.receiveForwardedMessage(second)

        if sameConnection {
            let body: String? = if case let .decrypted(decrypted)? = outcome { decrypted.message.body } else { nil }
            #expect(body == "second")
            #expect(Set(reader.allSessionEntries().map(\.version)) == [.omemo2, .legacy])
        } else {
            #expect(outcome?.reason == .decryptionFailed)
            #expect(reader.allSessionEntries().isEmpty)
        }
    }

    @Test func `a new legacy key exchange replaces the device's legacy session and leaves its OMEMO 2 session alone`() async throws {
        try await bob.handleMessage(aliceSendsOMEMO2("omemo 2"))
        var first = try legacySender()
        try bob.handleMessage(chatMessage(first.encrypted("first")))
        let omemo2Session = bob.exportSession(jid: aliceJID, deviceID: 100, version: .omemo2)?.sessionData
        let firstSession = bob.exportSession(jid: aliceJID, deviceID: 100, version: .legacy)?.sessionData
        var second = try legacySender()

        try bob.handleMessage(chatMessage(second.encrypted("second"), id: "m2"))
        try bob.handleMessage(chatMessage(second.encrypted("third"), id: "m3"))

        #expect(recorder.decryptedEvents.map(\.message.body) == ["omemo 2", "first", "second", "third"])
        #expect(bob.exportSession(jid: aliceJID, deviceID: 100, version: .omemo2)?.sessionData == omemo2Session)
        let secondSession = try #require(bob.exportSession(jid: aliceJID, deviceID: 100, version: .legacy)).sessionData
        #expect(secondSession != firstSession)
        #expect(bob.allSessionEntries().count == 2)
    }

    /// The restore a reconnect runs, from the entries the bulk save writes.
    @Test func `a device's sessions in both versions decrypt the next message in each after a restore`() async throws {
        let alice = try aliceModule()
        let first = try await alice.module.encryptMessage(plaintext: "one", to: bobJID, recipientDeviceIDs: [200], ownDeviceIDs: []).omemo2
        try bob.handleMessage(chatMessage(first))
        var sender = try legacySender()
        try bob.handleMessage(chatMessage(sender.encrypted("one")))
        let recorder = recorder
        try await eventually { recorder.sentMessages.count == 2 }
        for var reply in recorder.sentMessages {
            if let legacy = reply.child(named: "encrypted", namespace: XMPPNamespaces.omemoLegacy) {
                _ = try sender.read(legacy)
            } else {
                reply.attributes["from"] = "bob@example.com/laptop"
                try alice.module.handleMessage(XMPPMessage(element: reply))
            }
        }
        let reconnected = recorder.installedModule(identity: bobIdentity.data.withPreKeys([]))
        reconnected.restoreSessions(bob.allSessionEntries())

        let omemo2 = try await alice.module.encryptMessage(plaintext: "two", to: bobJID, recipientDeviceIDs: [200], ownDeviceIDs: []).omemo2
        let legacy = try sender.encrypted("two")
        let bodies = [omemo2, legacy].map { encrypted -> String? in
            if case let .decrypted(decrypted)? = reconnected.receiveForwardedMessage(chatMessage(encrypted)) { decrypted.message.body } else { nil }
        }

        #expect(!isKeyExchange(omemo2))
        #expect(legacyKey(of: legacy)?.attribute("prekey") == nil)
        #expect(bodies == ["two", "two"])
    }

    /// What knows the device's key when another key arrives.
    enum KeyHolder: CaseIterable {
        /// The connection that took up the first session.
        case thisConnection
        /// A stored trust row, after a restart.
        case storedRow
        /// The restored session alone, after a restart whose trust row holds no key.
        case restoredSession
    }

    /// The device's key is held once for both versions, so another key arriving through its second version is refused.
    /// The key may be known to this connection, to a stored row or, with no key held, to the first version's restored
    /// session. The first version still reads.
    @Test(arguments: [OMEMOWireFormat.omemo2, .legacy], KeyHolder.allCases)
    func `a key exchange through a device's second version with another key is refused, and its first version still reads`(
        heldVersion: OMEMOWireFormat, holder: KeyHolder
    ) async throws {
        let trustGuard = OMEMOTrustGuard()
        bob.configureTrustGuard(trustGuard)
        var legacy = try legacySender()
        let alice = try aliceModule()
        try await bob.handleMessage(alicesMessage("first", in: heldVersion, from: alice.module, legacy: &legacy))
        let reader: OMEMOModule
        switch holder {
        case .thisConnection:
            reader = bob
        case .storedRow, .restoredSession:
            reader = recorder.installedModule(identity: bobIdentity.data)
            let restartedGuard = OMEMOTrustGuard()
            if holder == .storedRow {
                let stored = try omemoFingerprint(of: OMEMOX3DH.identityKey(of: aliceIdentity.identityKeyPair, format: heldVersion), format: heldVersion)
                restartedGuard.mergeRow(peer: aliceJID, deviceID: 100, fingerprint: stored, decision: .undecided)
            }
            reader.configureTrustGuard(restartedGuard)
            reader.restoreSessions(bob.allSessionEntries())
        }
        let impostor = try makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1])
        var impostorLegacy = try LegacyOMEMOSender(identity: impostor.identityKeyPair, deviceID: 100, to: bobIdentity.data)
        let forged: XMPPMessage = switch heldVersion {
        case .omemo2:
            try chatMessage(impostorLegacy.encrypted("forged"), id: "m2")
        case .legacy:
            try await chatMessage(
                aliceModule(identity: impostor).module.encryptMessage(plaintext: "forged", to: bobJID, recipientDeviceIDs: [200], ownDeviceIDs: []).omemo2,
                id: "m2"
            )
        }

        let refused = reader.receiveForwardedMessage(forged)

        #expect(refused?.reason == .changedIdentityKey)
        #expect(Set(reader.allSessionEntries().map(\.version)) == [heldVersion])
        let next = try await alicesMessage("next", in: heldVersion, from: alice.module, legacy: &legacy, id: "m3")
        let body: String? = if case let .decrypted(decrypted)? = reader.receiveForwardedMessage(next) { decrypted.message.body } else { nil }
        #expect(body == "next")
    }

    /// After a restart whose trust row holds no key, the restored session's key is the device's, which its key exchange
    /// through its second version carries.
    @Test(arguments: [OMEMOWireFormat.omemo2, .legacy])
    func `with no key held, a key exchange through a device's second version with its restored session's key is taken up`(
        heldVersion: OMEMOWireFormat
    ) async throws {
        var legacy = try legacySender()
        let alice = try aliceModule()
        try await bob.handleMessage(alicesMessage("first", in: heldVersion, from: alice.module, legacy: &legacy))
        let reader = recorder.installedModule(identity: bobIdentity.data)
        let restartedGuard = OMEMOTrustGuard()
        reader.configureTrustGuard(restartedGuard)
        reader.restoreSessions(bob.allSessionEntries())
        let otherVersion: OMEMOWireFormat = heldVersion == .omemo2 ? .legacy : .omemo2

        let outcome = try await reader.receiveForwardedMessage(alicesMessage("second", in: otherVersion, from: alice.module, legacy: &legacy, id: "m2"))

        let body: String? = if case let .decrypted(decrypted)? = outcome { decrypted.message.body } else { nil }
        #expect(body == "second")
        #expect(Set(reader.allSessionEntries().map(\.version)) == [.omemo2, .legacy])
        #expect(OMEMOFingerprint.matches(
            restartedGuard.heldFingerprint(peer: aliceJID, deviceID: 100), omemoFingerprint(of: aliceIdentity.identityKeyPair.publicKeyBytes, format: .omemo2)
        ))
    }

    // MARK: - Choosing the Element

    @Test func `a stanza carrying both elements reads as one message from its OMEMO 2 element`() async throws {
        let alice = try aliceModule()
        let omemo2 = try await alice.module.encryptMessage(plaintext: "from omemo 2", to: bobJID, recipientDeviceIDs: [200], ownDeviceIDs: []).omemo2
        var sender = try legacySender()
        var message = chatMessage(omemo2)
        try message.element.addChild(sender.encrypted("from legacy"))

        try bob.handleMessage(message)

        #expect(recorder.decryptedEvents.map(\.message.body) == ["from omemo 2"])
        #expect(recorder.decryptedEvents.first?.sentTime == testEnvelopeTime)
        #expect(bob.exportSession(jid: aliceJID, deviceID: 100, version: .legacy) == nil)
    }

    /// The outcome comes from the element read, so a stanza whose OMEMO 2 element is for other devices reads from its
    /// legacy one. It counts as not for this device only when its legacy element is not either.
    @Test(arguments: [true, false])
    func `a stanza whose OMEMO 2 element has no key for this device is read from its legacy element`(legacyHasKey: Bool) throws {
        let omemo2 = bob.buildEncryptedElement(
            keys: [(bobJID, bob.buildKeyElement(deviceID: 201, data: [1, 2, 3], isKex: false))], payload: "AAAA", senderDeviceID: 100
        )
        let otherDevice = try makeTestOMEMOIdentity(deviceID: 201, preKeyIDs: [3])
        var sender = try LegacyOMEMOSender(
            identity: aliceIdentity.identityKeyPair, deviceID: 100, to: legacyHasKey ? bobIdentity.data : otherDevice.data
        )
        var message = chatMessage(omemo2)
        try message.element.addChild(sender.encrypted("from legacy"))

        try bob.handleMessage(message)

        if legacyHasKey {
            #expect(recorder.decryptedEvents.map(\.message.body) == ["from legacy"])
        } else {
            #expect(recorder.outcomes.map(\.reason) == [.notForThisDevice])
        }
    }

    // MARK: - The Rebuilt Message

    /// Only the body is encrypted, so what travels beside it could have been added on the way. A receipt request, a
    /// marker request and a chat state only ask for an answer or show typing, so they are kept, and nothing else of
    /// their namespaces is, such as a receipt or a marker standing for the message they name.
    @Test func `a legacy message keeps beside its decrypted body only a receipt request, markable and chat state from the stanza`() throws {
        var sender = try legacySender()
        var message = try chatMessage(sender.encrypted("> earlier\nthe answer"))
        message.body = "I sent you an OMEMO encrypted message but your client doesn't seem to support that."
        for element in [
            XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": "m0"]),
            XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": "m0"]),
            XMLElement(name: "reply", namespace: XMPPNamespaces.messageReply, attributes: ["to": "alice@example.com/phone", "id": "m0"]),
            XMLElement(name: "fallback", namespace: XMPPNamespaces.fallbackIndication, attributes: ["for": XMPPNamespaces.messageReply]),
            XMLElement(name: "request", namespace: XMPPNamespaces.receipts),
            XMLElement(name: "received", namespace: XMPPNamespaces.receipts, attributes: ["id": "m0"]),
            XMLElement(name: "markable", namespace: XMPPNamespaces.chatMarkers),
            XMLElement(name: "displayed", namespace: XMPPNamespaces.chatMarkers, attributes: ["id": "m0"]),
            XMLElement(name: "composing", namespace: XMPPNamespaces.chatStates),
            XMLElement(name: "typing", namespace: XMPPNamespaces.chatStates),
            XMLElement(name: "store", namespace: XMPPNamespaces.processingHints),
            XMLElement(name: "encryption", namespace: XMPPNamespaces.eme, attributes: ["namespace": XMPPNamespaces.omemoLegacy])
        ] {
            message.element.addChild(element)
        }

        try bob.handleMessage(message)

        let decrypted = try #require(recorder.decryptedEvents.first).message
        #expect(decrypted.body == "> earlier\nthe answer")
        #expect(decrypted.id == "m1")
        #expect(decrypted.from == message.from)
        let children = decrypted.element.children.compactMap { node -> String? in
            if case let .element(child) = node { "\(child.namespace ?? "") \(child.name)" } else { nil }
        }
        #expect(Set(children) == [
            " body", "\(XMPPNamespaces.receipts) request", "\(XMPPNamespaces.chatMarkers) markable", "\(XMPPNamespaces.chatStates) composing"
        ])
        #expect(children.count == 4)
        #expect(recorder.dispatched.map(\.body) == ["> earlier\nthe answer"])
    }

    // MARK: - Senders

    /// The fetch lets the device be trusted and encrypted to. Each version's list of a sender is fetched once, so the
    /// OMEMO 2 list fetched for an earlier message does not stand in for the legacy one.
    @Test func `legacy messages from a device its sender's legacy list leaves out fetch that list once`() async throws {
        try await bob.handleMessage(aliceSendsOMEMO2("first"))
        let recorder = recorder
        try await eventually { recorder.deviceListFetches == ["alice@example.com"] }
        var sender = try legacySender()

        for id in ["m2", "m3"] {
            try bob.handleMessage(chatMessage(sender.encrypted(id), id: id))
        }

        try await eventually { recorder.legacyDeviceListFetches == ["alice@example.com"] }
        try await Task.sleep(for: .milliseconds(100))
        #expect(recorder.legacyDeviceListFetches == ["alice@example.com"])
        #expect(recorder.deviceListFetches == ["alice@example.com"])
    }

    enum RoomSender: CaseIterable {
        case revealed, hidden, archivedPrivateUnrecorded
    }

    @Test(arguments: RoomSender.allCases)
    func `a legacy room message decrypts with the session of the occupant's real address, and shows as hidden without one`(sender: RoomSender) async throws {
        let room = try #require(BareJID.parse("room@conference.example.com"))
        _ = try await mucModule.joinRoom(room, nickname: "bob")
        let jid = sender == .revealed ? " jid='alice@example.com/phone'" : ""
        try mucModule.handlePresence(XMPPPresence(element: stanza(
            "<presence from='\(room)/alice'><x xmlns='\(XMPPNamespaces.mucUser)'><item affiliation='member' role='participant'\(jid)/></x></presence>"
        )))
        var legacy = try legacySender()
        let message = try chatMessage(
            legacy.encrypted("hello room"), id: "g1", from: "\(room)/alice", type: sender == .archivedPrivateUnrecorded ? .chat : .groupchat
        )

        let outcome: OMEMOReceiveOutcome?
        switch sender {
        case .revealed, .hidden:
            try bob.handleMessage(message)
            outcome = recorder.outcomes.first
        case .archivedPrivateUnrecorded:
            outcome = bob.receiveArchivedMessage(message, sender: nil, isRoomPrivateMessage: true, allowsKeyExchange: true)
        }

        if sender == .revealed {
            guard case let .decrypted(decrypted)? = outcome else {
                Issue.record("Expected a decrypted message, got \(String(describing: outcome))")
                return
            }
            #expect(decrypted.message.body == "hello room")
            #expect(decrypted.senderJID == aliceJID)
            #expect(decrypted.senderDeviceID == 100)
        } else {
            #expect(outcome?.reason == .senderHidden)
        }
    }

    // MARK: - Key Transport

    /// A legacy device answers in legacy: a key-transport element, which confirms the session so the sender stops
    /// repeating its key exchange.
    @Test func `a legacy key exchange is answered with a legacy key transport, which confirms the sender's session`() async throws {
        var sender = try legacySender()
        try bob.handleMessage(chatMessage(sender.encrypted("one")))
        let recorder = recorder
        try await eventually { !recorder.sentMessages.isEmpty }
        let reply = try #require(recorder.sentMessages.first)
        let encrypted = try #require(reply.child(named: "encrypted", namespace: XMPPNamespaces.omemoLegacy))

        let keyMaterial = try sender.read(encrypted)
        let next = try sender.encrypted("two")

        #expect(reply.attribute("to") == "alice@example.com")
        #expect(reply.child(named: "encrypted", namespace: XMPPNamespaces.omemo) == nil)
        #expect(reply.child(named: "store", namespace: XMPPNamespaces.processingHints) != nil)
        #expect(encrypted.child(named: "payload") == nil)
        #expect(encrypted.child(named: "header")?.attribute("sid") == "200")
        #expect(legacyKey(of: encrypted)?.attribute("prekey") == nil)
        #expect(try Base64.decode(#require(encrypted.child(named: "header")?.child(named: "iv")?.textContent))?.count == 12)
        #expect(keyMaterial.count == OMEMOLegacyPayload.keyLength)
        #expect(legacyKey(of: next)?.attribute("prekey") == nil)
    }

    @Test func `a legacy key transport moves the session on and shows nothing`() throws {
        var sender = try legacySender()
        try bob.handleMessage(chatMessage(sender.encrypted("one")))

        try bob.handleMessage(chatMessage(sender.encrypted(nil), id: "kt"))
        try bob.handleMessage(chatMessage(sender.encrypted("two"), id: "m2"))

        #expect(recorder.outcomes.count == 2)
        #expect(recorder.decryptedEvents.map(\.message.body) == ["one", "two"])
        // Once for the empty message answering the key exchange, and once for the key transport.
        #expect(recorder.sessionAdvances == 2)
    }

    @Test func `the legacy sender gets a legacy heartbeat once a message numbered 53 arrives in its run, and only once`() async throws {
        var sender = try legacySender()
        let recorder = recorder
        for index in 0 ... 53 {
            try bob.handleMessage(chatMessage(sender.encrypted("\(index)"), id: "m\(index)"))
            if index == 52 {
                // Message 0's key exchange is answered right away, and the run's heartbeat comes only with its 54th message.
                try await eventually { recorder.sentMessages.count == 1 }
            }
        }
        try await eventually { recorder.sentMessages.count == 2 }

        try bob.handleMessage(chatMessage(sender.encrypted("54"), id: "m54"))

        let heartbeat = try #require(recorder.sentMessages.last?.child(named: "encrypted", namespace: XMPPNamespaces.omemoLegacy))
        #expect(heartbeat.child(named: "payload") == nil)
        #expect(recorder.decryptedEvents.count == 55)
        #expect(recorder.sessionAdvances == 2)
    }

    // MARK: - Helpers

    private func legacySender() throws -> LegacyOMEMOSender {
        try LegacyOMEMOSender(identity: aliceIdentity.identityKeyPair, deviceID: 100, to: bobIdentity.data)
    }

    private func legacySenderMessage(_ body: String) throws -> XMPPMessage {
        var sender = try legacySender()
        return try chatMessage(sender.encrypted(body))
    }

    /// A sender whose message "one" bob read and whose session bob's answer confirmed.
    private func confirmedSender() async throws -> LegacyOMEMOSender {
        var sender = try legacySender()
        try bob.handleMessage(chatMessage(sender.encrypted("one")))
        let recorder = recorder
        try await eventually { !recorder.sentMessages.isEmpty }
        _ = try sender.read(#require(recorder.sentMessages.first?.child(named: "encrypted", namespace: XMPPNamespaces.omemoLegacy)))
        return sender
    }

    /// alice's device 100 as an OMEMO 2 client, with `identity` or alice's own, which fetches bob's bundle for device 200.
    private func aliceModule(identity: TestOMEMOIdentity? = nil) throws -> (module: OMEMOModule, recorder: OMEMOMessageRecorder) {
        let bobIdentity = bobIdentity
        let recorder = try OMEMOMessageRecorder(account: #require(FullJID.parse("alice@example.com/phone"))) { iq in
            deviceListItems([200], answering: iq) ?? bundleItems(for: bobIdentity)
        }
        return (recorder.installedModule(identity: (identity ?? aliceIdentity).data), recorder)
    }

    private func aliceSendsOMEMO2(_ body: String) async throws -> XMPPMessage {
        let encrypted = try await aliceModule().module.encryptMessage(plaintext: body, to: bobJID, recipientDeviceIDs: [200], ownDeviceIDs: []).omemo2
        return chatMessage(encrypted)
    }

    /// alice's message `body` in `version`, from her OMEMO 2 client `module` or her legacy `sender`.
    private func alicesMessage(
        _ body: String, in version: OMEMOWireFormat, from module: OMEMOModule, legacy sender: inout LegacyOMEMOSender, id: String = "m1"
    ) async throws -> XMPPMessage {
        switch version {
        case .omemo2: try await chatMessage(module.encryptMessage(plaintext: body, to: bobJID, recipientDeviceIDs: [200], ownDeviceIDs: []).omemo2, id: id)
        case .legacy: try chatMessage(sender.encrypted(body), id: id)
        }
    }

    private func chatMessage(
        _ encrypted: XMLElement, id: String = "m1", from: String = "alice@example.com/phone", type: XMPPMessage.MessageType = .chat
    ) -> XMPPMessage {
        var message = XMLElement(name: "message", attributes: ["from": from, "to": "bob@example.com/laptop", "type": type.rawValue, "id": id])
        message.addChild(encrypted)
        return XMPPMessage(element: message)
    }
}

private func flippingLastBit(of bytes: [UInt8]) -> [UInt8] {
    var flipped = bytes
    flipped[flipped.count - 1] ^= 1
    return flipped
}

/// The first `<key>` of a legacy `<encrypted>` element.
private func legacyKey(of encrypted: XMLElement) -> XMLElement? {
    encrypted.child(named: "header")?.child(named: "key")
}

/// `encrypted` with its key's bytes replaced by what `transform` makes of them.
private func mappingLegacyKey(in encrypted: XMLElement, _ transform: ([UInt8]) -> [UInt8]) throws -> XMLElement {
    var result = encrypted
    try result.mapChild(named: "header") { header in
        var header = header
        try header.mapChild(named: "key") { key in
            var altered = XMLElement(name: "key", attributes: key.attributes)
            let text = try #require(key.textContent)
            try altered.addText(Base64.encode(transform(#require(Base64.decode(text)))))
            return altered
        }
        return header
    }
    return result
}

private extension XMLElement {
    /// Replaces the first child named `name` with what `transform` makes of it.
    mutating func mapChild(named name: String, _ transform: (XMLElement) throws -> XMLElement) throws {
        let index = try #require(children.firstIndex { if case let .element(child) = $0 { child.name == name } else { false } })
        guard case let .element(child) = children[index] else { return }
        children[index] = try .element(transform(child))
    }
}
