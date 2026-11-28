import Foundation
import Testing
@testable import DuckoXMPP

/// Golden legacy OMEMO fixtures that `Fixtures/oldmemo_fixtures.py` generates with the reference implementation.
/// The JSON carries bytes as base64, which `JSONDecoder` decodes into `Data`. The parts shaped as in the OMEMO 2
/// fixtures reuse their types.
enum OMEMOLegacyFixtures {
    /// A device's key material, in the form Ducko stores it.
    struct Device: Decodable {
        struct IdentityKey: Decodable {
            /// The 32-byte Ed25519 seed `OMEMOIdentityKeyPair(rawRepresentation:)` takes.
            let seed: Data
            /// The Ed25519 public key.
            let publicKey: Data
            /// The X25519 public key that matches the identity key's agreement scalar.
            let agreementPublicKey: Data
            /// The identity key as the bundle and key exchanges carry it: `0x05` followed by `agreementPublicKey`.
            let serializedPublicKey: Data
            /// The top bit of `publicKey`'s last byte. alice's is 1 and bob's is 0.
            let signBit: UInt8
        }

        struct SignedPreKey: Decodable {
            let id: UInt32
            let privateKey: Data
            /// The raw X25519 public key, without the `0x05` prefix.
            let publicKey: Data
            /// The Ed25519 signature over `0x05` followed by `publicKey`.
            let signature: Data
            /// `signature` with the identity key's sign bit in the top bit of its last byte, as the bundle carries it.
            let publishedSignature: Data
        }

        let jid: String
        let deviceID: UInt32
        let identityKey: IdentityKey
        let signedPreKey: SignedPreKey
        /// Raw X25519 keys, without the `0x05` prefix.
        let preKeys: [OMEMO2Fixtures.Device.PreKey]
        /// The `<list>` element listing only this device.
        let deviceList: String
        let bundle: String
    }

    /// The messages alice and bob exchange, and each send and receive with the values the reference computed.
    struct Conversation: Decodable {
        /// The session's associated data: alice's serialized identity key followed by bob's.
        let associatedData: Data
        let messages: [Message]
        let events: [Event]
    }

    struct Message: Decodable {
        let sender: String
        /// The exact text encrypted, or nil for a key-transport element.
        let plaintext: String?
        /// `plaintext` without the leading and trailing spaces and tabs it was padded with.
        let body: String?
        /// The `<encrypted>` element.
        let encrypted: String
        /// The associated data this message's MAC covers: the sender's serialized identity key followed by the
        /// recipient's.
        let associatedData: Data
        /// The key the ratchet encrypts: the 16-byte AES-GCM key followed by the 16-byte tag, or a lone 16-byte key
        /// for a key-transport element.
        let keyMaterial: Data
        /// Its `ik` and `ek` carry the `0x05` prefix, and `bytes` the leading version byte.
        let keyExchange: OMEMO2Fixtures.Message.KeyExchange?
        /// `bytes` is `message.bytes` followed by the 8-byte `mac`.
        let authenticatedMessage: OMEMO2Fixtures.Message.AuthenticatedMessage
        /// `dhPub` carries the `0x05` prefix, and `bytes` the leading version byte.
        let message: OMEMO2Fixtures.Message.RatchetMessage
        /// The `<iv>`: 12 bytes, or 16 for one message.
        let iv: Data
        /// The base64 `<payload>` text, or nil for a key-transport element.
        let payload: String?
    }

    /// One party sending or receiving a message.
    struct Event: Decodable {
        struct X3DH: Decodable {
            let sharedSecret: Data
            /// The initiator's ephemeral key, present on the sending side only.
            let ephemeralPrivateKey: Data?
        }

        let party: String
        /// `send` or `receive`.
        let action: String
        /// The index into `Conversation.messages`.
        let message: Int
        let x3dh: X3DH?
        let rootChainSteps: [OMEMO2Fixtures.Event.RootChainStep]
        let messageChainSteps: [OMEMO2Fixtures.Event.MessageChainStep]
        let messageKeyMaterial: OMEMO2Fixtures.Event.MessageKeyMaterial
        /// The party's ratchet once the event is done.
        let ratchet: OMEMO2Fixtures.Ratchet
    }

    /// The skipped keys a legacy ratchet holds once it has read `message` from the state `previous`: the reference's
    /// `ratchet`'s, and the key of message `pn` on the receiving chain the message ratchets past. The reference writes
    /// `pn` as the previous chain's length, while libsignal writes the index of its last message, so the legacy ratchet
    /// skips one key further than the reference.
    static func skippedKeys(
        of ratchet: OMEMO2Fixtures.Ratchet, reading message: OMEMO2Fixtures.Message.RatchetMessage, from previous: OMEMO2Fixtures.Ratchet?
    ) -> [SkippedKeyID: [UInt8]] {
        var keys = Dictionary(uniqueKeysWithValues: ratchet.skippedMessageKeys.map {
            (SkippedKeyID(publicKey: Array($0.ratchetPublicKey), messageNumber: $0.index), Array($0.messageKey))
        })
        guard let previous, let chain = previous.receivingChain, let previousKey = previous.otherPublicKey,
              Array(previousKey) != Array(message.dhPub.dropFirst()), message.pn >= chain.length else { return keys }
        var chainKey = Array(chain.key)
        for _ in chain.length ..< message.pn {
            chainKey = OMEMOCrypto.kdfCK(chainKey: chainKey).chainKey
        }
        keys[SkippedKeyID(publicKey: Array(previousKey), messageNumber: message.pn)] = OMEMOCrypto.kdfCK(chainKey: chainKey).messageKey
        return keys
    }

    static func device(_ name: String) throws -> Device {
        try load(name)
    }

    static func conversation() throws -> Conversation {
        try load("conversation")
    }

    private static func load<Fixture: Decodable>(_ name: String) throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/OMEMOLegacy"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}

extension OMEMOLegacyFixtures.Device {
    /// The device's keys, as Ducko stores them.
    var identityData: OMEMOModule.OMEMOIdentityData {
        OMEMOModule.OMEMOIdentityData(
            deviceID: deviceID,
            identityKeyRaw: Array(identityKey.seed),
            signedPreKeyID: signedPreKey.id,
            signedPreKeyRaw: Array(signedPreKey.privateKey),
            signedPreKeySignature: Array(signedPreKey.signature),
            preKeys: preKeys.map { .init(keyID: $0.id, keyRaw: Array($0.privateKey)) }
        )
    }

    func restoredIdentityKey() throws -> OMEMOIdentityKeyPair {
        try OMEMOIdentityKeyPair(rawRepresentation: Array(identityKey.seed))
    }

    func restoredSignedPreKey() throws -> OMEMOSignedPreKey {
        try OMEMOSignedPreKey(
            keyID: signedPreKey.id, rawRepresentation: Array(signedPreKey.privateKey), signature: Array(signedPreKey.signature)
        )
    }

    func restoredPreKeys() throws -> [OMEMOPreKey] {
        try preKeys.map { try OMEMOPreKey(keyID: $0.id, rawRepresentation: Array($0.privateKey)) }
    }
}

/// bob of the reference fixtures, with the fixture's keys, reading legacy messages as his module reads them.
struct ReferenceBob {
    let conversation: OMEMOLegacyFixtures.Conversation
    let recorder: OMEMOMessageRecorder
    let module: OMEMOModule

    init() throws {
        let bob = try OMEMOLegacyFixtures.device("bob")
        self.conversation = try OMEMOLegacyFixtures.conversation()
        self.recorder = try OMEMOMessageRecorder(account: #require(FullJID.parse("\(bob.jid)/desktop")))
        self.module = recorder.installedModule(identity: bob.identityData)
    }

    /// alice's reference message `index` in a chat stanza to bob.
    func message(_ index: Int) throws -> XMPPMessage {
        try message(stanza(conversation.messages[index].encrypted))
    }

    func message(_ encrypted: DuckoXMPP.XMLElement) -> XMPPMessage {
        var message = DuckoXMPP.XMLElement(name: "message", attributes: [
            "from": "alice@example.org/phone", "to": "bob@example.org/desktop", "type": "chat", "id": "r1"
        ])
        message.addChild(encrypted)
        return XMPPMessage(element: message)
    }

    /// The body `encrypted` carries, nil for a key-transport element.
    func read(_ encrypted: DuckoXMPP.XMLElement, from sender: FullJID) throws -> String? {
        try module.decryptIncomingLegacyMessage(encrypted, from: .full(sender)).body
    }
}
