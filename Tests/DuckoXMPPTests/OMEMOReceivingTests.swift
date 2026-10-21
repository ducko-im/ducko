import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

/// Reading OMEMO messages: the envelope's affixes, room senders, what goes to the modules that act in the clear, and
/// the empty messages a device owes its peers.
struct OMEMOReceivingTests {
    private let parties: Parties

    init() async throws {
        self.parties = try await Parties.make()
    }

    @Test func `a message reads as its envelope's content with the stanza's attributes and the envelope's time`() async throws {
        let message = try await parties.aliceSends([bodyElement("hi")], id: "m1")

        try parties.bob.handleMessage(message)

        let decrypted = try #require(parties.bobRecorder.decryptedEvents.first)
        #expect(decrypted.message.body == "hi")
        #expect(decrypted.message.id == "m1")
        #expect(decrypted.message.from == message.from)
        #expect(decrypted.sentTime == testEnvelopeTime)
    }

    /// The envelope names who wrote it and to whom (XEP-0420), so a stanza readdressed on the way is not believed.
    @Test(arguments: [("alice@example.org/phone", "bob@example.org/desktop", true), ("mallory@example.org/x", "bob@example.org/desktop", false),
                      ("alice@example.org/phone", "carol@example.org/desktop", false)])
    func `the reference's envelope passes only in a stanza between the parties it names`(from: String, to: String, passes: Bool) throws {
        let fixture = try #require(try OMEMO2Fixtures.conversation().messages.first)
        let recorder = try Recorder(account: #require(FullJID.parse("bob@example.org/desktop")))
        let bob = try recorder.installedModule(identity: OMEMO2Fixtures.device("bob").identityData)
        var message = try XMLElement(name: "message", attributes: ["from": from, "to": to, "type": "chat", "id": "m0"])
        try message.addChild(stanza(fixture.encrypted))

        try bob.handleMessage(XMPPMessage(element: message))

        if passes {
            #expect(recorder.decryptedEvents.map(\.message.body) == ["Hello Bob!"])
        } else {
            #expect(recorder.outcomes.map(\.reason) == [.mismatchedEnvelope])
        }
    }

    /// XEP-0384 requires the recipient affix only in a room's envelope, and makes the sender affix a SHOULD.
    @Test(arguments: ["<from jid='alice@example.com'/>", ""])
    func `a chat message's envelope may leave out its recipient, and its sender`(fromAffix: String) async throws {
        let message = try await parties.aliceSends(envelope: envelope(body: "hi", affixes: fromAffix), id: "m1")

        try parties.bob.handleMessage(message)

        #expect(parties.bobRecorder.decryptedEvents.map(\.message.body) == ["hi"])
    }

    /// The recipient tells a room message from a private one, so a server cannot pass one off as the other (XEP-0384).
    @Test(arguments: [XMPPMessage.MessageType.groupchat, .chat])
    func `a room message or room's private message whose envelope names no recipient is reported`(type: XMPPMessage.MessageType) async throws {
        let room = try #require(BareJID.parse("room@conference.example.com"))
        try await parties.bobJoins(room, aliceRevealed: true)

        let message = try await parties.aliceSends(
            envelope: envelope(body: "hi", affixes: "<from jid='alice@example.com'/>"), id: "m1", type: type, from: "\(room)/alice"
        )
        try parties.bob.handleMessage(message)

        #expect(parties.bobRecorder.outcomes.map(\.reason) == [.mismatchedEnvelope])
    }

    @Test(arguments: [true, false])
    func `a room message decrypts with the session of the occupant's real address, which its envelope names`(revealsJIDs: Bool) async throws {
        let room = try #require(BareJID.parse("room@conference.example.com"))
        try await parties.bobJoins(room, aliceRevealed: revealsJIDs)
        let encrypted = try await parties.alice.encryptGroupMessage(
            content: [bodyElement("hello room")], time: testEnvelopeTime, roomJID: room, recipients: [(parties.bobJID, [200])], ownDeviceIDs: []
        ).encrypted
        var message = XMLElement(name: "message", attributes: ["from": "\(room)/alice", "to": "bob@example.com/laptop", "type": "groupchat", "id": "g1"])
        message.addChild(encrypted)

        try parties.bob.handleMessage(XMPPMessage(element: message))

        if revealsJIDs {
            #expect(parties.bobRecorder.decryptedEvents.map(\.message.body) == ["hello room"])
            #expect(parties.bobRecorder.decryptedEvents.first?.message.from?.description == "\(room)/alice")
        } else {
            #expect(parties.bobRecorder.outcomes.map(\.reason) == [.senderHidden])
        }
    }

    @Test func `a room's private message decrypts with the session of the occupant's real address`() async throws {
        let room = try #require(BareJID.parse("room@conference.example.com"))
        try await parties.bobJoins(room, aliceRevealed: true)
        var message = try await parties.aliceSends([bodyElement("psst")], id: "p1")
        message.element.attributes["from"] = "\(room)/alice"

        try parties.bob.handleMessage(message)

        #expect(parties.bobRecorder.decryptedEvents.map(\.message.body) == ["psst"])
    }

    /// Only what the encryption covers counts: a receipt, marker or chat state next to the payload could be anyone's.
    @Test func `a receipt request and chat state inside the envelope are acted on, and those next to the payload are not`() async throws {
        let receipts = ReceiptsModule()
        let chatStates = ChatStatesModule()
        receipts.setUp(parties.bobRecorder.context)
        chatStates.setUp(parties.bobRecorder.context)
        parties.bobRecorder.forwardDecryptedMessages(to: [receipts, chatStates])
        var message = try await parties.aliceSends(
            [bodyElement("hi"), XMLElement(name: "request", namespace: XMPPNamespaces.receipts), XMLElement(name: "composing", namespace: XMPPNamespaces.chatStates)],
            id: "m1"
        )
        message.element.addChild(XMLElement(name: "received", namespace: XMPPNamespaces.receipts, attributes: ["id": "x1"]))
        message.element.addChild(XMLElement(name: "displayed", namespace: XMPPNamespaces.chatMarkers, attributes: ["id": "x1"]))
        message.element.addChild(XMLElement(name: "gone", namespace: XMPPNamespaces.chatStates))

        for module in [receipts, chatStates, parties.bob] as [any XMPPModule] {
            try module.handleMessage(message)
        }

        let recorder = parties.bobRecorder
        try await eventually { recorder.sentMessages.contains { $0.child(named: "received")?.attribute("id") == "m1" } }
        let states: [ChatState] = parties.bobRecorder.events.compactMap { if case let .chatStateChanged(_, state, _) = $0 { state } else { nil } }
        #expect(states == [.composing])
        #expect(!parties.bobRecorder.events.contains { if case .deliveryReceiptReceived = $0 { true } else { false } })
        #expect(!parties.bobRecorder.events.contains { if case .chatMarkerReceived = $0 { true } else { false } })
    }

    /// The empty message completes the session the key exchange started, so the sender stops repeating it. It carries
    /// nothing anyone is shown.
    @Test func `a key exchange is answered with an empty message, which advances the sender's session and shows nothing`() async throws {
        let first = try await parties.aliceSends([bodyElement("one")], id: "m1")
        try parties.bob.handleMessage(first)
        let recorder = parties.bobRecorder
        try await eventually { !recorder.sentMessages.isEmpty }
        var reply = try #require(parties.bobRecorder.sentMessages.first)
        reply.attributes["from"] = "bob@example.com/laptop"

        try parties.alice.handleMessage(XMPPMessage(element: reply))
        let second = try await parties.aliceSends([bodyElement("two")], id: "m2")

        #expect(reply.attribute("to") == "alice@example.com")
        #expect(reply.child(named: "encrypted")?.child(named: "header")?.child(named: "keys")?.attribute("jid") == "alice@example.com")
        #expect(reply.child(named: "encrypted")?.child(named: "payload") == nil)
        #expect(reply.child(named: "store", namespace: XMPPNamespaces.processingHints) != nil)
        #expect(parties.aliceRecorder.outcomes.isEmpty)
        #expect(parties.aliceRecorder.events.contains { if case .omemoSessionAdvanced = $0 { true } else { false } })
        #expect(try isKeyExchange(#require(first.element.child(named: "encrypted"))))
        #expect(try !isKeyExchange(#require(second.element.child(named: "encrypted"))))
    }

    /// A send that waits on the account's device list after encrypting for the contact must not put back the session
    /// it encrypted with, since a message received meanwhile moved that session on.
    @Test func `a session a reply confirms while a send waits stays confirmed`() async throws {
        let reached = AsyncSemaphore()
        let release = AsyncSemaphore()
        let aliceIdentity = parties.aliceIdentity
        let recorder = try Recorder(account: #require(FullJID.parse("bob@example.com/laptop"))) { iq in
            guard iq.child(named: "pubsub")?.child(named: "items")?.attribute("node") == XMPPNamespaces.omemoDevices else {
                return bundleItems(for: aliceIdentity)
            }
            await reached.signal()
            await release.wait()
            return nil
        }
        let bob = recorder.installedModule(identity: parties.bobIdentity.data)
        var first = XMLElement(name: "message", attributes: ["from": "bob@example.com/laptop", "to": "alice@example.com/phone", "type": "chat", "id": "b1"])
        try await first.addChild(bob.encryptMessage(
            content: [bodyElement("one")], time: testEnvelopeTime, to: parties.aliceJID, recipientDeviceIDs: [100], ownDeviceIDs: []
        ).encrypted)
        try parties.alice.handleMessage(XMPPMessage(element: first))
        let aliceRecorder = parties.aliceRecorder
        try await eventually { !aliceRecorder.sentMessages.isEmpty }
        var reply = try #require(aliceRecorder.sentMessages.first)
        reply.attributes["from"] = "alice@example.com/phone"

        let aliceJID = parties.aliceJID
        let waiting = Task {
            try await bob.encryptMessage(content: [bodyElement("two")], time: testEnvelopeTime, to: aliceJID, recipientDeviceIDs: [100])
        }
        await reached.wait()
        try bob.handleMessage(XMPPMessage(element: reply))
        await release.signal()
        _ = try await waiting.value
        let third = try await bob.encryptMessage(
            content: [bodyElement("three")], time: testEnvelopeTime, to: parties.aliceJID, recipientDeviceIDs: [100], ownDeviceIDs: []
        ).encrypted

        #expect(!isKeyExchange(third))
    }

    /// A send that fetched the contact's bundle to start a session must not replace the one the contact's key
    /// exchange started meanwhile, which the contact's next messages are encrypted with.
    @Test func `a session a key exchange starts while a send fetches the bundle is the one kept`() async throws {
        let reached = AsyncSemaphore()
        let release = AsyncSemaphore()
        let aliceIdentity = parties.aliceIdentity
        let recorder = try Recorder(account: #require(FullJID.parse("bob@example.com/laptop"))) { _ in
            await reached.signal()
            await release.wait()
            return bundleItems(for: aliceIdentity)
        }
        let bob = recorder.installedModule(identity: parties.bobIdentity.data)
        let aliceJID = parties.aliceJID
        let sending = Task {
            try await bob.encryptMessage(content: [bodyElement("hi")], time: testEnvelopeTime, to: aliceJID, recipientDeviceIDs: [100], ownDeviceIDs: [])
        }
        await reached.wait()
        try await bob.handleMessage(parties.aliceSends([bodyElement("one")], id: "m1"))
        await release.signal()
        let encrypted = try await sending.value.encrypted

        #expect(!isKeyExchange(encrypted))
        #expect(recorder.events.count { if case .omemoSessionEstablished = $0 { true } else { false } } == 1)
        var message = XMLElement(name: "message", attributes: ["from": "bob@example.com/laptop", "to": "alice@example.com/phone", "type": "chat", "id": "b1"])
        message.addChild(encrypted)
        try parties.alice.handleMessage(XMPPMessage(element: message))
        #expect(parties.aliceRecorder.decryptedEvents.map(\.message.body) == ["hi"])
    }

    @Test func `the sender gets a heartbeat once a message numbered 53 arrives in its run on one ratchet key, and only once`() async throws {
        let recorder = parties.bobRecorder
        for index in 0 ... 53 {
            try await parties.bob.handleMessage(parties.aliceSends([bodyElement("\(index)")], id: "m\(index)"))
            if index == 52 {
                // Message 0's key exchange is answered right away, and the run's heartbeat comes only with its 54th message.
                try await eventually { recorder.sentMessages.count == 1 }
            }
        }
        try await eventually { recorder.sentMessages.count == 2 }

        try await parties.bob.handleMessage(parties.aliceSends([bodyElement("54")], id: "m54"))

        #expect(parties.bobRecorder.decryptedEvents.count == 55)
        #expect(parties.bobRecorder.sessionAdvances == 2)
    }

    /// Only the sender's current ratchet key asks for a heartbeat, so a late message from its run before does not.
    @Test func `a late message numbered 53 or higher on the sender's previous ratchet key gets no heartbeat`() async throws {
        let recorder = parties.bobRecorder
        var earlierRun: [XMPPMessage] = []
        for index in 0 ... 53 {
            try await earlierRun.append(parties.aliceSends([bodyElement("\(index)")], id: "m\(index)"))
        }
        try parties.bob.handleMessage(earlierRun[0])
        try await eventually { recorder.sentMessages.count == 1 }
        var reply = try #require(recorder.sentMessages.first)
        reply.attributes["from"] = "bob@example.com/laptop"
        try parties.alice.handleMessage(XMPPMessage(element: reply))
        try await parties.bob.handleMessage(parties.aliceSends([bodyElement("next run")], id: "n0"))

        try parties.bob.handleMessage(earlierRun[53])

        #expect(parties.bobRecorder.decryptedEvents.map(\.message.body) == ["0", "next run", "53"])
        #expect(parties.bobRecorder.sessionAdvances == 1)
    }

    @Test(arguments: [true, false])
    func `a message not encrypted for this device is reported when it has a payload`(hasPayload: Bool) async throws {
        var message = try await parties.aliceSends([bodyElement("hi")], id: "m1", deviceIDs: [999])
        if !hasPayload {
            try removePayload(from: &message)
        }

        try parties.bob.handleMessage(message)

        #expect(parties.bobRecorder.outcomes.map(\.reason) == (hasPayload ? [.notForThisDevice] : []))
    }

    /// The bounce carries the keys this device wrote for others, so it would read as one not encrypted for it.
    @Test func `an error bounce of a message this device sent is neither shown nor reported`() async throws {
        let encrypted = try await parties.bob.encryptMessage(
            content: [bodyElement("hi")], time: testEnvelopeTime, to: parties.aliceJID, recipientDeviceIDs: [100], ownDeviceIDs: []
        ).encrypted
        var bounce = XMLElement(name: "message", attributes: ["from": "alice@example.com", "to": "bob@example.com/laptop", "type": "error", "id": "m1"])
        bounce.addChild(encrypted)
        bounce.addChild(XMLElement(name: "error", attributes: ["type": "cancel"]))
        let message = XMPPMessage(element: bounce)

        try parties.bob.handleMessage(message)
        let forwarded = parties.bob.receiveForwardedMessage(message)

        #expect(parties.bobRecorder.outcomes.isEmpty)
        #expect(forwarded == nil)
    }

    /// A carbon's message is read for the caller to file, so none of it reaches the modules acting on live messages.
    @Test func `a message another of the account's devices sent reads from its carbon`() async throws {
        let bob2Recorder = try Recorder(account: #require(FullJID.parse("bob@example.com/phone"))) { _ in bundleItems(for: parties.aliceIdentity) }
        bob2Recorder.answerBundle(of: parties.bobIdentity, for: 200)
        let bob2 = try bob2Recorder.installedModule(identity: makeTestOMEMOIdentity(deviceID: 300, preKeyIDs: [1]).data)
        let encrypted = try await bob2.encryptMessage(
            content: [bodyElement("sent elsewhere")], time: testEnvelopeTime, to: parties.aliceJID, recipientDeviceIDs: [100], ownDeviceIDs: [200]
        ).encrypted
        var message = XMLElement(name: "message", attributes: ["from": "bob@example.com/phone", "to": "alice@example.com", "type": "chat", "id": "c1"])
        message.addChild(encrypted)

        let outcome = parties.bob.receiveForwardedMessage(XMPPMessage(element: message))

        guard case let .decrypted(decrypted) = outcome else {
            Issue.record("Expected the carbon's message to decrypt, got \(String(describing: outcome))")
            return
        }
        #expect(decrypted.message.body == "sent elsewhere")
        #expect(parties.bobRecorder.outcomes.isEmpty)
        #expect(parties.bobRecorder.dispatched.isEmpty)
    }

    @Test func `a carbon whose payload cannot be read is undecryptable whatever stands next to it in the clear`() async throws {
        var message = try await parties.aliceSends([bodyElement("hi")], id: "m1", deviceIDs: [999])
        message.body = "fallback"
        message.element.addChild(XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": "m0"]))

        let outcome = parties.bob.receiveForwardedMessage(message)

        #expect(outcome?.reason == .notForThisDevice)
    }
}

// MARK: - Helpers

private extension OMEMOReceiveOutcome {
    var reason: OMEMOUndecryptableReason? {
        if case let .undecryptable(reason) = self { reason } else { nil }
    }
}

/// An envelope with `body` as its content, padding, and `affixes` written out.
private func envelope(body: String, affixes: String) -> String {
    "<envelope xmlns='\(XMPPNamespaces.sce)'><content><body xmlns='\(XMPPNamespaces.client)'>\(body)</body></content><rpad>xyz</rpad>\(affixes)</envelope>"
}

private func removePayload(from message: inout XMPPMessage) throws {
    var encrypted = try #require(message.element.child(named: "encrypted", namespace: XMPPNamespaces.omemo))
    encrypted.children.removeAll { if case let .element(child) = $0 { child.name == "payload" } else { false } }
    message.element.children = [.element(encrypted)]
}

/// Plays the server for a module driven without a client: answers bundle fetches, and records what the module sends,
/// reports and hands to the modules acting on decrypted messages.
private final class Recorder: Sendable {
    private struct Recorded {
        var events: [XMPPEvent] = []
        var sent: [XMLElement] = []
        var dispatched: [XMPPMessage] = []
        var forwardTo: [any XMPPModule] = []
        var bundles: [String: XMLElement] = [:]
    }

    let account: FullJID
    private let recorded = OSAllocatedUnfairLock(initialState: Recorded())
    private let answer: @Sendable (XMLElement) async -> XMLElement?

    init(account: FullJID, answer: @escaping @Sendable (XMLElement) async -> XMLElement? = { _ in nil }) {
        self.account = account
        self.answer = answer
    }

    var context: ModuleContext {
        makeStubModuleContext(
            sendStanza: { [recorded] stanza, onAccepted in
                onAccepted?()
                recorded.withLock { $0.sent.append(stanza.element) }
            },
            sendIQ: { [recorded, answer] iq, _ in
                let item = iq.element.child(named: "pubsub")?.child(named: "items")?.child(named: "item")?.attribute("id")
                if let bundle = recorded.withLock({ recorded in item.flatMap { recorded.bundles.removeValue(forKey: $0) } }) {
                    return bundle
                }
                return await answer(iq.element)
            },
            emitEvent: { [recorded] event in recorded.withLock { $0.events.append(event) } },
            connectedJID: account,
            dispatchDecryptedMessage: { [recorded] message in
                let modules = recorded.withLock { recorded in
                    recorded.dispatched.append(message)
                    return recorded.forwardTo
                }
                for module in modules {
                    module.handleDecryptedMessage(message)
                }
            }
        )
    }

    /// Answers the next fetch of the bundle `deviceID` with `identity`'s bundle.
    func answerBundle(of identity: TestOMEMOIdentity, for deviceID: UInt32) {
        recorded.withLock { $0.bundles["\(deviceID)"] = bundleItems(for: identity) }
    }

    func forwardDecryptedMessages(to modules: [any XMPPModule]) {
        recorded.withLock { $0.forwardTo = modules }
    }

    var events: [XMPPEvent] {
        recorded.withLock { $0.events }
    }

    var sentMessages: [XMLElement] {
        recorded.withLock { $0.sent.filter { $0.name == "message" } }
    }

    var dispatched: [XMPPMessage] {
        recorded.withLock { $0.dispatched }
    }

    /// How often the module reported a session moved on: once for each empty message it sends, as it encrypts it,
    /// and once for each it receives.
    var sessionAdvances: Int {
        events.count { if case .omemoSessionAdvanced = $0 { true } else { false } }
    }

    var outcomes: [OMEMOReceiveOutcome] {
        events.compactMap { if case let .omemoEncryptedMessageReceived(_, outcome) = $0 { outcome } else { nil } }
    }

    var decryptedEvents: [OMEMODecryptedMessage] {
        outcomes.compactMap { if case let .decrypted(decrypted) = $0 { decrypted } else { nil } }
    }

    func installedModule(identity: OMEMOModule.OMEMOIdentityData, mucModule: MUCModule? = nil) -> OMEMOModule {
        makeInstalledOMEMOModule(identity: identity, context: context, mucModule: mucModule)
    }
}

/// Alice (device 100) writes to bob (device 200), the account whose module is under test.
private struct Parties {
    let aliceJID = BareJID(localPart: "alice", domainPart: "example.com")!
    let bobJID = BareJID(localPart: "bob", domainPart: "example.com")!
    let aliceIdentity: TestOMEMOIdentity
    let bobIdentity: TestOMEMOIdentity
    let alice: OMEMOModule
    let aliceRecorder: Recorder
    let bob: OMEMOModule
    let bobRecorder: Recorder
    let mucModule: MUCModule

    static func make() async throws -> Parties {
        let aliceIdentity = try makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1])
        let bobIdentity = try makeTestOMEMOIdentity(deviceID: 200, preKeyIDs: [7])
        let aliceRecorder = try Recorder(account: #require(FullJID.parse("alice@example.com/phone"))) { _ in bundleItems(for: bobIdentity) }
        let bobRecorder = try Recorder(account: #require(FullJID.parse("bob@example.com/laptop"))) { _ in bundleItems(for: aliceIdentity) }
        let mucModule = MUCModule()
        mucModule.setUp(bobRecorder.context)
        return Parties(
            aliceIdentity: aliceIdentity, bobIdentity: bobIdentity,
            alice: aliceRecorder.installedModule(identity: aliceIdentity.data), aliceRecorder: aliceRecorder,
            bob: bobRecorder.installedModule(identity: bobIdentity.data, mucModule: mucModule), bobRecorder: bobRecorder,
            mucModule: mucModule
        )
    }

    /// A chat message from alice's phone to bob's laptop, encrypted for `deviceIDs` of bob's.
    func aliceSends(_ content: [XMLElement], id: String, deviceIDs: [UInt32] = [200]) async throws -> XMPPMessage {
        let encrypted = try await alice.encryptMessage(
            content: content, time: testEnvelopeTime, to: bobJID, recipientDeviceIDs: deviceIDs, ownDeviceIDs: []
        ).encrypted
        var message = XMLElement(name: "message", attributes: ["from": "alice@example.com/phone", "to": "bob@example.com/laptop", "type": "chat", "id": id])
        message.addChild(encrypted)
        return XMPPMessage(element: message)
    }

    /// A message from alice to bob's device 200 whose payload is `envelope`, as another client could write it. A first
    /// message, never delivered, sets up alice's session.
    func aliceSends(
        envelope: String, id: String, type: XMPPMessage.MessageType = .chat, from: String = "alice@example.com/phone"
    ) async throws -> XMPPMessage {
        _ = try await aliceSends([], id: "setup")
        let payload = try OMEMOPayload(encrypting: Array(envelope.utf8), key: Array(repeating: 1, count: OMEMOPayload.keyLength))
        let sessionKey = SessionKey(jid: bobJID, deviceID: 200)
        let key = try alice.state.withLock { state in
            guard var session = state.sessions[sessionKey] else { throw OMEMOModuleError.noSession }
            let key = try session.encryptKey(payload.keyMaterial)
            state.sessions[sessionKey] = session
            return key
        }
        let encrypted = alice.buildEncryptedElement(
            keys: [(bobJID, alice.buildKeyElement(deviceID: 200, data: key.data, isKex: key.isKex))],
            payload: Base64.encode(payload.ciphertext), senderDeviceID: 100
        )
        var message = XMLElement(name: "message", attributes: ["from": from, "to": "bob@example.com/laptop", "type": type.rawValue, "id": id])
        message.addChild(encrypted)
        return XMPPMessage(element: message)
    }

    /// Bob is in `room` with alice, whose real address the room shows when `aliceRevealed`.
    func bobJoins(_ room: BareJID, aliceRevealed: Bool) async throws {
        _ = try await mucModule.joinRoom(room, nickname: "bob")
        let jid = aliceRevealed ? " jid='alice@example.com/phone'" : ""
        try mucModule.handlePresence(XMPPPresence(element: stanza(
            "<presence from='\(room)/alice'><x xmlns='\(XMPPNamespaces.mucUser)'><item affiliation='member' role='participant'\(jid)/></x></presence>"
        )))
    }
}
