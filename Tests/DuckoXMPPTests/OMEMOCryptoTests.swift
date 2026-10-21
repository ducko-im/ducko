import CryptoKit
import Testing
@testable import DuckoXMPP

enum OMEMOCryptoTests {
    // MARK: - Curve Conversion

    struct CurveConversionTests {
        @Test func `ed25519 to x25519 round trip via key agreement`() throws {
            // Generate an Ed25519 key pair
            let signingKey = Curve25519.Signing.PrivateKey()
            let edPublicBytes = Array(signingKey.publicKey.rawRepresentation)

            // Convert Ed25519 public → X25519 public via birational map
            let x25519Bytes = try #require(OMEMOCurveConversion.ed25519ToX25519(edPublicBytes))
            #expect(x25519Bytes.count == 32)

            // Derive X25519 private key from Ed25519 scalar: SHA512(seed)[0..31]
            // (Ed25519 stores a seed; the actual scalar is hash-derived)
            let hash = SHA512.hash(data: signingKey.rawRepresentation)
            let scalar = Array(hash.prefix(32))
            let agreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar)
            let expectedX25519 = Array(agreementKey.publicKey.rawRepresentation)
            #expect(x25519Bytes == expectedX25519)
        }

        @Test func `ed25519 to x25519 multiple keys`() throws {
            // Verify conversion works for multiple random keys
            for _ in 0 ..< 10 {
                let signingKey = Curve25519.Signing.PrivateKey()
                let edPublicBytes = Array(signingKey.publicKey.rawRepresentation)
                let x25519Bytes = try #require(OMEMOCurveConversion.ed25519ToX25519(edPublicBytes))

                let hash = SHA512.hash(data: signingKey.rawRepresentation)
                let scalar = Array(hash.prefix(32))
                let agreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar)
                let expected = Array(agreementKey.publicKey.rawRepresentation)
                #expect(x25519Bytes == expected)
            }
        }

        @Test func `ed25519 base point to x25519 base point`() throws {
            // Ed25519 base point y-coordinate: 4/5 mod p
            // Encoded in LE bytes:
            let edBasePoint: [UInt8] = [
                0x58, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
                0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
                0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
                0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66
            ]
            // X25519 base point: u = 9
            var expectedX25519 = [UInt8](repeating: 0, count: 32)
            expectedX25519[0] = 9

            let result = try #require(OMEMOCurveConversion.ed25519ToX25519(edBasePoint))
            #expect(result == expectedX25519)
        }

        @Test func `zero Y gives one`() throws {
            // y = 0: u = (1+0)/(1-0) = 1
            let zeroY = [UInt8](repeating: 0, count: 32)
            var expectedU = [UInt8](repeating: 0, count: 32)
            expectedU[0] = 1

            let result = try #require(OMEMOCurveConversion.ed25519ToX25519(zeroY))
            #expect(result == expectedU)
        }

        @Test func `invalid input returns nil`() {
            // Wrong length
            #expect(OMEMOCurveConversion.ed25519ToX25519([1, 2, 3]) == nil)
            #expect(OMEMOCurveConversion.x25519ToEd25519([1, 2, 3]) == nil)

            // Empty
            #expect(OMEMOCurveConversion.ed25519ToX25519([]) == nil)
        }

        @Test func `x25519 to ed25519 produces valid key`() throws {
            let agreementKey = Curve25519.KeyAgreement.PrivateKey()
            let x25519Bytes = Array(agreementKey.publicKey.rawRepresentation)

            let edBytes = try #require(OMEMOCurveConversion.x25519ToEd25519(x25519Bytes))
            #expect(edBytes.count == 32)
        }
    }

    // MARK: - AES-CBC

    struct AESCBCTests {
        @Test func `encrypt decrypt round trip`() throws {
            let plaintext = Array("Hello, OMEMO!".utf8)
            let key = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            let iv = (0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) }

            let ciphertext = try OMEMOAESCBC.encrypt(plaintext: plaintext, key: key, iv: iv)
            let decrypted = try OMEMOAESCBC.decrypt(ciphertext: ciphertext, key: key, iv: iv)

            #expect(decrypted == plaintext)
        }

        @Test func `ciphertext differs from plaintext`() throws {
            let plaintext = Array("Secret message".utf8)
            let key = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            let iv = (0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) }

            let ciphertext = try OMEMOAESCBC.encrypt(plaintext: plaintext, key: key, iv: iv)
            #expect(ciphertext != plaintext)
        }

        @Test func `wrong key fails decrypt`() throws {
            let plaintext = Array("Hello".utf8)
            let key1 = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            let key2 = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            let iv = (0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) }

            let ciphertext = try OMEMOAESCBC.encrypt(plaintext: plaintext, key: key1, iv: iv)

            // Decryption with wrong key should either throw or produce different output
            do {
                let decrypted = try OMEMOAESCBC.decrypt(ciphertext: ciphertext, key: key2, iv: iv)
                #expect(decrypted != plaintext)
            } catch {
                // Expected — wrong key causes padding error
            }
        }

        @Test func `invalid key length throws`() {
            let plaintext = Array("test".utf8)
            let shortKey = [UInt8](repeating: 0, count: 16)
            let iv = [UInt8](repeating: 0, count: 16)

            #expect(throws: OMEMOCryptoError.self) {
                try OMEMOAESCBC.encrypt(plaintext: plaintext, key: shortKey, iv: iv)
            }
        }

        @Test func `invalid IV length throws`() {
            let plaintext = Array("test".utf8)
            let key = [UInt8](repeating: 0, count: 32)
            let shortIV = [UInt8](repeating: 0, count: 8)

            #expect(throws: OMEMOCryptoError.self) {
                try OMEMOAESCBC.encrypt(plaintext: plaintext, key: key, iv: shortIV)
            }
        }

        @Test func `empty plaintext round trip`() throws {
            let key = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            let iv = (0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) }

            let ciphertext = try OMEMOAESCBC.encrypt(plaintext: [], key: key, iv: iv)
            let decrypted = try OMEMOAESCBC.decrypt(ciphertext: ciphertext, key: key, iv: iv)

            #expect(decrypted == [])
        }
    }

    // MARK: - Crypto Primitives

    struct CryptoPrimitivesTests {
        @Test func `kdf RK produces correct lengths`() {
            let rootKey = [UInt8](repeating: 0xAA, count: 32)
            let dhOutput = [UInt8](repeating: 0xBB, count: 32)

            let result = OMEMOCrypto.kdfRK(rootKey: rootKey, dhOutput: dhOutput)

            #expect(result.rootKey.count == 32)
            #expect(result.chainKey.count == 32)
            #expect(result.rootKey != result.chainKey)
        }

        @Test func `kdf CK produces correct lengths`() {
            let chainKey = [UInt8](repeating: 0xCC, count: 32)

            let result = OMEMOCrypto.kdfCK(chainKey: chainKey)

            #expect(result.messageKey.count == 32)
            #expect(result.chainKey.count == 32)
            #expect(result.messageKey != result.chainKey)
        }

        @Test func `kdf CK is deterministic`() {
            let chainKey = (0 ..< 32).map { UInt8($0) }

            let result1 = OMEMOCrypto.kdfCK(chainKey: chainKey)
            let result2 = OMEMOCrypto.kdfCK(chainKey: chainKey)

            #expect(result1.messageKey == result2.messageKey)
            #expect(result1.chainKey == result2.chainKey)
        }

        @Test func `hmac sha256 is deterministic`() {
            let key = Array("key".utf8)
            let data = Array("data".utf8)

            let mac1 = OMEMOCrypto.hmacSHA256(key: key, data: data)
            let mac2 = OMEMOCrypto.hmacSHA256(key: key, data: data)

            #expect(mac1.count == 32)
            #expect(mac1 == mac2)
        }

        @Test func `hmac sha256 multi segment matches single buffer`() {
            let key = Array("hmac-key".utf8)
            let part1 = Array("hello ".utf8)
            let part2 = Array("world".utf8)

            let singleBuffer = OMEMOCrypto.hmacSHA256(key: key, data: part1 + part2)
            let multiSegment = OMEMOCrypto.hmacSHA256(key: key, dataSegments: [part1, part2])

            #expect(singleBuffer == multiSegment)
        }

        @Test func `hkdf sha256 produces requested length`() {
            let ikm = Array("input key material".utf8)
            let salt = Array("salt".utf8)
            let info = Array("info".utf8)

            let output32 = OMEMOCrypto.hkdfSHA256(
                inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: 32
            )
            let output64 = OMEMOCrypto.hkdfSHA256(
                inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: 64
            )

            #expect(output32.count == 32)
            #expect(output64.count == 64)
        }

        @Test func `dh key agreement`() throws {
            let aliceKey = Curve25519.KeyAgreement.PrivateKey()
            let bobKey = Curve25519.KeyAgreement.PrivateKey()

            let shared1 = try OMEMOCrypto.dh(privateKey: aliceKey, publicKey: bobKey.publicKey)
            let shared2 = try OMEMOCrypto.dh(privateKey: bobKey, publicKey: aliceKey.publicKey)

            #expect(shared1.count == 32)
            #expect(shared1 == shared2)
        }
    }

    // MARK: - Message Crypto

    struct MessageCryptoTests {
        private let messageKey = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
        private let ad = (0 ..< 64).map { _ in UInt8.random(in: 0 ... 255) }

        private func encrypt(_ plaintext: [UInt8], associatedData: [UInt8]? = nil) throws -> OMEMOAuthenticatedMessage {
            try OMEMOMessageCrypto.encrypt(plaintext: plaintext, messageKey: messageKey, associatedData: associatedData ?? ad) {
                OMEMOMessage(messageNumber: 3, previousChainCount: 1, dhPublicKey: Array(repeating: 0x42, count: 32), ciphertext: $0)
            }
        }

        @Test func encryptDecryptRoundTrip() throws {
            let plaintext = Array("Hello, OMEMO encryption!".utf8)

            let encrypted = try encrypt(plaintext)
            let decrypted = try OMEMOMessageCrypto.decrypt(encrypted, messageKey: messageKey, associatedData: ad)

            #expect(decrypted == plaintext)
        }

        @Test func `hmac is truncated to 16 bytes`() throws {
            let encrypted = try encrypt(Array("test".utf8))

            #expect(encrypted.mac.count == 16)
        }

        @Test(arguments: [true, false])
        func `hmac verification fails when the ciphertext or the header changes`(changesCiphertext: Bool) throws {
            let encrypted = try encrypt(Array("test".utf8))
            let message = encrypted.message
            var ciphertext = message.ciphertext
            if changesCiphertext {
                ciphertext[0] ^= 0xFF
            }
            let tampered = OMEMOAuthenticatedMessage(mac: encrypted.mac, message: OMEMOMessage(
                messageNumber: changesCiphertext ? message.messageNumber : message.messageNumber + 1,
                previousChainCount: message.previousChainCount, dhPublicKey: message.dhPublicKey, ciphertext: ciphertext
            ))

            #expect(throws: OMEMOCryptoError.self) {
                try OMEMOMessageCrypto.decrypt(tampered, messageKey: messageKey, associatedData: ad)
            }
        }

        @Test func `different AD fails decrypt`() throws {
            let otherAD = (0 ..< 64).map { _ in UInt8.random(in: 0 ... 255) }

            let encrypted = try encrypt(Array("test".utf8), associatedData: otherAD)

            #expect(throws: OMEMOCryptoError.self) {
                try OMEMOMessageCrypto.decrypt(encrypted, messageKey: messageKey, associatedData: ad)
            }
        }

        @Test func `a payload decrypts with its key material and not with a changed MAC`() throws {
            let plaintext = Array("Hello, OMEMO!".utf8)
            let key = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }

            let payload = try OMEMOPayload(encrypting: plaintext, key: key)
            var keyMaterial = payload.keyMaterial
            keyMaterial[keyMaterial.count - 1] ^= 0xFF

            #expect(payload.keyMaterial.count == 48)
            #expect(Array(payload.keyMaterial.prefix(32)) == key)
            #expect(try payload.decrypt() == plaintext)
            #expect(throws: OMEMOCryptoError.self) {
                try OMEMOPayload(ciphertext: payload.ciphertext, keyMaterial: keyMaterial).decrypt()
            }
        }
    }

    // MARK: - X3DH Protocol

    struct X3DHTests {
        @Test func `handshake with one time pre key`() throws {
            let alice = OMEMOIdentityKeyPair()
            let bob = OMEMOIdentityKeyPair()
            let bobSPK = try OMEMOSignedPreKey(keyID: 1, identityKey: bob)
            let bobOPK = OMEMOPreKey(keyID: 1)

            let peerBundle = OMEMOX3DHPeerBundle(
                identityKey: bob.publicKeyBytes,
                signedPreKey: bobSPK.publicKeyBytes,
                signedPreKeySignature: bobSPK.signature,
                oneTimePreKey: bobOPK.publicKeyBytes
            )

            let aliceResult = try OMEMOX3DH.initiatorKeyAgreement(
                identityKeyPair: alice, peerBundle: peerBundle
            )

            let bobResult = try OMEMOX3DH.responderKeyAgreement(
                identityKeyPair: bob,
                signedPreKey: bobSPK,
                oneTimePreKey: bobOPK,
                peerIdentityKey: alice.publicKeyBytes,
                peerEphemeralKey: aliceResult.ephemeralPublicKey
            )

            #expect(aliceResult.sharedSecret == bobResult.sharedSecret)
            #expect(aliceResult.associatedData == bobResult.associatedData)
            #expect(aliceResult.sharedSecret.count == 32)
            #expect(aliceResult.associatedData.count == 64)
        }

        @Test func `handshake without one time pre key`() throws {
            let alice = OMEMOIdentityKeyPair()
            let bob = OMEMOIdentityKeyPair()
            let bobSPK = try OMEMOSignedPreKey(keyID: 1, identityKey: bob)

            let peerBundle = OMEMOX3DHPeerBundle(
                identityKey: bob.publicKeyBytes,
                signedPreKey: bobSPK.publicKeyBytes,
                signedPreKeySignature: bobSPK.signature,
                oneTimePreKey: nil
            )

            let aliceResult = try OMEMOX3DH.initiatorKeyAgreement(
                identityKeyPair: alice, peerBundle: peerBundle
            )

            let bobResult = try OMEMOX3DH.responderKeyAgreement(
                identityKeyPair: bob,
                signedPreKey: bobSPK,
                oneTimePreKey: nil,
                peerIdentityKey: alice.publicKeyBytes,
                peerEphemeralKey: aliceResult.ephemeralPublicKey
            )

            #expect(aliceResult.sharedSecret == bobResult.sharedSecret)
            #expect(aliceResult.associatedData == bobResult.associatedData)
        }

        @Test func `invalid signature rejected`() throws {
            let alice = OMEMOIdentityKeyPair()
            let bob = OMEMOIdentityKeyPair()
            let bobSPK = try OMEMOSignedPreKey(keyID: 1, identityKey: bob)

            // Use a bogus signature
            let badSignature = [UInt8](repeating: 0, count: 64)
            let peerBundle = OMEMOX3DHPeerBundle(
                identityKey: bob.publicKeyBytes,
                signedPreKey: bobSPK.publicKeyBytes,
                signedPreKeySignature: badSignature,
                oneTimePreKey: nil
            )

            #expect(throws: OMEMOCryptoError.self) {
                try OMEMOX3DH.initiatorKeyAgreement(
                    identityKeyPair: alice, peerBundle: peerBundle
                )
            }
        }

        @Test func `signed pre key verification`() throws {
            let identity = OMEMOIdentityKeyPair()
            let spk = try OMEMOSignedPreKey(keyID: 1, identityKey: identity)

            let valid = try OMEMOX3DH.verifySignedPreKey(
                signedPreKeyPublic: spk.publicKeyBytes,
                signature: spk.signature,
                identityKey: identity.publicKeyBytes
            )
            #expect(valid)

            // Tamper with the signature
            var badSig = spk.signature
            badSig[0] ^= 0xFF
            let invalid = try OMEMOX3DH.verifySignedPreKey(
                signedPreKeyPublic: spk.publicKeyBytes,
                signature: badSig,
                identityKey: identity.publicKeyBytes
            )
            #expect(!invalid)
        }
    }

    // MARK: - Double Ratchet

    struct DoubleRatchetTests {
        /// Creates an Alice-Bob session pair from a fresh X3DH handshake.
        private static func createSessionPair() throws -> SessionPair {
            let alice = OMEMOIdentityKeyPair()
            let bob = OMEMOIdentityKeyPair()
            let bobSPK = try OMEMOSignedPreKey(keyID: 1, identityKey: bob)
            let bobOPK = OMEMOPreKey(keyID: 1)

            let peerBundle = OMEMOX3DHPeerBundle(
                identityKey: bob.publicKeyBytes,
                signedPreKey: bobSPK.publicKeyBytes,
                signedPreKeySignature: bobSPK.signature,
                oneTimePreKey: bobOPK.publicKeyBytes
            )

            let aliceX3DH = try OMEMOX3DH.initiatorKeyAgreement(
                identityKeyPair: alice, peerBundle: peerBundle
            )
            let bobX3DH = try OMEMOX3DH.responderKeyAgreement(
                identityKeyPair: bob,
                signedPreKey: bobSPK,
                oneTimePreKey: bobOPK,
                peerIdentityKey: alice.publicKeyBytes,
                peerEphemeralKey: aliceX3DH.ephemeralPublicKey
            )

            var aliceSession = try OMEMODoubleRatchetSession(
                asInitiatorWithSharedSecret: aliceX3DH.sharedSecret,
                peerSignedPreKey: bobSPK.publicKeyBytes
            )
            var bobSession = OMEMODoubleRatchetSession(
                asResponderWithSharedSecret: bobX3DH.sharedSecret,
                ourSignedPreKeyPair: bobSPK.keyPair
            )

            return SessionPair(
                aliceSession: aliceSession,
                bobSession: bobSession,
                ad: aliceX3DH.associatedData
            )
        }

        private struct SessionPair {
            var aliceSession: OMEMODoubleRatchetSession
            var bobSession: OMEMODoubleRatchetSession
            let ad: [UInt8]
        }

        @Test func `single message alice to bob`() throws {
            var pair = try Self.createSessionPair()
            let plaintext = Array("Hello Bob!".utf8)

            let encrypted = try pair.aliceSession.encrypt(plaintext: plaintext, associatedData: pair.ad)
            let decrypted = try pair.bobSession.decrypt(message: encrypted, associatedData: pair.ad)

            #expect(decrypted == plaintext)
        }

        @Test func `multiple messages one direction`() throws {
            var pair = try Self.createSessionPair()

            for i in 0 ..< 5 {
                let plaintext = Array("Message \(i)".utf8)
                let encrypted = try pair.aliceSession.encrypt(
                    plaintext: plaintext, associatedData: pair.ad
                )
                let decrypted = try pair.bobSession.decrypt(
                    message: encrypted, associatedData: pair.ad
                )
                #expect(decrypted == plaintext)
            }
        }

        @Test func `ping pong exchange`() throws {
            var pair = try Self.createSessionPair()

            // Alice → Bob
            let msg1 = Array("Hello Bob".utf8)
            let enc1 = try pair.aliceSession.encrypt(plaintext: msg1, associatedData: pair.ad)
            let dec1 = try pair.bobSession.decrypt(message: enc1, associatedData: pair.ad)
            #expect(dec1 == msg1)

            // Bob → Alice
            let msg2 = Array("Hello Alice".utf8)
            let enc2 = try pair.bobSession.encrypt(plaintext: msg2, associatedData: pair.ad)
            let dec2 = try pair.aliceSession.decrypt(message: enc2, associatedData: pair.ad)
            #expect(dec2 == msg2)

            // Alice → Bob again
            let msg3 = Array("How are you?".utf8)
            let enc3 = try pair.aliceSession.encrypt(plaintext: msg3, associatedData: pair.ad)
            let dec3 = try pair.bobSession.decrypt(message: enc3, associatedData: pair.ad)
            #expect(dec3 == msg3)
        }

        @Test func `out of order messages`() throws {
            var pair = try Self.createSessionPair()

            // Alice sends 3 messages
            let msg0 = Array("Message 0".utf8)
            let msg1 = Array("Message 1".utf8)
            let msg2 = Array("Message 2".utf8)

            let enc0 = try pair.aliceSession.encrypt(plaintext: msg0, associatedData: pair.ad)
            let enc1 = try pair.aliceSession.encrypt(plaintext: msg1, associatedData: pair.ad)
            let enc2 = try pair.aliceSession.encrypt(plaintext: msg2, associatedData: pair.ad)

            // Bob receives them out of order: 2, 0, 1
            let dec2 = try pair.bobSession.decrypt(message: enc2, associatedData: pair.ad)
            #expect(dec2 == msg2)

            let dec0 = try pair.bobSession.decrypt(message: enc0, associatedData: pair.ad)
            #expect(dec0 == msg0)

            let dec1 = try pair.bobSession.decrypt(message: enc1, associatedData: pair.ad)
            #expect(dec1 == msg1)
        }

        @Test func `skipped messages across ratchets`() throws {
            var pair = try Self.createSessionPair()

            // Alice sends 2 messages
            let msg0 = Array("msg0".utf8)
            let msg1 = Array("msg1".utf8)
            let enc0 = try pair.aliceSession.encrypt(plaintext: msg0, associatedData: pair.ad)
            _ = try pair.aliceSession.encrypt(plaintext: msg1, associatedData: pair.ad)

            // Bob receives only msg0
            let dec0 = try pair.bobSession.decrypt(message: enc0, associatedData: pair.ad)
            #expect(dec0 == msg0)

            // Bob replies (triggers DH ratchet on Alice's side)
            let reply = Array("reply".utf8)
            let encReply = try pair.bobSession.encrypt(plaintext: reply, associatedData: pair.ad)
            let decReply = try pair.aliceSession.decrypt(message: encReply, associatedData: pair.ad)
            #expect(decReply == reply)
        }

        @Test func `max skipped messages enforced`() throws {
            var pair = try Self.createSessionPair()

            // Encrypt many messages without decrypting
            var messages: [OMEMOAuthenticatedMessage] = []
            for i in 0 ..< 1002 {
                let plaintext = Array("Message \(i)".utf8)
                let encrypted = try pair.aliceSession.encrypt(
                    plaintext: plaintext, associatedData: pair.ad
                )
                messages.append(encrypted)
            }

            // Try to decrypt message 1001 directly (skipping 1001 messages)
            #expect(throws: OMEMOCryptoError.self) {
                try pair.bobSession.decrypt(message: messages[1001], associatedData: pair.ad)
            }
        }
    }

    // MARK: - Pre-Key Management

    struct PreKeyManagementTests {
        @Test func `generate pre key batch`() {
            let preKeys = OMEMOPreKeyManager.generatePreKeys(startID: 1, count: 25)

            #expect(preKeys.count == 25)
            for (index, preKey) in preKeys.enumerated() {
                let expectedID = UInt32(index) + 1
                #expect(preKey.keyID == expectedID)
                #expect(preKey.publicKeyBytes.count == 32)
            }
        }

        @Test func `signed pre key creation`() throws {
            let identity = OMEMOIdentityKeyPair()
            let spk = try OMEMOPreKeyManager.generateSignedPreKey(
                keyID: 42, identityKey: identity
            )

            #expect(spk.keyID == 42)
            #expect(spk.publicKeyBytes.count == 32)

            let signatureValid = try OMEMOX3DH.verifySignedPreKey(
                signedPreKeyPublic: spk.publicKeyBytes,
                signature: spk.signature,
                identityKey: identity.publicKeyBytes
            )
            #expect(signatureValid)
        }

        @Test func `bundle construction`() throws {
            let identity = OMEMOIdentityKeyPair()
            let deviceID = OMEMODeviceID.random()
            let spk = try OMEMOPreKeyManager.generateSignedPreKey(keyID: 1, identityKey: identity)
            let preKeys = OMEMOPreKeyManager.generatePreKeys(startID: 1, count: 25)

            let bundle = OMEMOPreKeyManager.buildBundle(
                deviceID: deviceID,
                identityKeyPair: identity,
                signedPreKey: spk,
                preKeys: preKeys
            )

            #expect(bundle.deviceID == deviceID)
            #expect(bundle.identityKey == identity.publicKeyBytes)
            #expect(bundle.signedPreKeyID == 1)
            #expect(bundle.signedPreKey == spk.publicKeyBytes)
            #expect(bundle.signedPreKeySignature == spk.signature)
            #expect(bundle.preKeys.count == 25)
            #expect(bundle.preKeys[0].id == 1)
            #expect(bundle.preKeys[0].publicKey.count == 32)
        }

        @Test func `device ID range`() {
            for _ in 0 ..< 100 {
                let id = OMEMODeviceID.random()
                #expect(id.value >= 1)
                let maxValid: UInt32 = 0x7FFF_FFFE
                #expect(id.value <= maxValid)
            }
        }
    }

    // MARK: - Error Display Text

    struct ErrorDisplayTextTests {
        @Test(arguments: [
            (OMEMOCryptoError.invalidKeyLength, "Invalid key length"),
            (OMEMOCryptoError.invalidIVLength, "Invalid initialization vector length"),
            (OMEMOCryptoError.encryptionFailed(status: -4300), "Invalid parameter"),
            (OMEMOCryptoError.encryptionFailed(status: -4301), "The output buffer is too small"),
            (OMEMOCryptoError.encryptionFailed(status: -4302), "Out of memory"),
            (OMEMOCryptoError.decryptionFailed(status: -4303), "The input is not aligned to the cipher block size"),
            (OMEMOCryptoError.decryptionFailed(status: -4304), "The input could not be decoded"),
            (OMEMOCryptoError.encryptionFailed(status: -4305), "The operation is not supported"),
            (OMEMOCryptoError.encryptionFailed(status: -1), "Unknown CommonCrypto status"),
            (OMEMOCryptoError.invalidSignature, "The signed pre-key signature is invalid"),
            (OMEMOCryptoError.invalidPublicKey, "Invalid public key"),
            (OMEMOCryptoError.sessionNotInitialized, "The encryption session is not initialized"),
            (OMEMOCryptoError.tooManySkippedMessages, "Too many skipped messages"),
            (OMEMOCryptoError.hmacVerificationFailed, "Message authentication failed")
        ])
        func `display text is readable`(error: OMEMOCryptoError, expected: String) {
            #expect(error.displayText == expected)
        }
    }

    // MARK: - Key Types

    struct KeyTypeTests {
        @Test func `identity key pair round trip`() throws {
            let original = OMEMOIdentityKeyPair()
            let restored = try OMEMOIdentityKeyPair(rawRepresentation: original.rawRepresentation)

            #expect(original.publicKeyBytes == restored.publicKeyBytes)
        }

        @Test func `pre key round trip`() throws {
            let original = OMEMOPreKey(keyID: 42)
            let restored = try OMEMOPreKey(
                keyID: 42, rawRepresentation: original.rawRepresentation
            )

            #expect(original.publicKeyBytes == restored.publicKeyBytes)
            #expect(original.keyID == restored.keyID)
        }

        @Test func `signed pre key round trip`() throws {
            let identity = OMEMOIdentityKeyPair()
            let original = try OMEMOSignedPreKey(keyID: 7, identityKey: identity)
            let restored = try OMEMOSignedPreKey(
                keyID: 7,
                rawRepresentation: original.rawRepresentation,
                signature: original.signature
            )

            #expect(original.publicKeyBytes == restored.publicKeyBytes)
            #expect(original.keyID == restored.keyID)
            #expect(original.signature == restored.signature)
        }

        @Test func `identity key agreement derivation`() throws {
            let pair = OMEMOIdentityKeyPair()
            let agreementKey = try pair.agreementPrivateKey()

            // Verify the derived agreement key is usable for DH
            let otherKey = Curve25519.KeyAgreement.PrivateKey()
            let shared = try agreementKey.sharedSecretFromKeyAgreement(with: otherKey.publicKey)
            let sharedBytes = shared.withUnsafeBytes { Array($0) }
            #expect(sharedBytes.count == 32)
        }
    }
}
