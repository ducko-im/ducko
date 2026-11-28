import Foundation
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

/// Writes Ducko's legacy bundle and the legacy messages it encrypts to the fixture device bob into
/// `DUCKO_OMEMO_LEGACY_VERIFY_DIR`, for `Fixtures/oldmemo_fixtures.py verify` to check with the reference
/// implementation. It writes one subdirectory for an identity whose Edwards key has sign bit 0 and one for sign bit 1, so
/// the bundle signature carries the bit both ways. bob never answers, so every message repeats the key exchange.
struct OMEMOLegacyVerifyTests {
    private static let directory = ProcessInfo.processInfo.environment["DUCKO_OMEMO_LEGACY_VERIFY_DIR"]

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
            /// The body Ducko encrypted, nil for a key-transport element.
            let plaintext: String?
            let encrypted: String

            /// Spelled out so a key transport's plaintext is written as null, which the script reads.
            func encode(to encoder: any Encoder) throws {
                var container = encoder.container(keyedBy: ConversationMessageKey.self)
                try container.encode(plaintext, forKey: .plaintext)
                try container.encode(encrypted, forKey: .encrypted)
            }
        }

        // periphery:ignore
        let messages: [Message]
    }

    @Test(.enabled(if: directory != nil, "Set DUCKO_OMEMO_LEGACY_VERIFY_DIR to the directory to write to"), arguments: [UInt8(0), 1])
    func `writes a legacy bundle and messages to bob for the reference to decrypt`(signBit: UInt8) async throws {
        let directory = try URL(fileURLWithPath: #require(Self.directory), isDirectory: true).appendingPathComponent("sign-bit-\(signBit)")
        let bob = try OMEMOLegacyFixtures.device("bob")
        let bobJID = try #require(BareJID.parse(bob.jid))
        let ownJID = try #require(FullJID.parse("ducko@example.org/verify"))
        let identity = try #require(try Self.identity(withSignBit: signBit))
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
            answeringFetchesWith: bob, sent: sent
        )
        let bundle = try module.buildLegacyBundleElement(OMEMOPreKeyManager.buildLegacyBundle(
            deviceID: OMEMODeviceID(value: deviceID), identityKeyPair: identity, signedPreKey: signedPreKey, preKeys: preKeys
        ))
        let reader = try ReferenceBob()
        var messages: [ConversationFile.Message] = []

        let bodies: [String?] = [
            "Hello from Ducko!", "Fish & chips <tonight>?",
            "A longer message that spans several AES blocks, so its payload is more than one block of ciphertext.", nil,
            "After the key transport."
        ]
        for body in bodies {
            let encrypted: DuckoXMPP.XMLElement
            if let body {
                encrypted = try await module.encryptMessage(
                    content: [bodyElement(body)], legacyBody: body, time: testEnvelopeTime, to: bobJID, ownDeviceIDs: []
                ).legacy
            } else {
                try await module.sendEmptyMessageAwaiting(to: SessionKey(jid: bobJID, deviceID: bob.deviceID, version: .legacy))
                encrypted = try #require(sent.withLock { $0.last }?.child(named: "encrypted", namespace: XMPPNamespaces.omemoLegacy))
            }
            let keys = encrypted.child(named: "header")?.children(named: "key") ?? []
            #expect(keys.map { $0.attribute("rid") } == ["\(bob.deviceID)"])
            #expect(keys.first?.attribute("prekey") == "true")
            #expect(try reader.read(encrypted, from: ownJID) == body)
            messages.append(.init(plaintext: body, encrypted: encrypted.xmlString))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(DeviceFile(jid: ownJID.bareJID.description, deviceID: deviceID, bundle: bundle.xmlString))
            .write(to: directory.appendingPathComponent("device.json"))
        try encoder.encode(ConversationFile(messages: messages)).write(to: directory.appendingPathComponent("conversation.json"))
    }

    /// The first identity, from seeds of one repeated byte, whose Ed25519 public key has `signBit` as the top bit of its
    /// last byte.
    private static func identity(withSignBit signBit: UInt8) throws -> OMEMOIdentityKeyPair? {
        for byte in UInt8(0) ... 255 {
            let identity = try OMEMOIdentityKeyPair(rawRepresentation: Array(repeating: byte, count: 32))
            if identity.publicKeyBytes[31] >> 7 == signBit { return identity }
        }
        return nil
    }

    /// A module installed as `jid`, which finds `peer` on the peer's legacy device list alone and fetches `peer`'s
    /// fixture legacy bundle, and whose stanzas go to `sent`.
    private func makeInstalledModule(
        as jid: FullJID, data: OMEMOModule.OMEMOIdentityData, answeringFetchesWith peer: OMEMOLegacyFixtures.Device,
        sent: OSAllocatedUnfairLock<[DuckoXMPP.XMLElement]>
    ) throws -> OMEMOModule {
        let bundleNode = XMPPNamespaces.omemoLegacyBundles(deviceID: peer.deviceID)
        var item = DuckoXMPP.XMLElement(name: "item", attributes: ["id": "current"])
        try item.addChild(stanza(peer.bundle))
        var items = DuckoXMPP.XMLElement(name: "items", attributes: ["node": bundleNode])
        items.addChild(item)
        var bundleItems = DuckoXMPP.XMLElement(name: "pubsub", namespace: XMPPNamespaces.pubsub)
        bundleItems.addChild(items)
        let context = makeStubModuleContext(
            sendStanza: { stanza, onAccepted in
                sent.withLock { $0.append(stanza.element) }
                onAccepted?()
            },
            sendIQ: { [bundleItems] iq, _ in
                if let list = deviceListItems([peer.deviceID], answering: iq.element, in: .legacy) { return list }
                return iq.element.child(named: "pubsub")?.child(named: "items")?.attribute("node") == bundleNode ? bundleItems : nil
            },
            connectedJID: jid
        )
        return makeInstalledOMEMOModule(identity: data, context: context)
    }
}

private enum ConversationMessageKey: String, CodingKey {
    case plaintext, encrypted
}
