import CryptoKit
import Testing
@testable import DuckoXMPP

enum OMEMOSerializationTests {
    // MARK: - Double Ratchet Session

    struct SessionSerializationTests {
        @Test func `initiator session round trip`() throws {
            let sharedSecret = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            let peerKey = Curve25519.KeyAgreement.PrivateKey()
            let peerPublicBytes = Array(peerKey.publicKey.rawRepresentation)

            let session = try OMEMODoubleRatchetSession(
                asInitiatorWithSharedSecret: sharedSecret,
                peerSignedPreKey: peerPublicBytes
            )

            let serialized = session.serialize()
            let restored = try OMEMODoubleRatchetSession(serialized: serialized)

            #expect(Array(restored.dhSendKeyPair.rawRepresentation) == Array(session.dhSendKeyPair.rawRepresentation))
            #expect(restored.dhSendPublicKeyBytes == session.dhSendPublicKeyBytes)
            #expect(restored.dhRecvPublicKey == session.dhRecvPublicKey)
            #expect(restored.rootKey == session.rootKey)
            #expect(restored.sendChainKey == session.sendChainKey)
            #expect(restored.recvChainKey == session.recvChainKey)
            #expect(restored.sendMessageNumber == session.sendMessageNumber)
            #expect(restored.recvMessageNumber == session.recvMessageNumber)
            #expect(restored.previousSendCount == session.previousSendCount)
        }

        @Test func `dh send public key cache matches derived key`() throws {
            let sharedSecret = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            let peerKey = Curve25519.KeyAgreement.PrivateKey()

            let session = try OMEMODoubleRatchetSession(
                asInitiatorWithSharedSecret: sharedSecret,
                peerSignedPreKey: Array(peerKey.publicKey.rawRepresentation)
            )

            let derived = Array(session.dhSendKeyPair.publicKey.rawRepresentation)
            #expect(session.dhSendPublicKeyBytes == derived)
        }

        @Test func `responder session round trip`() throws {
            let sharedSecret = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            let ourKeyPair = Curve25519.KeyAgreement.PrivateKey()

            let session = OMEMODoubleRatchetSession(
                asResponderWithSharedSecret: sharedSecret,
                ourSignedPreKeyPair: ourKeyPair
            )

            let serialized = session.serialize()
            let restored = try OMEMODoubleRatchetSession(serialized: serialized)

            #expect(Array(restored.dhSendKeyPair.rawRepresentation) == Array(session.dhSendKeyPair.rawRepresentation))
            #expect(restored.dhSendPublicKeyBytes == session.dhSendPublicKeyBytes)
            #expect(restored.dhRecvPublicKey == nil)
            #expect(restored.rootKey == session.rootKey)
            #expect(restored.sendChainKey == nil)
            #expect(restored.recvChainKey == nil)
        }

        @Test func `session after encryption round trip`() throws {
            let sharedSecret = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            let peerKey = Curve25519.KeyAgreement.PrivateKey()
            let peerPublicBytes = Array(peerKey.publicKey.rawRepresentation)
            let ad = (0 ..< 64).map { _ in UInt8.random(in: 0 ... 255) }

            var session = try OMEMODoubleRatchetSession(
                asInitiatorWithSharedSecret: sharedSecret,
                peerSignedPreKey: peerPublicBytes
            )

            // Encrypt a few messages to advance the ratchet
            _ = try session.encrypt(plaintext: Array("Hello".utf8), associatedData: ad)
            _ = try session.encrypt(plaintext: Array("World".utf8), associatedData: ad)

            let serialized = session.serialize()
            let restored = try OMEMODoubleRatchetSession(serialized: serialized)

            #expect(restored.sendMessageNumber == 2)
            #expect(restored.sendChainKey == session.sendChainKey)
            #expect(restored.rootKey == session.rootKey)

            // Verify restored session can continue encrypting
            var mutable = restored
            let msg = try mutable.encrypt(plaintext: Array("Test".utf8), associatedData: ad)
            #expect(msg.message.messageNumber == 2)
        }

        @Test func `session with skipped keys round trip`() throws {
            let sharedSecret = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            let bobKeyPair = Curve25519.KeyAgreement.PrivateKey()
            let ad = (0 ..< 64).map { _ in UInt8.random(in: 0 ... 255) }

            // Alice initiates
            var alice = try OMEMODoubleRatchetSession(
                asInitiatorWithSharedSecret: sharedSecret,
                peerSignedPreKey: Array(bobKeyPair.publicKey.rawRepresentation)
            )

            // Bob responds
            var bob = OMEMODoubleRatchetSession(
                asResponderWithSharedSecret: sharedSecret,
                ourSignedPreKeyPair: bobKeyPair
            )

            // Alice sends 3 messages
            let msg0 = try alice.encrypt(plaintext: Array("msg0".utf8), associatedData: ad)
            _ = try alice.encrypt(plaintext: Array("msg1".utf8), associatedData: ad)
            let msg2 = try alice.encrypt(plaintext: Array("msg2".utf8), associatedData: ad)

            // Bob receives msg2 first (skipping msg1)
            _ = try bob.decrypt(message: msg2, associatedData: ad)
            // Bob receives msg0 (using skipped key from before ratchet)
            _ = try bob.decrypt(message: msg0, associatedData: ad)

            // Bob should have msg1's key stored as skipped
            let skippedCount = bob.skippedMessageKeys.count
            #expect(skippedCount == 1)

            // Serialize and restore
            let serialized = bob.serialize()
            let restored = try OMEMODoubleRatchetSession(serialized: serialized)

            #expect(restored.skippedMessageKeys.count == skippedCount)
            #expect(restored.skippedKeyOrder.count == skippedCount)
        }
    }

    // MARK: - OMEMO Session

    struct OMEMOSessionSerializationTests {
        /// Until the device answers, the session wraps each message in its key exchange.
        @Test func `a started session reads back unconfirmed until a message from the device confirms it`() throws {
            let associatedData = Array(repeating: UInt8(0x5A), count: 64)
            let bobKeyPair = Curve25519.KeyAgreement.PrivateKey()
            let keyExchange = OMEMOKeyExchangeHeader(
                preKeyID: 7, signedPreKeyID: 1, identityKey: Array(repeating: 0xAB, count: 32), ephemeralKey: Array(repeating: 0xEE, count: 32)
            )
            var bob = OMEMODoubleRatchetSession(asResponderWithSharedSecret: Array(repeating: 1, count: 32), ourSignedPreKeyPair: bobKeyPair)
            let started = try OMEMOSession(
                ratchet: OMEMODoubleRatchetSession(
                    asInitiatorWithSharedSecret: Array(repeating: 1, count: 32), peerSignedPreKey: Array(bobKeyPair.publicKey.rawRepresentation)
                ),
                associatedData: associatedData,
                start: .sent(keyExchange, isConfirmed: false)
            )

            var alice = try OMEMOSession(serialized: started.serialized, associatedData: associatedData)
            let first = try alice.encryptKey([1])
            _ = try bob.decrypt(message: OMEMOKeyExchange(serialized: first.data).message, associatedData: associatedData)
            _ = try alice.decrypt(bob.encrypt(plaintext: [2], associatedData: associatedData))
            var confirmed = try OMEMOSession(serialized: alice.serialized, associatedData: associatedData)

            #expect(first.isKex)
            #expect(confirmed.start == .sent(keyExchange, isConfirmed: true))
            #expect(try !confirmed.encryptKey([3]).isKex)
        }
    }

    // MARK: - Skipped Key ID

    struct SkippedKeyIDTests {
        @Test func `public init and hash`() {
            let key = SkippedKeyID(publicKey: [1, 2, 3], messageNumber: 42)
            #expect(key.publicKey == [1, 2, 3])
            #expect(key.messageNumber == 42)

            let same = SkippedKeyID(publicKey: [1, 2, 3], messageNumber: 42)
            #expect(key == same)

            let different = SkippedKeyID(publicKey: [1, 2, 3], messageNumber: 43)
            #expect(key != different)
        }
    }
}
