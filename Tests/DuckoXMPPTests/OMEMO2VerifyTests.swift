import Foundation
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

/// Writes Ducko's bundle and messages it encrypts to the fixture device bob into `DUCKO_OMEMO2_VERIFY_DIR`, for
/// `Fixtures/omemo2_fixtures.py verify` to check with the reference implementation. A session reset in between sends bob
/// an empty key exchange, which the messages after it follow.
struct OMEMO2VerifyTests {
    private static let directory = ProcessInfo.processInfo.environment["DUCKO_OMEMO2_VERIFY_DIR"]

    private struct DeviceFile: Encodable {
        // periphery:ignore
        let jid: String
        // periphery:ignore
        let deviceID: UInt32
        // periphery:ignore
        let bundle: String
    }

    private struct ConversationFile: Encodable {
        struct Message: Encodable {
            /// The SCE envelope Ducko encrypted, nil for an empty OMEMO message.
            let plaintext: String?
            let encrypted: String

            /// Spelled out so an empty message's plaintext is written as null, which the script reads.
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: ConversationMessageKey.self)
                try container.encode(plaintext, forKey: .plaintext)
                try container.encode(encrypted, forKey: .encrypted)
            }
        }

        // periphery:ignore
        let messages: [Message]
    }

    @Test(.enabled(if: directory != nil, "Set DUCKO_OMEMO2_VERIFY_DIR to the directory to write to"))
    func `writes a bundle and messages to bob for the reference to decrypt`() async throws {
        let directory = try URL(fileURLWithPath: #require(Self.directory), isDirectory: true)
        let bob = try OMEMO2Fixtures.device("bob")
        let bobJID = try #require(BareJID.parse(bob.jid))
        let ownJID = try #require(FullJID.parse("ducko@example.org/verify"))
        let identity = try OMEMOIdentityKeyPair(rawRepresentation: Array(repeating: 0x2A, count: 32))
        // A signed pre-key id past 2^31 - 1, which the reference must still read.
        let signedPreKey = try OMEMOPreKeyManager.generateSignedPreKey(keyID: 4_000_000_000, identityKey: identity)
        let preKeys = [OMEMOPreKey(keyID: 1), OMEMOPreKey(keyID: 2)]
        let deviceID: UInt32 = 16_180_339
        let sent = OSAllocatedUnfairLock<[DuckoXMPP.XMLElement]>(initialState: [])
        let module = try makeInstalledModule(
            as: ownJID, data: OMEMOModule.OMEMOIdentityData(
                deviceID: deviceID, identityKeyRaw: identity.rawRepresentation,
                signedPreKeyID: signedPreKey.keyID, signedPreKeyRaw: signedPreKey.rawRepresentation,
                signedPreKeySignature: signedPreKey.signature,
                preKeys: preKeys.map { .init(keyID: $0.keyID, keyRaw: $0.rawRepresentation) }
            ),
            answeringBundleFetchesWith: bob, sent: sent
        )
        let bundle = module.buildBundleElement(OMEMOPreKeyManager.buildBundle(
            deviceID: OMEMODeviceID(value: deviceID), identityKeyPair: identity, signedPreKey: signedPreKey, preKeys: preKeys
        ))
        var bobsSession: OMEMOSession?
        var messages: [ConversationFile.Message] = []

        for body in ["Hello from Ducko!", "Fish & chips <tonight>?", "Third time's the charm.", nil, "After the reset."] {
            guard let body else {
                #expect(try await module.resetSession(jid: bobJID, deviceID: bob.deviceID, versions: [.omemo2]).outcomes == [.omemo2: .rebuilt])
                let encrypted = try #require(sent.withLock { $0.last }?.child(named: "encrypted", namespace: XMPPNamespaces.omemo))
                #expect(try decryptEnvelope(of: encrypted, as: bob, session: &bobsSession) == nil)
                messages.append(.init(plaintext: nil, encrypted: encrypted.xmlString))
                continue
            }
            let encrypted = try await module.encryptMessage(
                plaintext: body, to: bobJID, recipientDeviceIDs: [bob.deviceID], ownDeviceIDs: []
            ).omemo2
            let envelope = try #require(decryptEnvelope(of: encrypted, as: bob, session: &bobsSession))
            let parsed = try SCEEnvelope(parsing: Array(envelope.utf8))
            #expect(parsed.content.map(\.xmlString) == ["<body>" + XMLElement.escape(body) + "</body>"])
            #expect(parsed.to == bobJID)
            #expect(parsed.from == ownJID.bareJID)
            messages.append(.init(plaintext: envelope, encrypted: encrypted.xmlString))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(DeviceFile(jid: ownJID.bareJID.description, deviceID: deviceID, bundle: bundle.xmlString))
            .write(to: directory.appendingPathComponent("device.json"))
        try encoder.encode(ConversationFile(messages: messages)).write(to: directory.appendingPathComponent("conversation.json"))
    }

    /// A module installed as `jid`, whose bundle fetches return `peer`'s fixture bundle and whose stanzas go to `sent`.
    private func makeInstalledModule(
        as jid: FullJID, data: OMEMOModule.OMEMOIdentityData, answeringBundleFetchesWith peer: OMEMO2Fixtures.Device,
        sent: OSAllocatedUnfairLock<[DuckoXMPP.XMLElement]>
    ) throws -> OMEMOModule {
        var item = DuckoXMPP.XMLElement(name: "item", attributes: ["id": "\(peer.deviceID)"])
        try item.addChild(stanza(peer.bundle))
        var items = DuckoXMPP.XMLElement(name: "items", attributes: ["node": XMPPNamespaces.omemoBundles])
        items.addChild(item)
        var pubsub = DuckoXMPP.XMLElement(name: "pubsub", namespace: XMPPNamespaces.pubsub)
        pubsub.addChild(items)
        let context = makeStubModuleContext(
            sendStanza: { stanza, onAccepted in
                sent.withLock { $0.append(stanza.element) }
                onAccepted?()
            },
            sendIQ: { [pubsub] _, _ in pubsub }, connectedJID: jid
        )
        return makeInstalledOMEMOModule(identity: data, context: context)
    }

    /// The envelope in `encrypted`, read with bob's fixture keys, so the reference has to decrypt to the same text. Nil
    /// for an empty message. A key exchange other than the one that started `session` builds a new session, as the
    /// reference does.
    private func decryptEnvelope(
        of encrypted: DuckoXMPP.XMLElement, as bob: OMEMO2Fixtures.Device, session: inout OMEMOSession?
    ) throws -> String? {
        let key = try #require(encrypted.child(named: "header")?.child(named: "keys")?.child(named: "key"))
        #expect(key.attribute("kex") == "true")
        let keyExchange = try OMEMOKeyExchange(serialized: #require(key.textContent.flatMap(Base64.decode)))
        var current: OMEMOSession
        if let session, session.isStarted(by: keyExchange.header) {
            current = session
        } else {
            let preKey = try #require(bob.restoredPreKeys().first { $0.keyID == keyExchange.preKeyID })
            let signedPreKey = try bob.restoredSignedPreKey()
            let agreement = try OMEMOX3DH.responderKeyAgreement(
                identityKeyPair: bob.restoredIdentityKey(),
                signedPreKey: signedPreKey,
                oneTimePreKey: preKey,
                peerIdentityKey: keyExchange.identityKey,
                peerEphemeralKey: keyExchange.ephemeralKey,
                format: .omemo2
            )
            current = OMEMOSession(
                ratchet: OMEMODoubleRatchetSession(
                    asResponderWithSharedSecret: agreement.sharedSecret, ourSignedPreKeyPair: signedPreKey.keyPair,
                    format: .omemo2
                ),
                associatedData: agreement.associatedData,
                start: .received(keyExchange.header)
            )
        }
        let keyMaterial = try current.decrypt(.omemo2(keyExchange.message))
        session = current
        guard let payloadText = encrypted.child(named: "payload")?.textContent else { return nil }
        let payload = try #require(Base64.decode(payloadText))
        return try String(decoding: OMEMOPayload(ciphertext: payload, keyMaterial: keyMaterial).decrypt(), as: UTF8.self)
    }
}

private enum ConversationMessageKey: String, CodingKey {
    case plaintext, encrypted
}
