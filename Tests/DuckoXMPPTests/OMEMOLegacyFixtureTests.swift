import Foundation
import Testing
@testable import DuckoXMPP

/// Ducko's identity and pre-keys checked against the legacy OMEMO reference implementation.
enum OMEMOLegacyFixtureTests {
    struct DeviceKeys {
        @Test(arguments: ["alice", "bob"])
        func `an identity seed gives the reference identity key in both forms`(device name: String) throws {
            let identityKey = try OMEMOLegacyFixtures.device(name).identityKey

            let identity = try OMEMOIdentityKeyPair(rawRepresentation: Array(identityKey.seed))
            let agreementKey = try Array(identity.agreementPrivateKey().publicKey.rawRepresentation)

            #expect(identity.publicKeyBytes == Array(identityKey.publicKey))
            #expect(agreementKey == Array(identityKey.agreementPublicKey))
            #expect([0x05] + agreementKey == Array(identityKey.serializedPublicKey))
            #expect(identity.publicKeyBytes[31] >> 7 == identityKey.signBit)
        }

        @Test(arguments: ["alice", "bob"])
        func `the published signature's top bit rebuilds the Edwards identity key from the bundle's`(device name: String) throws {
            let device = try OMEMOLegacyFixtures.device(name)
            let publishedSignature = Array(device.signedPreKey.publishedSignature)

            let rebuilt = OMEMOCurveConversion.x25519ToEd25519(
                Array(device.identityKey.serializedPublicKey.dropFirst()), signBit: publishedSignature[63] >> 7
            )

            #expect(rebuilt == Array(device.identityKey.publicKey))
            #expect(publishedSignature[..<63] == Array(device.signedPreKey.signature)[..<63])
        }

        @Test(arguments: ["alice", "bob"])
        func `pre-key private keys give the reference public keys`(device name: String) throws {
            let device = try OMEMOLegacyFixtures.device(name)

            let signedPreKey = try device.restoredSignedPreKey()
            let preKeys = try device.restoredPreKeys()

            #expect(signedPreKey.publicKeyBytes == Array(device.signedPreKey.publicKey))
            #expect(preKeys.map(\.publicKeyBytes) == device.preKeys.map { Array($0.publicKey) })
        }
    }

    struct KeyAgreement {
        @Test func `bob's responder X3DH reproduces the reference root key and 66-byte associated data`() throws {
            let bob = try OMEMOLegacyFixtures.device("bob")
            let conversation = try OMEMOLegacyFixtures.conversation()
            let event = try #require(conversation.events.first { $0.party == "bob" && $0.x3dh != nil })
            let keyExchange = try #require(conversation.messages[event.message].keyExchange)
            let preKey = try #require(bob.preKeys.first { $0.id == keyExchange.pkID })
            #expect(keyExchange.spkID == bob.signedPreKey.id)
            #expect(keyExchange.ik.first == 0x05 && keyExchange.ek.first == 0x05)

            let result = try OMEMOX3DH.responderKeyAgreement(
                identityKeyPair: bob.restoredIdentityKey(),
                signedPreKey: OMEMOSignedPreKey(
                    keyID: bob.signedPreKey.id,
                    rawRepresentation: Array(bob.signedPreKey.privateKey),
                    signature: Array(bob.signedPreKey.publishedSignature)
                ),
                oneTimePreKey: OMEMOPreKey(keyID: preKey.id, rawRepresentation: Array(preKey.privateKey)),
                peerIdentityKey: Array(keyExchange.ik.dropFirst()),
                peerEphemeralKey: Array(keyExchange.ek.dropFirst()),
                format: .legacy
            )

            #expect(Data(result.sharedSecret) == event.x3dh?.sharedSecret)
            #expect(conversation.associatedData.count == 66)
            #expect(Data(result.associatedData) == conversation.associatedData)
        }

        @Test func `alice agrees with bob on a key through his reference bundle`() throws {
            let alice = try OMEMOLegacyFixtures.device("alice")
            let bob = try OMEMOLegacyFixtures.device("bob")
            let aliceIdentity = try alice.restoredIdentityKey()
            let preKey = try #require(bob.preKeys.first)

            let initiator = try OMEMOX3DH.initiatorKeyAgreement(
                identityKeyPair: aliceIdentity,
                peerBundle: OMEMOX3DHPeerBundle(
                    identityKey: Array(bob.identityKey.agreementPublicKey),
                    signedPreKey: Array(bob.signedPreKey.publicKey),
                    signedPreKeySignature: Array(bob.signedPreKey.publishedSignature),
                    oneTimePreKey: Array(preKey.publicKey)
                ),
                format: .legacy
            )
            let responder = try OMEMOX3DH.responderKeyAgreement(
                identityKeyPair: bob.restoredIdentityKey(),
                signedPreKey: OMEMOSignedPreKey(
                    keyID: bob.signedPreKey.id,
                    rawRepresentation: Array(bob.signedPreKey.privateKey),
                    signature: Array(bob.signedPreKey.publishedSignature)
                ),
                oneTimePreKey: OMEMOPreKey(keyID: preKey.id, rawRepresentation: Array(preKey.privateKey)),
                peerIdentityKey: Array(alice.identityKey.agreementPublicKey),
                peerEphemeralKey: initiator.ephemeralPublicKey,
                format: .legacy
            )

            #expect(initiator.sharedSecret == responder.sharedSecret)
            #expect(try Data(initiator.associatedData) == OMEMOLegacyFixtures.conversation().associatedData)
        }
    }

    struct KeyDerivation {
        @Test func `every root chain step matches the reference`() throws {
            let steps = try OMEMOLegacyFixtures.conversation().events.flatMap(\.rootChainSteps)
            try #require(!steps.isEmpty)

            for step in steps {
                let result = OMEMOCrypto.kdfRK(
                    rootKey: Array(step.rootKey), dhOutput: Array(step.dhOutput), info: OMEMOWireFormat.legacy.rootChainInfo
                )

                #expect(result.rootKey == Array(step.nextRootKey))
                #expect(result.chainKey == Array(step.chainKey))
            }
        }

        @Test func `every message key expands to the reference's keys`() throws {
            for event in try OMEMOLegacyFixtures.conversation().events {
                let material = event.messageKeyMaterial

                let keys = OMEMOMessageCrypto.deriveKeys(from: Array(material.messageKey), for: .legacyMessageKey)

                #expect(keys.encryptionKey == Array(material.encryptionKey))
                #expect(keys.authenticationKey == Array(material.authenticationKey))
                #expect(keys.iv == Array(material.iv))
            }
        }
    }
}
