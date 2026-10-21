import CryptoKit

/// XEP-0384's encryption of a Double Ratchet message: HKDF expands the message key into an AES-256-CBC key, an HMAC
/// key and an IV, and the truncated HMAC-SHA-256 covers the associated data and the serialized `OMEMOMessage`.
/// `deriveKeys(from:for:)` and the MAC helpers also serve `OMEMOPayload`.
enum OMEMOMessageCrypto {
    /// Encrypts with a 32-byte `messageKey` from the Double Ratchet chain into the `OMEMOMessage` that `message` builds
    /// around the ciphertext. `associatedData` is authenticated, not encrypted.
    static func encrypt(
        plaintext: [UInt8],
        messageKey: [UInt8],
        associatedData: [UInt8],
        message: (_ ciphertext: [UInt8]) -> OMEMOMessage
    ) throws -> OMEMOAuthenticatedMessage {
        let keys = deriveKeys(from: messageKey, for: .messageKey)
        let message = try message(OMEMOAESCBC.encrypt(plaintext: plaintext, key: keys.encryptionKey, iv: keys.iv))
        let mac = truncatedMAC(key: keys.authenticationKey, over: [associatedData, message.serialized])
        return OMEMOAuthenticatedMessage(mac: mac, message: message)
    }

    /// Verifies the MAC over the message's exact received bytes BEFORE AES-CBC decrypt. Throws `hmacVerificationFailed`
    /// on tag mismatch.
    static func decrypt(
        _ authenticatedMessage: OMEMOAuthenticatedMessage,
        messageKey: [UInt8],
        associatedData: [UInt8]
    ) throws -> [UInt8] {
        let keys = deriveKeys(from: messageKey, for: .messageKey)
        try verifyMAC(
            authenticatedMessage.mac,
            key: keys.authenticationKey,
            over: [associatedData, authenticatedMessage.message.serialized]
        )
        return try OMEMOAESCBC.decrypt(ciphertext: authenticatedMessage.message.ciphertext, key: keys.encryptionKey, iv: keys.iv)
    }

    /// What a key is expanded for. The HKDF info string keeps the two uses apart.
    enum KeyUse {
        /// A Double Ratchet message key.
        case messageKey
        /// The key that encrypts a message's `<payload>`.
        case payloadKey

        var info: [UInt8] {
            switch self {
            case .messageKey: Array("OMEMO Message Key Material".utf8)
            case .payloadKey: Array("OMEMO Payload".utf8)
            }
        }
    }

    /// Derives the AES key (32), HMAC key (32) and IV (16) from a key, with a zero salt.
    static func deriveKeys(from key: [UInt8], for use: KeyUse) -> DerivedKeys {
        let derived = OMEMOCrypto.hkdfSHA256(
            inputKeyMaterial: key,
            salt: [UInt8](repeating: 0, count: 32),
            info: use.info,
            outputByteCount: 80
        )
        return DerivedKeys(
            encryptionKey: Array(derived[0 ..< 32]),
            authenticationKey: Array(derived[32 ..< 64]),
            iv: Array(derived[64 ..< 80])
        )
    }

    /// HMAC-SHA256 over the concatenated segments, truncated to 16 bytes.
    static func truncatedMAC(key: [UInt8], over segments: [[UInt8]]) -> [UInt8] {
        Array(OMEMOCrypto.hmacSHA256(key: key, dataSegments: segments).prefix(OMEMOAuthenticatedMessage.macLength))
    }

    /// Throws `hmacVerificationFailed` unless `mac` is the truncated MAC over `segments`, comparing in constant time to
    /// prevent timing attacks.
    static func verifyMAC(_ mac: [UInt8], key: [UInt8], over segments: [[UInt8]]) throws {
        let expected = truncatedMAC(key: key, over: segments)
        guard mac.count == expected.count else { throw OMEMOCryptoError.hmacVerificationFailed }
        var difference: UInt8 = 0
        for index in 0 ..< mac.count {
            difference |= mac[index] ^ expected[index]
        }
        guard difference == 0 else { throw OMEMOCryptoError.hmacVerificationFailed }
    }

    struct DerivedKeys {
        let encryptionKey: [UInt8]
        let authenticationKey: [UInt8]
        let iv: [UInt8]
    }
}

/// A message's `<payload>`: its content encrypted under a fresh key. The key travels to each recipient device inside
/// the ratchet message, together with the payload's MAC, so the payload itself is only the ciphertext.
struct OMEMOPayload {
    static let keyLength = 32

    let ciphertext: [UInt8]
    /// The key followed by the truncated MAC over `ciphertext` (48 bytes): what each recipient's ratchet message carries.
    let keyMaterial: [UInt8]

    init(ciphertext: [UInt8], keyMaterial: [UInt8]) {
        self.ciphertext = ciphertext
        self.keyMaterial = keyMaterial
    }

    /// Encrypts `plaintext` under a 32-byte `key`.
    init(encrypting plaintext: [UInt8], key: [UInt8]) throws {
        let keys = OMEMOMessageCrypto.deriveKeys(from: key, for: .payloadKey)
        let ciphertext = try OMEMOAESCBC.encrypt(plaintext: plaintext, key: keys.encryptionKey, iv: keys.iv)
        self.ciphertext = ciphertext
        self.keyMaterial = key + OMEMOMessageCrypto.truncatedMAC(key: keys.authenticationKey, over: [ciphertext])
    }

    /// Verifies the MAC BEFORE AES-CBC decrypt. Throws `invalidPayload` when the key material is not a key and a MAC.
    func decrypt() throws -> [UInt8] {
        guard keyMaterial.count == Self.keyLength + OMEMOAuthenticatedMessage.macLength else {
            throw OMEMOModuleError.invalidPayload
        }
        let keys = OMEMOMessageCrypto.deriveKeys(from: Array(keyMaterial.prefix(Self.keyLength)), for: .payloadKey)
        try OMEMOMessageCrypto.verifyMAC(
            Array(keyMaterial.dropFirst(Self.keyLength)), key: keys.authenticationKey, over: [ciphertext]
        )
        return try OMEMOAESCBC.decrypt(ciphertext: ciphertext, key: keys.encryptionKey, iv: keys.iv)
    }
}
