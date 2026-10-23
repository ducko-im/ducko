import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

extension OMEMOModuleTests {
    /// XEP-0384: a key exchange must name one of this device's pre-keys. One that fails to decrypt shows whenever it
    /// carries a payload.
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
                encrypted = try removingPreKeyID(from: encrypted)
            }

            let sender = try #require(FullJID.parse("peer@example.com/i"))

            #expect(throws: namesNone ? OMEMOModuleError.invalidKeyData : .unknownPreKey) {
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

        @Test func `A copy of a repeated key exchange on a later connection leaves the session as it was`() async throws {
            let messages = try await makeRepeatingKEXMessages(to: recipient, plaintexts: ["one", "two"])
            let earlier = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer())
            for message in messages {
                _ = try earlier.decryptIncomingMessage(message, from: .full(peerJID))
            }
            // The next connection still holds the pre-key until upkeep retires it.
            let module = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer())
            module.restoreSessions(earlier.allSessionEntries())
            let session = earlier.allSessionEntries().map(\.sessionData)

            #expect(throws: OMEMOModuleError.replayedKeyExchange) {
                _ = try module.decryptIncomingMessage(messages[0], from: .full(peerJID))
            }
            #expect(module.allSessionEntries().map(\.sessionData) == session)
        }

        @Test func `A sender repeats its key exchange until a message from the device confirms the session`() async throws {
            let recipient = recipient
            let senderModule = try makeInstalledModule(
                identity: makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1]).data, peer: StubPEPPeer(account: peerJID) { _ in bundleItems(for: recipient) }
            )
            let recipientModule = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer())
            func send(_ plaintext: String) async throws -> XMLElement {
                try await senderModule.encryptMessage(plaintext: plaintext, to: recipientJID, recipientDeviceIDs: [200], ownDeviceIDs: []).encrypted
            }

            let unanswered = try await [send("one"), send("two")]
            for encrypted in unanswered {
                _ = try recipientModule.decryptIncomingMessage(encrypted, from: .full(peerJID))
            }
            let reply = try await recipientModule.encryptMessage(
                plaintext: "back", to: peerJID.bareJID, recipientDeviceIDs: [100], ownDeviceIDs: []
            ).encrypted
            let replyBody = try senderModule.decryptIncomingMessage(reply, from: .full(#require(FullJID.parse("user@example.com/r")))).body
            let answered = try await send("three")

            #expect(unanswered.map(isKeyExchange) == [true, true])
            #expect(!isKeyExchange(reply))
            #expect(replyBody == "back")
            #expect(!isKeyExchange(answered))
            #expect(try recipientModule.decryptIncomingMessage(answered, from: .full(peerJID)).body == "three")
        }

        @Test func `A key exchange marked with 1 is read as one`() async throws {
            let message = try await makeKEXMessage(to: recipient, plaintext: "secret")
            let module = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer())
            let encrypted = try marking(#require(message.child(named: "encrypted", namespace: XMPPNamespaces.omemo)), kex: "1")

            #expect(try module.decryptIncomingMessage(encrypted, from: .full(peerJID)).body == "secret")
        }

        @Test func `A session stored in the earlier encoding counts as none, so the next message starts a key exchange`() async throws {
            let recipient = recipient
            let module = try makeInstalledModule(
                identity: makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1]).data, peer: StubPEPPeer { _ in bundleItems(for: recipient) }
            )
            let ratchetOnly = try OMEMODoubleRatchetSession(
                asInitiatorWithSharedSecret: Array(repeating: 1, count: 32), peerSignedPreKey: recipient.signedPreKey.publicKeyBytes
            ).serialize()

            module.restoreSessions([OMEMOModule.StoredSessionEntry(
                jid: recipientJID, deviceID: 200, sessionData: ratchetOnly, associatedData: Array(repeating: 0, count: 64)
            )])
            let encrypted = try await module.encryptMessage(
                plaintext: "hi", to: recipientJID, recipientDeviceIDs: [200], ownDeviceIDs: []
            ).encrypted

            #expect(isKeyExchange(encrypted))
        }

        @Test func `A new key exchange naming a used pre-key replaces the session`() async throws {
            // The same device starting over from a bundle that still lists the pre-key it used before.
            let sender = try makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1])
            let first = try await kexEncrypted(from: sender, plaintext: "old")
            let restarted = try await kexEncrypted(from: sender, plaintext: "new")
            let module = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer())
            _ = try module.decryptIncomingMessage(first, from: .full(peerJID))
            let oldSession = try #require(module.allSessionEntries().first).sessionData

            #expect(try module.decryptIncomingMessage(restarted, from: .full(peerJID)).body == "new")
            #expect(module.allSessionEntries().map(\.sessionData) != [oldSession])
            #expect(module.allSessionEntries().count == 1)
        }

        /// The `<encrypted>` element of a key exchange from `sender`'s device, which uses the recipient's pre-key 7.
        private func kexEncrypted(from sender: TestOMEMOIdentity, plaintext: String) async throws -> XMLElement {
            let message = try await makeKEXMessage(to: recipient, plaintext: plaintext, from: sender)
            return try #require(message.child(named: "encrypted", namespace: XMPPNamespaces.omemo))
        }

        /// A session with the device holds its key even when the guard holds none, so a key exchange signed with
        /// another key cannot replace it.
        @Test(arguments: [true, false])
        func `A key exchange with another key than an existing session's is refused, and one with the session's key replaces it`(
            sessionWasSent: Bool
        ) async throws {
            let sender = try makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1])
            let impostor = try makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1])
            let restored = try await sessionEntries(with: sender, sessionWasSent: sessionWasSent)
            let trustGuard = OMEMOTrustGuard()
            let module = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer(), trustGuard: trustGuard)
            module.restoreSessions(restored)

            let forged = try await kexEncrypted(from: impostor, plaintext: "forged")
            #expect(throws: OMEMOModuleError.changedIdentityKey) {
                _ = try module.decryptIncomingMessage(forged, from: .full(peerJID))
            }
            #expect(module.allSessionEntries().map(\.sessionData) == restored.map(\.sessionData))
            #expect(module.consumedPreKeyIDs().isEmpty)
            #expect(trustGuard.heldFingerprint(peer: peerJID.bareJID, deviceID: 100).isEmpty)
            #expect(trustGuard.consumedPreKeyIDs(ownDeviceID: 200).isEmpty)

            let genuine = try await kexEncrypted(from: sender, plaintext: "genuine")
            #expect(try module.decryptIncomingMessage(genuine, from: .full(peerJID)).body == "genuine")
            #expect(module.allSessionEntries().map(\.sessionData) != restored.map(\.sessionData))
        }

        /// The sessions another module of this device holds with `sender`'s device: one `sender` started with a key
        /// exchange, or, when `sessionWasSent`, one this device started from `sender`'s bundle.
        private func sessionEntries(with sender: TestOMEMOIdentity, sessionWasSent: Bool) async throws -> [OMEMOModule.StoredSessionEntry] {
            let other = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer { _ in bundleItems(for: sender) })
            if sessionWasSent {
                _ = try await other.encryptMessage(plaintext: "hi", to: peerJID.bareJID, recipientDeviceIDs: [100], ownDeviceIDs: [])
            } else {
                _ = try await other.decryptIncomingMessage(kexEncrypted(from: sender, plaintext: "hi"), from: .full(peerJID))
            }
            return other.allSessionEntries()
        }

        /// A started session whose associated data is corrupt shows no key to compare with.
        @Test func `A key exchange cannot replace a session whose key cannot be read`() async throws {
            let sender = try makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1])
            let restored = try await sessionEntries(with: sender, sessionWasSent: true)
            let module = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer())
            module.restoreSessions(restored.map {
                OMEMOModule.StoredSessionEntry(
                    jid: $0.jid, deviceID: $0.deviceID, sessionData: $0.sessionData, associatedData: Array($0.associatedData.dropLast())
                )
            })

            let genuine = try await kexEncrypted(from: sender, plaintext: "genuine")
            #expect(throws: OMEMOModuleError.changedIdentityKey) {
                _ = try module.decryptIncomingMessage(genuine, from: .full(peerJID))
            }
        }

        @Test(arguments: [true, false])
        func `A key exchange from a device marked untrusted, or with another key than the one held, builds nothing`(isUntrusted: Bool) async throws {
            let sender = try makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1])
            let trustGuard = OMEMOTrustGuard()
            let stored = isUntrusted ? "" : unrelatedFingerprint()
            trustGuard.mergeRow(peer: peerJID.bareJID, deviceID: 100, fingerprint: stored, decision: isUntrusted ? .untrusted : .undecided)
            let module = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer(), trustGuard: trustGuard)
            let encrypted = try await kexEncrypted(from: sender, plaintext: "secret")

            #expect(throws: isUntrusted ? OMEMOModuleError.untrustedDevice : .changedIdentityKey) {
                _ = try module.decryptIncomingMessage(encrypted, from: .full(peerJID))
            }

            #expect(module.allSessionEntries().isEmpty)
            #expect(module.consumedPreKeyIDs().isEmpty)
            #expect(trustGuard.consumedPreKeyIDs(ownDeviceID: 200).isEmpty)
            #expect(trustGuard.heldFingerprint(peer: peerJID.bareJID, deviceID: 100) == stored)
        }

        @Test func `A first key exchange holds its key, so a second with another key for the device is refused`() async throws {
            let sender = try makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1])
            let impostor = try makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1])
            let trustGuard = OMEMOTrustGuard()
            let module = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer(), trustGuard: trustGuard)
            _ = try await module.decryptIncomingMessage(kexEncrypted(from: sender, plaintext: "first"), from: .full(peerJID))

            #expect(trustGuard.heldFingerprint(peer: peerJID.bareJID, deviceID: 100) == omemoFingerprint(of: sender.identityKeyPair.publicKeyBytes))
            #expect(trustGuard.consumedPreKeyIDs(ownDeviceID: 200) == [7])
            let forged = try await kexEncrypted(from: impostor, plaintext: "forged")
            #expect(throws: OMEMOModuleError.changedIdentityKey) {
                _ = try module.decryptIncomingMessage(forged, from: .full(peerJID))
            }
        }

        @Test func `A module the account's guard was never wired into still holds a device's first key`() async throws {
            let sender = try makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1])
            let impostor = try makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1])
            let module = makeInstalledOMEMOModule(identity: recipient.data, context: StubPEPPeer().context)
            _ = try await module.decryptIncomingMessage(kexEncrypted(from: sender, plaintext: "first"), from: .full(peerJID))

            let forged = try await kexEncrypted(from: impostor, plaintext: "forged")
            #expect(throws: OMEMOModuleError.changedIdentityKey) {
                _ = try module.decryptIncomingMessage(forged, from: .full(peerJID))
            }
        }

        @Test func `A repeated key exchange is not read through a session whose key contradicts the one held`() async throws {
            let messages = try await makeRepeatingKEXMessages(to: recipient, plaintexts: ["one", "two"])
            let earlier = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer())
            _ = try earlier.decryptIncomingMessage(messages[0], from: .full(peerJID))
            let restored = earlier.allSessionEntries()
            let trustGuard = OMEMOTrustGuard()
            try trustGuard.mergeRow(
                peer: peerJID.bareJID, deviceID: #require(restored.first).deviceID, fingerprint: unrelatedFingerprint(), decision: .undecided
            )
            let module = makeInstalledModule(identity: recipient.data.withPreKeys([]), peer: StubPEPPeer(), trustGuard: trustGuard)
            module.restoreSessions(restored)

            #expect(throws: OMEMOModuleError.changedIdentityKey) {
                _ = try module.decryptIncomingMessage(messages[1], from: .full(peerJID))
            }
        }

        /// The next connection loads the pre-key as unused when saving it as used failed or never ran.
        @Test func `A key exchange taken up by an earlier module is refused when replayed to a later one`() async throws {
            let trustGuard = OMEMOTrustGuard()
            let message = try await makeKEXMessage(to: recipient, plaintext: "secret")
            let encrypted = try #require(message.child(named: "encrypted", namespace: XMPPNamespaces.omemo))
            let earlier = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer(), trustGuard: trustGuard)
            _ = try earlier.decryptIncomingMessage(encrypted, from: .full(peerJID))
            let module = makeInstalledModule(identity: recipient.data, peer: StubPEPPeer(), trustGuard: trustGuard)

            #expect(throws: OMEMOModuleError.unknownPreKey) {
                _ = try module.decryptIncomingMessage(encrypted, from: .full(peerJID))
            }
            #expect(module.allSessionEntries().isEmpty)
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

        /// A correction or retraction next to the payload is outside the encryption, so it hides no failure.
        @Test(arguments: ["message", "correction", "retraction", "keyOnly"])
        func `A failed decrypt shows whenever the stanza has a payload`(kind: String) throws {
            let peer = StubPEPPeer()
            let module = makeInstalledModule(identity: recipient.data, peer: peer)
            var message = XMLElement(name: "message", attributes: ["from": "peer@example.com/i", "id": "m1"])
            var header = XMLElement(name: "header", attributes: ["sid": "1"])
            var keys = XMLElement(name: "keys", attributes: ["jid": recipientJID.description])
            var key = XMLElement(name: "key", attributes: ["rid": "200"])
            key.addText("AAAA")
            keys.addChild(key)
            header.addChild(keys)
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

            #expect(peer.undecryptableMessageIDs == (kind == "keyOnly" ? [] : ["m1"]))
        }
    }

    /// A send checks each device's session against the trust guard before encrypting for it.
    struct SendTrustTests {
        private let sender: TestOMEMOIdentity
        private let recipient: TestOMEMOIdentity

        init() throws {
            self.sender = try makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1])
            self.recipient = try makeTestOMEMOIdentity(deviceID: 200, preKeyIDs: [7])
        }

        private func send(_ plaintext: String, from module: OMEMOModule) async throws {
            _ = try await module.encryptMessage(plaintext: plaintext, to: recipientJID, recipientDeviceIDs: [200], ownDeviceIDs: [])
        }

        @Test func `A device marked untrusted after its session started gets nothing encrypted`() async throws {
            let recipient = recipient
            let trustGuard = OMEMOTrustGuard()
            let module = makeInstalledModule(identity: sender.data, peer: StubPEPPeer { _ in bundleItems(for: recipient) }, trustGuard: trustGuard)
            try await send("one", from: module)

            _ = trustGuard.applyDistrust(peer: recipientJID, deviceID: 200)

            await #expect(throws: OMEMOModuleError.untrustedDevice) { try await send("two", from: module) }
        }

        /// The session exists, so the check is the send's own, not the one a new session gets.
        @Test(arguments: [true, false])
        func `A restored session whose key is not the one held, or cannot be read, gets nothing encrypted`(isReadable: Bool) async throws {
            let recipient = recipient
            let earlier = makeInstalledModule(identity: sender.data, peer: StubPEPPeer { _ in bundleItems(for: recipient) })
            try await send("one", from: earlier)
            let trustGuard = OMEMOTrustGuard()
            if isReadable {
                trustGuard.mergeRow(peer: recipientJID, deviceID: 200, fingerprint: unrelatedFingerprint(), decision: .undecided)
            }
            let peer = StubPEPPeer()
            let module = makeInstalledModule(identity: sender.data, peer: peer, trustGuard: trustGuard)
            module.restoreSessions(earlier.allSessionEntries().map { entry in
                OMEMOModule.StoredSessionEntry(
                    jid: entry.jid, deviceID: entry.deviceID, sessionData: entry.sessionData,
                    associatedData: isReadable ? entry.associatedData : Array(entry.associatedData.dropLast())
                )
            })

            await #expect(throws: OMEMOModuleError.changedIdentityKey) { try await send("two", from: module) }
            #expect(peer.iqs.isEmpty)
        }

        /// The bundle's key is checked before its session is installed, so a refused one is never stored or reported.
        @Test(arguments: [true, false])
        func `A send to a device without a session installs nothing when the bundle's key is refused`(isUntrusted: Bool) async throws {
            let recipient = recipient
            let trustGuard = OMEMOTrustGuard()
            trustGuard.mergeRow(
                peer: recipientJID, deviceID: 200, fingerprint: isUntrusted ? "" : unrelatedFingerprint(), decision: isUntrusted ? .untrusted : .undecided
            )
            let peer = StubPEPPeer { _ in bundleItems(for: recipient) }
            let module = makeInstalledModule(identity: sender.data, peer: peer, trustGuard: trustGuard)

            await #expect(throws: isUntrusted ? OMEMOModuleError.untrustedDevice : .changedIdentityKey) { try await send("hi", from: module) }

            #expect(module.allSessionEntries().isEmpty)
            #expect(peer.sessionEstablishedPreKeyIDs.isEmpty)
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
    private let account: FullJID
    private let answer: @Sendable (XMLElement) async throws -> XMLElement?

    /// `account` is the JID the module is signed in as.
    init(account: FullJID = FullJID.parse("user@example.com/res")!, answer: @escaping @Sendable (XMLElement) async throws -> XMLElement? = { _ in nil }) {
        self.account = account
        self.answer = answer
    }

    var context: ModuleContext {
        makeStubModuleContext(
            sendIQ: { [recorded, answer] iq, _ in
                recorded.withLock { $0.iqs.append(iq.element) }
                return try await answer(iq.element)
            },
            emitEvent: { [recorded] event in recorded.withLock { $0.events.append(event) } },
            connectedJID: account
        )
    }

    var iqs: [XMLElement] {
        recorded.withLock { $0.iqs }
    }

    var bundlePublishes: [XMLElement] {
        iqs.filter { $0.xmlString.contains("<publish") && $0.xmlString.contains(XMPPNamespaces.omemoBundles) }
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
                if case let .omemoEncryptedMessageReceived(message, _) = event { message.id } else { nil }
            }
        }
    }

    var undecryptableMessageIDs: [String] {
        recorded.withLock { recorded in
            recorded.events.compactMap { event in
                if case let .omemoEncryptedMessageReceived(message, .undecryptable) = event { message.id } else { nil }
            }
        }
    }
}

/// A module with `identity` installed, as an established session installs it, talking to `peer` and checking sessions
/// against `trustGuard`.
private func makeInstalledModule(
    identity: OMEMOModule.OMEMOIdentityData, peer: StubPEPPeer, trustGuard: OMEMOTrustGuard = OMEMOTrustGuard()
) -> OMEMOModule {
    let module = makeInstalledOMEMOModule(identity: identity, context: peer.context)
    module.configureTrustGuard(trustGuard)
    return module
}

/// The `<pubsub>` answer to a bundle fetch, carrying `identity`'s bundle.
func bundleItems(for identity: TestOMEMOIdentity) -> XMLElement {
    let bundle = OMEMOPreKeyManager.buildBundle(
        deviceID: OMEMODeviceID(value: identity.data.deviceID),
        identityKeyPair: identity.identityKeyPair,
        signedPreKey: identity.signedPreKey,
        preKeys: identity.preKeys
    )
    var item = XMLElement(name: "item", attributes: ["id": "\(identity.data.deviceID)"])
    item.addChild(OMEMOModule(pepModule: PEPModule()).buildBundleElement(bundle))
    var items = XMLElement(name: "items", attributes: ["node": XMPPNamespaces.omemoBundles])
    items.addChild(item)
    var pubsub = XMLElement(name: "pubsub", namespace: XMPPNamespaces.pubsub)
    pubsub.addChild(items)
    return pubsub
}

/// `encrypted` with the required pre-key id field left out of its key exchange.
private func removingPreKeyID(from encrypted: XMLElement) throws -> XMLElement {
    try mappingKeys(in: encrypted) { key in
        guard key.attribute("kex") == "true" else { return key }
        let text = try #require(key.textContent)
        let bytes = try #require(Base64.decode(text))
        // The key exchange opens with the pre-key id: tag 0x08 and a one-byte varint for the small ids used here.
        try #require(bytes.first == 0x08 && bytes[1] < 0x80)
        var newKey = XMLElement(name: "key", attributes: key.attributes)
        newKey.addText(Base64.encode(Array(bytes.dropFirst(2))))
        return newKey
    }
}

/// The `<encrypted>` elements of messages from one sender to `recipient`, which has not answered, so each carries the
/// sender's key exchange around its own ratchet message (XEP-0384 §4.3).
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
    return encrypted
}

/// `encrypted` with its keys' `kex` attribute set to `value`.
private func marking(_ encrypted: XMLElement, kex value: String) throws -> XMLElement {
    try mappingKeys(in: encrypted) { key in
        var key = key
        key.setAttribute("kex", value: value)
        return key
    }
}

/// `encrypted` as if sent by the device `deviceID`.
private func replacingSenderDevice(with deviceID: UInt32, in encrypted: XMLElement) throws -> XMLElement {
    try mappingKeys(in: encrypted, senderDeviceID: deviceID) { $0 }
}

/// `encrypted` with each `<key>` replaced by `transform`'s result, and the sender device replaced when one is given.
private func mappingKeys(
    in encrypted: XMLElement, senderDeviceID: UInt32? = nil, _ transform: (XMLElement) throws -> XMLElement
) throws -> XMLElement {
    let header = try #require(encrypted.child(named: "header"))
    var newHeader = XMLElement(name: "header", attributes: header.attributes)
    if let senderDeviceID {
        newHeader.setAttribute("sid", value: "\(senderDeviceID)")
    }
    for keys in header.children(named: "keys") {
        var newKeys = XMLElement(name: "keys", attributes: keys.attributes)
        for key in keys.children(named: "key") {
            try newKeys.addChild(transform(key))
        }
        newHeader.addChild(newKeys)
    }
    var newEncrypted = XMLElement(name: "encrypted", namespace: XMPPNamespaces.omemo)
    newEncrypted.addChild(newHeader)
    if let payload = encrypted.child(named: "payload") {
        newEncrypted.addChild(payload)
    }
    return newEncrypted
}

/// The pre-key ids a bundle publish carries, in ascending order.
private func publishedPreKeyIDs(in publish: XMLElement) -> [String] {
    let bundle = publish.child(named: "pubsub")?.child(named: "publish")?.child(named: "item")?.child(named: "bundle")
    let preKeys = bundle?.child(named: "prekeys")?.children(named: "pk") ?? []
    return preKeys.compactMap { $0.attribute("id") }.sorted()
}

private extension OMEMOModule.OMEMOIdentityData {
    func withPreKeys(_ preKeys: [PreKeyData]) -> Self {
        Self(
            deviceID: deviceID, identityKeyRaw: identityKeyRaw, signedPreKeyID: signedPreKeyID,
            signedPreKeyRaw: signedPreKeyRaw, signedPreKeySignature: signedPreKeySignature, preKeys: preKeys
        )
    }
}
