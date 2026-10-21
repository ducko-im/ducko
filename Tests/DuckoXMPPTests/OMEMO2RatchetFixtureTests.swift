import CryptoKit
import Foundation
import Testing
@testable import DuckoXMPP

/// Ducko's key derivations, MACs and ratchet against the messages the reference implementation produced.
extension OMEMO2FixtureTests {
    struct KeyDerivation {
        @Test func `every root chain step matches the reference`() throws {
            let steps = try OMEMO2Fixtures.conversation().events.flatMap(\.rootChainSteps)
            try #require(!steps.isEmpty)

            for step in steps {
                let result = OMEMOCrypto.kdfRK(rootKey: Array(step.rootKey), dhOutput: Array(step.dhOutput))

                #expect(result.rootKey == Array(step.nextRootKey))
                #expect(result.chainKey == Array(step.chainKey))
            }
        }

        @Test func `every message key and payload key expands to the reference's keys`() throws {
            for event in try OMEMO2Fixtures.conversation().events {
                let material = event.messageKeyMaterial
                let messageKeys = OMEMOMessageCrypto.deriveKeys(from: Array(material.messageKey), for: .messageKey)

                #expect(messageKeys.encryptionKey == Array(material.encryptionKey))
                #expect(messageKeys.authenticationKey == Array(material.authenticationKey))
                #expect(messageKeys.iv == Array(material.iv))

                guard let payload = event.payloadKeyMaterial else { continue }
                let payloadKeys = OMEMOMessageCrypto.deriveKeys(from: Array(payload.key), for: .payloadKey)

                #expect(payloadKeys.encryptionKey == Array(payload.encryptionKey))
                #expect(payloadKeys.authenticationKey == Array(payload.authenticationKey))
                #expect(payloadKeys.iv == Array(payload.iv))
            }
        }
    }

    /// From the reference's ratchet after each send, rewound to the chain key and message number the send started from,
    /// Ducko encrypts the same bytes.
    struct Sending {
        @Test func `every payload encrypts to the reference's payload and key material`() throws {
            let conversation = try OMEMO2Fixtures.conversation()

            for event in conversation.events where event.action == "send" {
                let message = conversation.messages[event.message]
                guard let material = event.payloadKeyMaterial else { continue }
                let plaintext = try #require(message.plaintext)

                let payload = try OMEMOPayload(encrypting: Array(plaintext.utf8), key: Array(material.key))

                #expect(try Base64.encode(payload.ciphertext) == #require(message.payload))
                #expect(payload.keyMaterial == Array(material.key + material.hmac))
            }
        }

        @Test func `every ratchet message and key exchange encrypts to the reference's bytes`() throws {
            let conversation = try OMEMO2Fixtures.conversation()

            for event in conversation.events where event.action == "send" {
                let message = conversation.messages[event.message]
                let step = try #require(event.messageChainSteps.first)
                var ratchet = try OMEMODoubleRatchetSession(reference: event.ratchet)
                ratchet.sendChainKey = Array(step.chainKey)
                ratchet.sendMessageNumber = message.message.n
                // An empty message carries an all-zero key and no MAC.
                let keyMaterial = event.payloadKeyMaterial.map { $0.key + $0.hmac } ?? Data(count: OMEMOPayload.keyLength)

                let encrypted = try ratchet.encrypt(plaintext: Array(keyMaterial), associatedData: Array(conversation.associatedData))

                #expect(encrypted.serialized == Array(message.authenticatedMessage.bytes))
                if let keyExchange = message.keyExchange {
                    let header = OMEMOKeyExchangeHeader(
                        preKeyID: keyExchange.pkID, signedPreKeyID: keyExchange.spkID,
                        identityKey: Array(keyExchange.ik), ephemeralKey: Array(keyExchange.ek)
                    )
                    #expect(OMEMOKeyExchange(header, message: encrypted).serialized == Array(keyExchange.bytes))
                }
            }
        }
    }

    /// Ducko reads the reference's messages in the order the reference received them.
    struct Receiving {
        @Test func `every payload decrypts with the reference's key material`() throws {
            let conversation = try OMEMO2Fixtures.conversation()

            for event in conversation.events where event.action == "receive" {
                let message = conversation.messages[event.message]
                guard let material = event.payloadKeyMaterial else { continue }
                let payloadText = try #require(message.payload)
                let ciphertext = try #require(Base64.decode(payloadText))

                let decrypted = try OMEMOPayload(ciphertext: ciphertext, keyMaterial: Array(material.key + material.hmac)).decrypt()

                #expect(try decrypted == Array(#require(message.plaintext).utf8))
            }
        }

        @Test func `bob decrypts every message alice sent him`() throws {
            let alice = try OMEMO2Fixtures.device("alice")
            let bob = try OMEMO2Fixtures.device("bob")
            let conversation = try OMEMO2Fixtures.conversation()
            let module = makeInstalledOMEMOModule(
                identity: bob.identityData, context: makeStubModuleContext(connectedJID: FullJID.parse("\(bob.jid)/desktop"))
            )
            let sender = try #require(FullJID.parse("\(alice.jid)/phone"))
            var bobsLastState: OMEMO2Fixtures.Ratchet?

            for event in conversation.events where event.party == "bob" {
                defer { bobsLastState = event.ratchet }
                guard event.action == "receive" else { continue }
                let message = conversation.messages[event.message]
                // A ratchet step uses bob's own ratchet key, which the reference drew at random at its previous step, so
                // bob's session first takes the reference's last state.
                let dhPub = Array(message.message.dhPub)
                if let bobsLastState, let session = try storedSession(in: module, with: alice), session.ratchet.dhRecvPublicKey != dhPub,
                   session.ratchet.skippedMessageKeys[SkippedKeyID(publicKey: dhPub, messageNumber: message.message.n)] == nil {
                    try restore(OMEMODoubleRatchetSession(reference: bobsLastState), into: module, keeping: session, with: alice)
                }

                let result = try module.decryptIncomingMessage(stanza(message.encrypted), from: .full(sender))

                #expect(try result.body == expectedBody(of: message))
                let session = try storedSession(in: module, with: alice)
                let ratchet = try #require(session).ratchet
                expectReceivingHalf(of: ratchet, matches: event.ratchet)
            }
            #expect(conversation.events.contains { $0.party == "bob" && $0.action == "receive" })
        }

        private func storedSession(in module: OMEMOModule, with peer: OMEMO2Fixtures.Device) throws -> OMEMOSession? {
            let jid = try #require(BareJID.parse(peer.jid))
            return try module.exportSession(jid: jid, deviceID: peer.deviceID).map {
                try OMEMOSession(serialized: $0.sessionData, associatedData: $0.associatedData)
            }
        }

        private func restore(
            _ ratchet: OMEMODoubleRatchetSession, into module: OMEMOModule, keeping session: OMEMOSession, with peer: OMEMO2Fixtures.Device
        ) throws {
            let replaced = OMEMOSession(ratchet: ratchet, associatedData: session.associatedData, start: session.start)
            try module.restoreSessions([OMEMOModule.StoredSessionEntry(
                jid: #require(BareJID.parse(peer.jid)), deviceID: peer.deviceID,
                sessionData: replaced.serialized, associatedData: replaced.associatedData
            )])
        }

        /// The `<body>` text of the message's envelope, read by Foundation's parser.
        private func expectedBody(of message: OMEMO2Fixtures.Message) throws -> String {
            let envelope = try XMLDocument(xmlString: #require(message.plaintext))
            return try #require(envelope.nodes(forXPath: "//*[local-name()='body']").first?.stringValue)
        }

        /// Bob's own ratchet key is a random pick and his root key derives from it, so only the receiving half compares.
        private func expectReceivingHalf(of ratchet: OMEMODoubleRatchetSession, matches reference: OMEMO2Fixtures.Ratchet) {
            #expect(ratchet.dhRecvPublicKey == reference.otherPublicKey.map(Array.init))
            #expect(ratchet.recvChainKey == reference.receivingChain.map { Array($0.key) })
            #expect(ratchet.recvMessageNumber == reference.receivingChain?.length ?? 0)
            #expect(ratchet.skippedMessageKeys == Dictionary(uniqueKeysWithValues: reference.skippedMessageKeys.map {
                (SkippedKeyID(publicKey: Array($0.ratchetPublicKey), messageNumber: $0.index), Array($0.messageKey))
            }))
        }
    }
}

extension OMEMODoubleRatchetSession {
    /// A session in the reference's state.
    init(reference: OMEMO2Fixtures.Ratchet) throws {
        try self.init(
            asResponderWithSharedSecret: Array(reference.rootKey),
            ourSignedPreKeyPair: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: reference.ownPrivateKey)
        )
        dhRecvPublicKey = reference.otherPublicKey.map(Array.init)
        sendChainKey = reference.sendingChain.map { Array($0.key) }
        sendMessageNumber = reference.sendingChain?.length ?? 0
        recvChainKey = reference.receivingChain.map { Array($0.key) }
        recvMessageNumber = reference.receivingChain?.length ?? 0
        previousSendCount = reference.previousSendingChainLength ?? 0
        for skipped in reference.skippedMessageKeys {
            let keyID = SkippedKeyID(publicKey: Array(skipped.ratchetPublicKey), messageNumber: skipped.index)
            skippedMessageKeys[keyID] = Array(skipped.messageKey)
            skippedKeyOrder.append(keyID)
        }
    }
}
