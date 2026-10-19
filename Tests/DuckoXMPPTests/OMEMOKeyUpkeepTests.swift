import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

extension OMEMOModuleTests {
    /// XEP-0384: a key exchange must name one of this device's pre-keys. One that fails to decrypt shows only when it
    /// carried a message of its own.
    struct KeyExchangeTests {
        private let recipient: TestOMEMOIdentity

        init() throws {
            self.recipient = try makeTestOMEMOIdentity(deviceID: 200, preKeyIDs: [7])
        }

        @Test(arguments: [true, false])
        func `A key exchange naming no pre-key, or one this device does not hold, is rejected`(namesNone: Bool) async throws {
            let message = try await makeKEXMessage(to: recipient, plaintext: "secret")
            let identity = namesNone ? recipient.data : recipient.data.withPreKeys([])
            let module = makeInstalledModule(identity: identity, peer: StubPEPPeer())
            var encrypted = try #require(message.child(named: "encrypted", namespace: XMPPNamespaces.omemo))
            if namesNone {
                encrypted = try replacingPreKeyID(with: 0xFFFF_FFFF, in: encrypted)
            }

            let sender = try #require(FullJID.parse("peer@example.com/i"))

            #expect(throws: OMEMOModuleError.unknownPreKey) {
                _ = try module.decryptIncomingMessage(encrypted, from: .full(sender))
            }
        }

        @Test func `A key exchange reports the pre-key it used up`() async throws {
            let peer = StubPEPPeer()
            let module = makeInstalledModule(identity: recipient.data, peer: peer)

            try await module.handleMessage(XMPPMessage(element: makeKEXMessage(to: recipient, plaintext: "secret")))

            #expect(peer.sessionEstablishedPreKeyIDs == [7])
        }

        @Test func `A key exchange delivered again is ignored and leaves its session as it was`() async throws {
            let message = try await makeKEXMessage(to: recipient, plaintext: "secret")
            let module = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer())
            let encrypted = try #require(message.child(named: "encrypted", namespace: XMPPNamespaces.omemo))
            _ = try module.decryptIncomingMessage(encrypted, from: .full(peerJID))
            let session = try #require(module.allSessionEntries().first).sessionData

            #expect(throws: OMEMOModuleError.replayedKeyExchange) {
                _ = try module.decryptIncomingMessage(encrypted, from: .full(peerJID))
            }

            #expect(module.allSessionEntries().map(\.sessionData) == [session])
        }

        @Test func `A key exchange delivered again under a new id shows nothing`() async throws {
            let peer = StubPEPPeer()
            let module = makeInstalledModule(identity: recipient.data, peer: peer)
            var message = try await makeKEXMessage(to: recipient, plaintext: "secret")

            for id in ["m1", "m2"] {
                message.setAttribute("id", value: id)
                try module.handleMessage(XMPPMessage(element: message))
            }

            #expect(peer.encryptedMessageIDs == ["m1"])
            #expect(peer.undecryptableMessageIDs.isEmpty)
        }

        @Test(arguments: [true, false])
        func `A key exchange replayed under another device or contact builds no session`(otherDevice: Bool) async throws {
            let message = try await makeKEXMessage(to: recipient, plaintext: "secret")
            let module = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer())
            let encrypted = try #require(message.child(named: "encrypted", namespace: XMPPNamespaces.omemo))
            _ = try module.decryptIncomingMessage(encrypted, from: .full(peerJID))

            let other = try #require(FullJID.parse("victim@example.com/x"))
            #expect(throws: OMEMOModuleError.replayedKeyExchange) {
                _ = try module.decryptIncomingMessage(
                    otherDevice ? replacingSenderDevice(with: 424_242, in: encrypted) : encrypted, from: .full(otherDevice ? peerJID : other)
                )
            }

            #expect(module.allSessionEntries().count == 1)
        }

        @Test func `A sender repeating its key exchange is read through the session it started`() async throws {
            let messages = try await makeRepeatingKEXMessages(to: recipient, plaintexts: ["one", "two", "three"])
            let module = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer())

            let bodies = try messages.map { try module.decryptIncomingMessage($0, from: .full(peerJID)).body }

            #expect(bodies == ["one", "two", "three"])
            #expect(module.allSessionEntries().count == 1)
        }

        @Test func `A repeated key exchange reads through the restored session once its pre-key is gone`() async throws {
            let messages = try await makeRepeatingKEXMessages(to: recipient, plaintexts: ["one", "two"])
            let earlier = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer())
            _ = try earlier.decryptIncomingMessage(messages[0], from: .full(peerJID))
            // The next connection loads only unused pre-keys, so it no longer holds the one the key exchange names.
            let module = makeInstalledModule(identity: recipient.data.withPreKeys([]), peer: StubPEPPeer())
            module.restoreSessions(earlier.allSessionEntries())

            #expect(try module.decryptIncomingMessage(messages[1], from: .full(peerJID)).body == "two")
        }

        @Test func `A new key exchange naming a used pre-key replaces the session`() async throws {
            let first = try await makeKEXMessage(to: recipient, plaintext: "old")
            let restarted = try await makeKEXMessage(to: recipient, plaintext: "new")
            let module = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer())
            let firstEncrypted = try #require(first.child(named: "encrypted", namespace: XMPPNamespaces.omemo))
            _ = try module.decryptIncomingMessage(firstEncrypted, from: .full(peerJID))
            let oldSession = try #require(module.allSessionEntries().first).sessionData
            // The same device starting over from a bundle that still lists the pre-key it used before.
            let restartedEncrypted = try #require(restarted.child(named: "encrypted", namespace: XMPPNamespaces.omemo))
            let sameDevice = try replacingSenderDevice(with: senderDeviceID(of: firstEncrypted), in: restartedEncrypted)

            #expect(try module.decryptIncomingMessage(sameDevice, from: .full(peerJID)).body == "new")
            #expect(module.allSessionEntries().map(\.sessionData) != [oldSession])
            #expect(module.allSessionEntries().count == 1)
        }

        @Test func `A pre-key retired as used elsewhere cannot be taken up`() async throws {
            let message = try await makeKEXMessage(to: recipient, plaintext: "secret")
            let module = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer())
            let encrypted = try #require(message.child(named: "encrypted", namespace: XMPPNamespaces.omemo))

            module.retirePreKeys([7])

            #expect(throws: OMEMOModuleError.unknownPreKey) {
                _ = try module.decryptIncomingMessage(encrypted, from: .full(peerJID))
            }
        }

        @Test func `A pre-key this connection used stays open to a second contact after it is retired`() async throws {
            let first = try await makeKEXMessage(to: recipient, plaintext: "first")
            let second = try await makeKEXMessage(to: recipient, plaintext: "second")
            let module = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer())
            let firstEncrypted = try #require(first.child(named: "encrypted", namespace: XMPPNamespaces.omemo))
            _ = try module.decryptIncomingMessage(firstEncrypted, from: .full(peerJID))

            module.retirePreKeys([7])

            // Both contacts picked pre-key 7 from the same bundle.
            let other = try #require(FullJID.parse("other@example.com/x"))
            let secondEncrypted = try #require(second.child(named: "encrypted", namespace: XMPPNamespaces.omemo))
            #expect(try module.decryptIncomingMessage(secondEncrypted, from: .full(other)).body == "second")
        }

        @Test func `A session this device starts reports no pre-key`() async throws {
            let recipient = recipient
            let peer = StubPEPPeer { _ in bundleItems(for: recipient) }
            let module = try makeInstalledModule(identity: makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1]).data, peer: peer)

            _ = try await module.encryptMessage(plaintext: "hi", to: recipientJID, recipientDeviceIDs: [200], ownDeviceIDs: [])

            #expect(peer.sessionEstablishedPreKeyIDs == [nil])
        }

        @Test func `A device whose bundle lists no pre-keys is dropped as a recipient`() async throws {
            let empty = TestOMEMOIdentity(
                data: recipient.data.withPreKeys([]), identityKeyPair: recipient.identityKeyPair,
                signedPreKey: recipient.signedPreKey, preKeys: []
            )
            let peer = StubPEPPeer { _ in bundleItems(for: empty) }
            let module = try makeInstalledModule(identity: makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1]).data, peer: peer)

            await #expect(throws: OMEMOModuleError.noUsableRecipientDevices) {
                _ = try await module.encryptMessage(plaintext: "hi", to: recipientJID, recipientDeviceIDs: [200], ownDeviceIDs: [])
            }
        }

        @Test(arguments: ["message", "correction", "retraction", "keyOnly"])
        func `A failed decrypt shows only when the stanza was a message of its own`(kind: String) throws {
            let peer = StubPEPPeer()
            let module = makeInstalledModule(identity: recipient.data, peer: peer)
            var message = XMLElement(name: "message", attributes: ["from": "peer@example.com/i", "id": "m1"])
            var header = XMLElement(name: "header", attributes: ["sid": "1"])
            var key = XMLElement(name: "key", attributes: ["rid": "200"])
            key.addText("AAAA")
            header.addChild(key)
            var encrypted = XMLElement(name: "encrypted", namespace: XMPPNamespaces.omemo)
            encrypted.addChild(header)
            if kind != "keyOnly" {
                var payload = XMLElement(name: "payload")
                payload.addText("AAAA")
                encrypted.addChild(payload)
            }
            message.addChild(encrypted)
            if kind == "correction" {
                message.addChild(XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": "m0"]))
            } else if kind == "retraction" {
                message.addChild(XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": "m0"]))
            }

            try module.handleMessage(XMPPMessage(element: message))

            #expect(peer.undecryptableMessageIDs == (kind == "message" ? ["m1"] : []))
        }
    }

    /// The published bundle follows the pre-keys this device can hand out, and publishes never overlap.
    struct BundleUpkeepTests {
        private let identity: TestOMEMOIdentity

        init() throws {
            self.identity = try makeTestOMEMOIdentity(deviceID: 200, preKeyIDs: [7, 8])
        }

        @Test func `A republish after a key exchange leaves the used pre-key out`() async throws {
            let peer = StubPEPPeer()
            let module = makeInstalledModule(identity: identity.data, peer: peer)
            try await module.handleMessage(XMPPMessage(element: makeKEXMessage(to: identity, plaintext: "secret")))
            #expect(module.bundleNeedsPublish)

            try await module.republishBundle()

            // The contact picked one of the two pre-keys at random.
            let used = try #require(peer.sessionEstablishedPreKeyIDs.first ?? nil)
            let bundle = try #require(peer.bundlePublishes.last)
            #expect(publishedPreKeyIDs(in: bundle) == ["7", "8"].filter { $0 != "\(used)" })
            #expect(!module.bundleNeedsPublish)
        }

        @Test func `A bundle still needs publishing after a failed publish, and not after one that succeeds`() async throws {
            let failing = OSAllocatedUnfairLock(initialState: true)
            let peer = StubPEPPeer { _ in
                if failing.withLock({ $0 }) { throw XMPPStanzaError(errorType: .wait, condition: .resourceConstraint) }
                return nil
            }
            let module = makeInstalledModule(identity: identity.data, peer: peer)

            await #expect(throws: XMPPStanzaError.self) { try await module.republishBundle() }
            #expect(module.bundleNeedsPublish)

            failing.withLock { $0 = false }
            try await module.republishBundle()
            #expect(!module.bundleNeedsPublish)
        }

        @Test func `A publish asked for during another starts once it ends, and fails with its own outcome`() async throws {
            struct Publishes {
                var count = 0
                var inFlight = 0
                var overlapped = false
            }
            let entered = AsyncSemaphore()
            let secondEntered = AsyncSemaphore()
            let release = AsyncSemaphore()
            let publishes = OSAllocatedUnfairLock(initialState: Publishes())
            let peer = StubPEPPeer { _ in
                let publish = publishes.withLock { publishes in
                    publishes.count += 1
                    publishes.inFlight += 1
                    publishes.overlapped = publishes.overlapped || publishes.inFlight > 1
                    return publishes.count
                }
                defer { publishes.withLock { $0.inFlight -= 1 } }
                if publish == 1 {
                    await entered.signal()
                    await release.wait()
                    return nil
                }
                await secondEntered.signal()
                throw XMPPStanzaError(errorType: .wait, condition: .resourceConstraint)
            }
            let module = makeInstalledModule(identity: identity.data, peer: peer)

            let first = Task { try await module.republishBundle() }
            await entered.wait()
            // Runs up to its first suspension here, so the call is made while the first publish is still out.
            let second = Task.immediate { try await module.republishBundle() }
            // A publish started alongside the first would reach the server well within this.
            _ = try await boundedOutcome(timeout: .milliseconds(200)) { await secondEntered.wait() }
            await release.signal()

            try await first.value
            await #expect(throws: XMPPStanzaError.self) { try await second.value }
            let recorded = publishes.withLock { $0 }
            #expect(recorded.count == 2)
            #expect(!recorded.overlapped)
        }

        @Test func `A caller cancelled during its publish leaves the publish to finish`() async {
            let entered = AsyncSemaphore()
            let release = AsyncSemaphore()
            // Fails a cancelled publish, as the client's `sendIQ` does.
            let peer = StubPEPPeer { _ in
                await entered.signal()
                await release.wait()
                try Task.checkCancellation()
                return nil
            }
            let module = makeInstalledModule(identity: identity.data, peer: peer)

            let caller = Task { try await module.republishBundle() }
            await entered.wait()
            caller.cancel()
            await release.signal()
            _ = await caller.result

            #expect(peer.bundlePublishes.count == 1)
            #expect(!module.bundleNeedsPublish)
        }

        @Test func `Pre-keys used up elsewhere leave the bundle`() async throws {
            let peer = StubPEPPeer()
            let module = makeInstalledModule(identity: identity.data, peer: peer)
            try await module.republishBundle()

            module.retirePreKeys([8, 99])

            #expect(module.bundleNeedsPublish)
            try await module.republishBundle()
            let bundle = try #require(peer.bundlePublishes.last)
            #expect(publishedPreKeyIDs(in: bundle) == ["7"])
        }

        @Test func `A connect waiting on the device list publishes last a bundle with pre-keys added meanwhile`() async throws {
            let entered = AsyncSemaphore()
            let release = AsyncSemaphore()
            let peer = StubPEPPeer { iq in
                if iq.xmlString.contains("<items"), iq.xmlString.contains(XMPPNamespaces.omemoDevices) {
                    await entered.signal()
                    await release.wait()
                }
                return nil
            }
            let module = makeInstalledModule(identity: identity.data, peer: peer)

            let connect = Task { try await module.handleConnect() }
            await entered.wait()
            module.addPreKeys([OMEMOPreKey(keyID: 50)])
            try await module.republishBundle()
            await release.signal()
            try await connect.value

            let bundle = try #require(peer.bundlePublishes.last)
            #expect(publishedPreKeyIDs(in: bundle) == ["50", "7", "8"])
        }

        @Test func `An unavailable identity connects without publishing and leaves encryption off`() async throws {
            let peer = StubPEPPeer()
            let pepModule = PEPModule()
            pepModule.setUp(peer.context)
            let module = OMEMOModule(pepModule: pepModule)
            module.setUp(peer.context)
            module.configureIdentity(identity.data)
            module.markIdentityUnavailable()
            module.handleSessionEstablished(resumed: false)

            try await module.handleConnect()

            #expect(peer.iqs.isEmpty)
            await #expect(throws: OMEMOModuleError.notSetUp) {
                _ = try await module.encryptMessage(plaintext: "hi", to: recipientJID, recipientDeviceIDs: [1], ownDeviceIDs: [])
            }
        }
    }
}

// MARK: - Helpers

private let recipientJID = BareJID(localPart: "user", domainPart: "example.com")!
private let peerJID = FullJID.parse("peer@example.com/i")!

/// Plays the server for a module driven without a client: records the IQs and events, and answers each IQ with
/// `answer`.
private final class StubPEPPeer: Sendable {
    private struct Recorded {
        var iqs: [XMLElement] = []
        var events: [XMPPEvent] = []
    }

    private let recorded = OSAllocatedUnfairLock(initialState: Recorded())
    private let answer: @Sendable (XMLElement) async throws -> XMLElement?

    init(answer: @escaping @Sendable (XMLElement) async throws -> XMLElement? = { _ in nil }) {
        self.answer = answer
    }

    var context: ModuleContext {
        makeStubModuleContext(
            sendIQ: { [recorded, answer] iq, _ in
                recorded.withLock { $0.iqs.append(iq.element) }
                return try await answer(iq.element)
            },
            emitEvent: { [recorded] event in recorded.withLock { $0.events.append(event) } }
        )
    }

    var iqs: [XMLElement] {
        recorded.withLock { $0.iqs }
    }

    var bundlePublishes: [XMLElement] {
        iqs.filter { $0.xmlString.contains("<publish") && $0.xmlString.contains(OMEMOModule.bundleNodePrefix) }
    }

    var sessionEstablishedPreKeyIDs: [UInt32?] {
        recorded.withLock { recorded in
            recorded.events.compactMap { event in
                if case let .omemoSessionEstablished(_, _, _, consumedPreKeyID) = event { consumedPreKeyID } else { nil }
            }
        }
    }

    var encryptedMessageIDs: [String?] {
        recorded.withLock { recorded in
            recorded.events.compactMap { event in
                if case let .omemoEncryptedMessageReceived(message, _, _) = event { message.id } else { nil }
            }
        }
    }

    var undecryptableMessageIDs: [String] {
        recorded.withLock { recorded in
            recorded.events.compactMap { event in
                if case let .omemoEncryptedMessageReceived(message, nil, _) = event { message.id } else { nil }
            }
        }
    }
}

/// A module with `identity` installed, as an established session installs it, talking to `peer`.
private func makeInstalledModule(identity: OMEMOModule.OMEMOIdentityData, peer: StubPEPPeer) -> OMEMOModule {
    let pepModule = PEPModule()
    pepModule.setUp(peer.context)
    let module = OMEMOModule(pepModule: pepModule)
    module.setUp(peer.context)
    module.configureIdentity(identity)
    module.handleSessionEstablished(resumed: true)
    return module
}

/// The `<pubsub>` answer to a bundle fetch, carrying `identity`'s bundle.
private func bundleItems(for identity: TestOMEMOIdentity) -> XMLElement {
    let bundle = OMEMOPreKeyManager.buildBundle(
        deviceID: OMEMODeviceID(value: identity.data.deviceID),
        identityKeyPair: identity.identityKeyPair,
        signedPreKey: identity.signedPreKey,
        preKeys: identity.preKeys
    )
    var item = XMLElement(name: "item", attributes: ["id": "current"])
    item.addChild(OMEMOModule(pepModule: PEPModule()).buildBundleElement(bundle))
    var items = XMLElement(name: "items", attributes: ["node": "\(OMEMOModule.bundleNodePrefix)\(identity.data.deviceID)"])
    items.addChild(item)
    var pubsub = XMLElement(name: "pubsub", namespace: XMPPNamespaces.pubsub)
    pubsub.addChild(items)
    return pubsub
}

/// `encrypted` with the pre-key id of its key exchange set to `preKeyID`.
private func replacingPreKeyID(with preKeyID: UInt32, in encrypted: XMLElement) throws -> XMLElement {
    let header = try #require(encrypted.child(named: "header"))
    var newHeader = XMLElement(name: "header", attributes: header.attributes)
    for key in header.children(named: "key") {
        guard key.attribute("kex") == "true" else {
            newHeader.addChild(key)
            continue
        }
        let text = try #require(key.textContent)
        var bytes = try #require(Base64.decode(text))
        bytes.replaceSubrange(4 ..< 8, with: [24, 16, 8, 0].map { UInt8(preKeyID >> $0 & 0xFF) })
        var newKey = XMLElement(name: "key", attributes: key.attributes)
        newKey.addText(Base64.encode(bytes))
        newHeader.addChild(newKey)
    }
    return rebuilding(encrypted, header: newHeader)
}

/// The `<encrypted>` elements of messages from one sender to `recipient`. The first starts the session with a key
/// exchange, and each later one repeats that key exchange around its own ratchet message, as a sender does until it
/// hears back (XEP-0384 §4.3).
private func makeRepeatingKEXMessages(to recipient: TestOMEMOIdentity, plaintexts: [String]) async throws -> [XMLElement] {
    let mock = MockTransport()
    let pepModule = PEPModule()
    let sender = OMEMOModule(pepModule: pepModule)
    let (client, _) = try await makeConnectedClient(mock: mock, omemoModule: sender, pepModule: pepModule)
    let deviceIDs = [recipient.data.deviceID]
    let first = Task {
        try await sender.encryptMessage(plaintext: plaintexts[0], to: recipientJID, recipientDeviceIDs: deviceIDs, ownDeviceIDs: [])
    }
    await mock.waitForSent(count: 1)
    let fetchID = try await #require(extractIQID(from: mock.sentBytes[0]))
    await mock.simulateReceive(makeBundleResultIQ(iqID: fetchID, fromJID: recipientJID, identity: recipient, module: sender))
    var encrypted = try await [first.value.encrypted]
    for plaintext in plaintexts.dropFirst() {
        try await encrypted.append(
            sender.encryptMessage(plaintext: plaintext, to: recipientJID, recipientDeviceIDs: deviceIDs, ownDeviceIDs: []).encrypted
        )
    }
    await disconnectFast(client)

    // Signed pre-key id, pre-key id, identity key and ephemeral key come before the ratchet message.
    let kexText = try #require(encrypted[0].child(named: "header")?.children(named: "key").first { $0.attribute("kex") == "true" }?.textContent)
    let kexHeader = try Array(#require(Base64.decode(kexText)).prefix(72))
    return try [encrypted[0]] + encrypted.dropFirst().map { try wrappingInKeyExchange($0, header: kexHeader) }
}

/// `encrypted` with its key wrapped in the key exchange `header`, as a repeated key exchange carries it.
private func wrappingInKeyExchange(_ encrypted: XMLElement, header kexHeader: [UInt8]) throws -> XMLElement {
    let header = try #require(encrypted.child(named: "header"))
    var newHeader = XMLElement(name: "header", attributes: header.attributes)
    for key in header.children(named: "key") {
        let text = try #require(key.textContent)
        let ratchetMessage = try #require(Base64.decode(text))
        var attributes = key.attributes
        attributes["kex"] = "true"
        var newKey = XMLElement(name: "key", attributes: attributes)
        newKey.addText(Base64.encode(kexHeader + ratchetMessage))
        newHeader.addChild(newKey)
    }
    return rebuilding(encrypted, header: newHeader)
}

/// `encrypted` as if sent by the device `deviceID`.
private func replacingSenderDevice(with deviceID: UInt32, in encrypted: XMLElement) throws -> XMLElement {
    let header = try #require(encrypted.child(named: "header"))
    var attributes = header.attributes
    attributes["sid"] = "\(deviceID)"
    var newHeader = XMLElement(name: "header", attributes: attributes)
    for key in header.children(named: "key") {
        newHeader.addChild(key)
    }
    return rebuilding(encrypted, header: newHeader)
}

private func senderDeviceID(of encrypted: XMLElement) throws -> UInt32 {
    try #require(encrypted.child(named: "header")?.attribute("sid").flatMap(UInt32.init))
}

private func rebuilding(_ encrypted: XMLElement, header: XMLElement) -> XMLElement {
    var newEncrypted = XMLElement(name: "encrypted", namespace: XMPPNamespaces.omemo)
    newEncrypted.addChild(header)
    if let payload = encrypted.child(named: "payload") {
        newEncrypted.addChild(payload)
    }
    return newEncrypted
}

/// The pre-key ids a bundle publish carries, in ascending order.
private func publishedPreKeyIDs(in publish: XMLElement) -> [String] {
    let bundle = publish.child(named: "pubsub")?.child(named: "publish")?.child(named: "item")?.child(named: "bundle")
    let preKeys = bundle?.child(named: "prekeys")?.children(named: "preKeyPublic") ?? []
    return preKeys.compactMap { $0.attribute("preKeyId") }.sorted()
}

private extension OMEMOModule.OMEMOIdentityData {
    func withPreKeys(_ preKeys: [PreKeyData]) -> Self {
        Self(
            deviceID: deviceID, identityKeyRaw: identityKeyRaw, signedPreKeyID: signedPreKeyID,
            signedPreKeyRaw: signedPreKeyRaw, signedPreKeySignature: signedPreKeySignature, preKeys: preKeys
        )
    }
}
