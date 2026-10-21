import Foundation
import Testing
@testable import DuckoXMPP

/// Ducko's OMEMO 2 crypto and elements checked against the reference implementation.
enum OMEMO2FixtureTests {
    struct DeviceKeys {
        @Test(arguments: ["alice", "bob"])
        func `an identity seed gives the reference identity and agreement keys`(device name: String) throws {
            let identityKey = try OMEMO2Fixtures.device(name).identityKey

            let identity = try OMEMOIdentityKeyPair(rawRepresentation: Array(identityKey.seed))
            let agreementKey = try identity.agreementPrivateKey()

            #expect(identity.publicKeyBytes == Array(identityKey.publicKey))
            #expect(Array(agreementKey.publicKey.rawRepresentation) == Array(identityKey.agreementPublicKey))
            #expect(OMEMOCurveConversion.ed25519ToX25519(identity.publicKeyBytes) == Array(identityKey.agreementPublicKey))
        }

        @Test(arguments: ["alice", "bob"])
        func `pre-key private keys give the reference public keys and the signature verifies`(device name: String) throws {
            let device = try OMEMO2Fixtures.device(name)

            let signedPreKey = try device.restoredSignedPreKey()
            let preKeys = try device.restoredPreKeys()

            #expect(signedPreKey.publicKeyBytes == Array(device.signedPreKey.publicKey))
            #expect(try OMEMOX3DH.verifySignedPreKey(
                signedPreKeyPublic: signedPreKey.publicKeyBytes,
                signature: signedPreKey.signature,
                identityKey: Array(device.identityKey.publicKey)
            ))
            #expect(preKeys.map(\.publicKeyBytes) == device.preKeys.map { Array($0.publicKey) })
        }
    }

    struct KeyAgreement {
        @Test func `bob's responder X3DH reproduces the reference shared secret and associated data`() throws {
            let bob = try OMEMO2Fixtures.device("bob")
            let conversation = try OMEMO2Fixtures.conversation()
            let event = try #require(conversation.events.first { $0.party == "bob" && $0.x3dh != nil })
            let keyExchange = try #require(conversation.messages[event.message].keyExchange)
            let preKey = try #require(bob.preKeys.first { $0.id == keyExchange.pkID })
            #expect(keyExchange.spkID == bob.signedPreKey.id)

            let result = try OMEMOX3DH.responderKeyAgreement(
                identityKeyPair: OMEMOIdentityKeyPair(rawRepresentation: Array(bob.identityKey.seed)),
                signedPreKey: OMEMOSignedPreKey(
                    keyID: bob.signedPreKey.id,
                    rawRepresentation: Array(bob.signedPreKey.privateKey),
                    signature: Array(bob.signedPreKey.signature)
                ),
                oneTimePreKey: OMEMOPreKey(keyID: preKey.id, rawRepresentation: Array(preKey.privateKey)),
                peerIdentityKey: Array(keyExchange.ik),
                peerEphemeralKey: Array(keyExchange.ek)
            )

            #expect(Data(result.sharedSecret) == event.x3dh?.sharedSecret)
            #expect(Data(result.associatedData) == conversation.associatedData)
        }
    }

    struct Protobufs {
        @Test func `every OMEMOMessage decodes and re-encodes byte for byte`() throws {
            for fixture in try OMEMO2Fixtures.conversation().messages.map(\.message) {
                let decoded = try OMEMOMessage(serialized: Array(fixture.bytes))
                let encoded = OMEMOMessage(
                    messageNumber: decoded.messageNumber,
                    previousChainCount: decoded.previousChainCount,
                    dhPublicKey: decoded.dhPublicKey,
                    ciphertext: decoded.ciphertext
                )

                #expect(decoded.messageNumber == fixture.n)
                #expect(decoded.previousChainCount == fixture.pn)
                #expect(decoded.dhPublicKey == Array(fixture.dhPub))
                #expect(decoded.ciphertext == Array(fixture.ciphertext))
                #expect(encoded.serialized == Array(fixture.bytes))
            }
        }

        @Test func `every OMEMOAuthenticatedMessage decodes and re-encodes byte for byte`() throws {
            for fixture in try OMEMO2Fixtures.conversation().messages {
                let decoded = try OMEMOAuthenticatedMessage(serialized: Array(fixture.authenticatedMessage.bytes))
                let encoded = try OMEMOAuthenticatedMessage(
                    mac: decoded.mac,
                    message: OMEMOMessage(serialized: Array(fixture.message.bytes))
                )

                #expect(decoded.mac == Array(fixture.authenticatedMessage.mac))
                #expect(decoded.message.serialized == Array(fixture.message.bytes))
                #expect(encoded.serialized == Array(fixture.authenticatedMessage.bytes))
            }
        }

        @Test func `every OMEMOKeyExchange decodes and re-encodes byte for byte`() throws {
            let messages = try OMEMO2Fixtures.conversation().messages
            let keyExchanges = messages.filter { $0.keyExchange != nil }
            try #require(!keyExchanges.isEmpty)

            for fixture in keyExchanges {
                let keyExchange = try #require(fixture.keyExchange)
                let decoded = try OMEMOKeyExchange(serialized: Array(keyExchange.bytes))
                let encoded = try OMEMOKeyExchange(
                    preKeyID: decoded.preKeyID,
                    signedPreKeyID: decoded.signedPreKeyID,
                    identityKey: decoded.identityKey,
                    ephemeralKey: decoded.ephemeralKey,
                    message: OMEMOAuthenticatedMessage(serialized: Array(fixture.authenticatedMessage.bytes))
                )

                #expect(decoded.preKeyID == keyExchange.pkID)
                #expect(decoded.signedPreKeyID == keyExchange.spkID)
                #expect(decoded.identityKey == Array(keyExchange.ik))
                #expect(decoded.ephemeralKey == Array(keyExchange.ek))
                #expect(decoded.message.serialized == Array(fixture.authenticatedMessage.bytes))
                #expect(encoded.serialized == Array(keyExchange.bytes))
            }
        }
    }

    struct MessageChain {
        @Test func `every message chain step matches the reference`() throws {
            let steps = try OMEMO2Fixtures.conversation().events.flatMap(\.messageChainSteps)
            try #require(!steps.isEmpty)

            for step in steps {
                let result = OMEMOCrypto.kdfCK(chainKey: Array(step.chainKey))

                #expect(result.chainKey == Array(step.nextChainKey))
                #expect(result.messageKey == Array(step.messageKey))
            }
        }
    }
}
