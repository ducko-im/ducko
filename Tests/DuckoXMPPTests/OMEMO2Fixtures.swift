import Foundation
import Testing

/// Golden OMEMO 2 fixtures that `Fixtures/omemo2_fixtures.py` generates with the reference implementation.
/// The JSON carries bytes as base64, which `JSONDecoder` decodes into `Data`.
enum OMEMO2Fixtures {
    /// A device's key material, in the form Ducko stores it.
    struct Device: Decodable {
        struct IdentityKey: Decodable {
            /// The 32-byte Ed25519 seed `OMEMOIdentityKeyPair(rawRepresentation:)` takes.
            let seed: Data
            let publicKey: Data
            /// The X25519 public key that matches the identity key's agreement scalar.
            let agreementPublicKey: Data
        }

        struct SignedPreKey: Decodable {
            let id: UInt32
            let privateKey: Data
            let publicKey: Data
            let signature: Data
        }

        struct PreKey: Decodable {
            let id: UInt32
            let privateKey: Data
            let publicKey: Data
        }

        let jid: String
        let deviceID: UInt32
        let identityKey: IdentityKey
        let signedPreKey: SignedPreKey
        let preKeys: [PreKey]
        /// The `<devices>` element listing only this device.
        let deviceList: String
        let bundle: String
    }

    /// The messages alice and bob exchange, and each send and receive with the values the reference computed.
    struct Conversation: Decodable {
        /// The X3DH associated data: alice's identity key followed by bob's.
        let associatedData: Data
        let messages: [Message]
        let events: [Event]
    }

    struct Message: Decodable {
        struct KeyExchange: Decodable {
            let pkID: UInt32
            let spkID: UInt32
            let ik: Data
            let ek: Data
            let bytes: Data
        }

        struct AuthenticatedMessage: Decodable {
            let mac: Data
            let bytes: Data
        }

        /// The reference's `OMEMOMessage`.
        struct RatchetMessage: Decodable {
            let n: UInt32
            let pn: UInt32
            let dhPub: Data
            let ciphertext: Data
            let bytes: Data
        }

        let sender: String
        /// The SCE envelope, or nil for an empty message.
        let plaintext: String?
        /// The `<encrypted>` element.
        let encrypted: String
        let keyExchange: KeyExchange?
        let authenticatedMessage: AuthenticatedMessage
        let message: RatchetMessage
        /// The base64 `<payload>` text, or nil for an empty message.
        let payload: String?
    }

    /// One party sending or receiving a message.
    struct Event: Decodable {
        struct X3DH: Decodable {
            let sharedSecret: Data
        }

        struct RootChainStep: Decodable {
            let rootKey: Data
            let dhOutput: Data
            let nextRootKey: Data
            let chainKey: Data
        }

        struct MessageChainStep: Decodable {
            let chainKey: Data
            let nextChainKey: Data
            let messageKey: Data
        }

        struct MessageKeyMaterial: Decodable {
            let messageKey: Data
            let encryptionKey: Data
            let authenticationKey: Data
            let iv: Data
        }

        struct PayloadKeyMaterial: Decodable {
            let key: Data
            let encryptionKey: Data
            let authenticationKey: Data
            let iv: Data
            /// The truncated MAC over the payload ciphertext.
            let hmac: Data
        }

        let party: String
        /// `send` or `receive`.
        let action: String
        /// The index into `Conversation.messages`.
        let message: Int
        let x3dh: X3DH?
        let rootChainSteps: [RootChainStep]
        let messageChainSteps: [MessageChainStep]
        let messageKeyMaterial: MessageKeyMaterial
        /// Nil for an empty message.
        let payloadKeyMaterial: PayloadKeyMaterial?
        /// The party's ratchet once the event is done.
        let ratchet: Ratchet
    }

    /// The reference's Double Ratchet state.
    struct Ratchet: Decodable {
        struct Chain: Decodable {
            let key: Data
            let length: UInt32
        }

        struct SkippedMessageKey: Decodable {
            let ratchetPublicKey: Data
            let index: UInt32
            let messageKey: Data
        }

        let ownPrivateKey: Data
        let otherPublicKey: Data?
        let rootKey: Data
        let sendingChain: Chain?
        let receivingChain: Chain?
        let previousSendingChainLength: UInt32?
        let skippedMessageKeys: [SkippedMessageKey]
    }

    static func device(_ name: String) throws -> Device {
        try load(name)
    }

    static func conversation() throws -> Conversation {
        try load("conversation")
    }

    private static func load<Fixture: Decodable>(_ name: String) throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/OMEMO2"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}
