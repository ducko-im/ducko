import CryptoKit
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func bytes(_ hex: String) -> [UInt8] {
    var result: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        result.append(UInt8(hex[index ..< next], radix: 16)!)
        index = next
    }
    return result
}

private func repeated(_ byte: UInt8, _ count: Int) -> [UInt8] {
    [UInt8](repeating: byte, count: count)
}

private func x25519(scalar: [UInt8], u: [UInt8]) throws -> [UInt8] {
    try OMEMOCrypto.dh(
        privateKey: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar),
        publicKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation: u)
    )
}

// MARK: - Tests

/// Known-answer vectors for the primitives OMEMO is built from.
enum OMEMOPrimitiveVectorTests {
    struct HKDFSHA256 {
        /// RFC 5869 Appendix A.1–A.3.
        @Test(arguments: [
            (
                ikm: repeated(0x0B, 22), salt: bytes("000102030405060708090a0b0c"), info: bytes("f0f1f2f3f4f5f6f7f8f9"),
                okm: "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"
            ),
            (
                ikm: [UInt8](0x00 ... 0x4F), salt: [UInt8](0x60 ... 0xAF), info: [UInt8](0xB0 ... 0xFF),
                okm: "b11e398dc80327a1c8e7f78c596a49344f012eda2d4efad8a050cc4c19afa97c59045a99cac7827271cb41c65e590e09da3275600c2f09b8367793a9aca3db71cc30c58179ec3e87c14c01d5c1f3434f1d87"
            ),
            (
                ikm: repeated(0x0B, 22), salt: [], info: [],
                okm: "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8"
            )
        ])
        func `matches RFC 5869`(ikm: [UInt8], salt: [UInt8], info: [UInt8], okm: String) {
            let expected = bytes(okm)

            let derived = OMEMOCrypto.hkdfSHA256(inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: expected.count)

            #expect(derived == expected)
        }
    }

    struct HMACSHA256 {
        /// RFC 4231 §4.2–§4.8; test case 5 checks only the 128-bit truncation, which OMEMO also uses.
        @Test(arguments: [
            (key: repeated(0x0B, 20), data: Array("Hi There".utf8), mac: "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"),
            (key: Array("Jefe".utf8), data: Array("what do ya want for nothing?".utf8), mac: "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"),
            (key: repeated(0xAA, 20), data: repeated(0xDD, 50), mac: "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"),
            (key: [UInt8](0x01 ... 0x19), data: repeated(0xCD, 50), mac: "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"),
            (key: repeated(0x0C, 20), data: Array("Test With Truncation".utf8), mac: "a3b6167473100ee06e0c796c2955552b"),
            (
                key: repeated(0xAA, 131), data: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8),
                mac: "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
            ),
            (
                key: repeated(0xAA, 131),
                data: Array(
                    "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."
                        .utf8
                ),
                mac: "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"
            )
        ])
        func `matches RFC 4231`(key: [UInt8], data: [UInt8], mac: String) {
            let expected = bytes(mac)

            let computed = OMEMOCrypto.hmacSHA256(key: key, data: data)

            #expect(Array(computed.prefix(expected.count)) == expected)
        }
    }

    struct AES256CBC {
        /// NIST SP 800-38A F.2.5/F.2.6 (CBC-AES256).
        static let key = bytes("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        static let iv = bytes("000102030405060708090a0b0c0d0e0f")
        static let plaintext = bytes(
            "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710"
        )
        static let ciphertext = bytes(
            "f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d39f23369a9d9bacfa530e26304231461b2eb05e2c39be9fcda6c19078c6a9d1b"
        )
        /// The PKCS#7 block that follows the NIST ciphertext: sixteen 0x10 bytes encrypted after its last block.
        static let paddingBlock = bytes("3f461796d6b0d6b2e0c2a72b4d80e644")

        @Test func `encryption matches NIST SP 800-38A F.2.5 followed by a full padding block`() throws {
            let encrypted = try OMEMOAESCBC.encrypt(plaintext: Self.plaintext, key: Self.key, iv: Self.iv)

            #expect(encrypted == Self.ciphertext + Self.paddingBlock)
        }

        @Test func `decryption matches NIST SP 800-38A F.2.6 and strips the padding block`() throws {
            let decrypted = try OMEMOAESCBC.decrypt(ciphertext: Self.ciphertext + Self.paddingBlock, key: Self.key, iv: Self.iv)

            #expect(decrypted == Self.plaintext)
        }

        @Test func `a partial block is padded with PKCS#7`() throws {
            let plaintext = Array(Self.plaintext.prefix(20))
            let expected = bytes("f58c4c04d6e5f1ba779eabfb5f7bfbd684354e280bfa27ef071b563dc89d0364")

            let encrypted = try OMEMOAESCBC.encrypt(plaintext: plaintext, key: Self.key, iv: Self.iv)
            let decrypted = try OMEMOAESCBC.decrypt(ciphertext: expected, key: Self.key, iv: Self.iv)

            #expect(encrypted == expected)
            #expect(decrypted == plaintext)
        }
    }

    struct X25519 {
        /// RFC 7748 §5.2, including a u-coordinate with the high bit set, which X25519 must mask.
        @Test(arguments: [
            (
                scalar: "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4",
                u: "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c",
                output: "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"
            ),
            (
                scalar: "4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d",
                u: "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493",
                output: "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957"
            )
        ])
        func `matches RFC 7748 §5.2`(scalar: String, u: String, output: String) throws {
            let result = try x25519(scalar: bytes(scalar), u: bytes(u))

            #expect(result == bytes(output))
        }

        @Test func `iterating 1000 times matches RFC 7748 §5.2`() throws {
            var k = bytes("0900000000000000000000000000000000000000000000000000000000000000")
            var u = k
            var afterOne: [UInt8] = []

            for iteration in 1 ... 1000 {
                (k, u) = try (x25519(scalar: k, u: u), k)
                if iteration == 1 {
                    afterOne = k
                }
            }

            #expect(afterOne == bytes("422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079"))
            #expect(k == bytes("684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51"))
        }

        @Test func `Diffie-Hellman matches RFC 7748 §6.1`() throws {
            let alice = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: bytes("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
            )
            let bob = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: bytes("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
            )
            let shared = bytes("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")

            #expect(Array(alice.publicKey.rawRepresentation) == bytes("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"))
            #expect(Array(bob.publicKey.rawRepresentation) == bytes("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"))
            #expect(try OMEMOCrypto.dh(privateKey: alice, publicKey: bob.publicKey) == shared)
            #expect(try OMEMOCrypto.dh(privateKey: bob, publicKey: alice.publicKey) == shared)
        }
    }

    struct Ed25519 {
        /// RFC 8032 §7.1 TEST 1, 2, 3 and SHA(abc). An identity key is restored from its 32-byte seed, as these secrets are.
        @Test(arguments: [
            (
                secret: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
                publicKey: "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a",
                message: "",
                signature: "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
            ),
            (
                secret: "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
                publicKey: "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c",
                message: "72",
                signature: "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"
            ),
            (
                secret: "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
                publicKey: "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
                message: "af82",
                signature: "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"
            ),
            (
                secret: "833fe62409237b9d62ec77587520911e9a759cec1d19755b7da901b96dca3d42",
                publicKey: "ec172b93ad5e563bf4932c70e1245034c35467ef2efd4d64ebf819683467e2bf",
                message: "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
                signature: "dc2a4459e7369633a52b1bf277839a00201009a3efbf3ecb69bea2186c26b58909351fc9ac90b3ecfdfbc7c66431e0303dca179c138ac17ad9bef1177331a704"
            )
        ])
        func `matches RFC 8032 §7.1`(secret: String, publicKey: String, message: String, signature: String) throws {
            let identity = try OMEMOIdentityKeyPair(rawRepresentation: bytes(secret))
            let ownSignature = try identity.sign(bytes(message))

            #expect(identity.publicKeyBytes == bytes(publicKey))
            #expect(try OMEMOX3DH.verifySignedPreKey(signedPreKeyPublic: bytes(message), signature: bytes(signature), identityKey: bytes(publicKey)))
            #expect(try OMEMOX3DH.verifySignedPreKey(signedPreKeyPublic: bytes(message), signature: ownSignature, identityKey: bytes(publicKey)))
        }
    }
}
