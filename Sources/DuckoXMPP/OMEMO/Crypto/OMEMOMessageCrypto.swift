import CryptoKit

/// XEP-0384's encryption of a Double Ratchet message: HKDF expands the message key into an AES-256-CBC key, an HMAC
/// key and an IV, and the truncated HMAC-SHA-256 covers the associated data and the serialized message. The versions
/// differ in the HKDF info, the MAC length and the message encoding. `deriveKeys(from:for:)` and the MAC helpers also
/// serve `OMEMOPayload`.
enum OMEMOMessageCrypto {
    /// Encrypts with a 32-byte `messageKey` from the Double Ratchet chain into the `OMEMOMessage` that `message` builds
    /// around the ciphertext. `associatedData` is authenticated, not encrypted.
    static func encrypt(
        plaintext: [UInt8],
        messageKey: [UInt8],
        associatedData: [UInt8],
        message: (_ ciphertext: [UInt8]) -> OMEMOMessage
    ) throws -> OMEMOAuthenticatedMessage {
        let sealed = try seal(plaintext, messageKey: messageKey, associatedData: associatedData, format: .omemo2, content: message)
        return OMEMOAuthenticatedMessage(mac: sealed.mac, message: sealed.content)
    }

    /// Encrypts a legacy message as `encrypt(plaintext:messageKey:associatedData:message:)` encrypts an OMEMO 2 one,
    /// with `message` building its content around the ciphertext.
    static func encrypt(
        plaintext: [UInt8],
        messageKey: [UInt8],
        associatedData: [UInt8],
        message: (_ ciphertext: [UInt8]) -> OMEMOLegacyMessage.Content
    ) throws -> OMEMOLegacyMessage {
        let sealed = try seal(plaintext, messageKey: messageKey, associatedData: associatedData, format: .legacy, content: message)
        return OMEMOLegacyMessage(content: sealed.content, mac: sealed.mac)
    }

    /// Verifies the MAC over the message's exact received bytes BEFORE AES-CBC decrypt. Throws `hmacVerificationFailed`
    /// on tag mismatch.
    static func decrypt(
        _ authenticatedMessage: OMEMOAuthenticatedMessage,
        messageKey: [UInt8],
        associatedData: [UInt8]
    ) throws -> [UInt8] {
        try open(
            authenticatedMessage.message, mac: authenticatedMessage.mac, messageKey: messageKey, associatedData: associatedData, format: .omemo2
        )
    }

    /// Verifies a legacy message's MAC over its exact received content BEFORE AES-CBC decrypt. Throws
    /// `hmacVerificationFailed` on tag mismatch.
    static func decrypt(
        _ legacyMessage: OMEMOLegacyMessage,
        messageKey: [UInt8],
        associatedData: [UInt8]
    ) throws -> [UInt8] {
        try open(legacyMessage.content, mac: legacyMessage.mac, messageKey: messageKey, associatedData: associatedData, format: .legacy)
    }

    /// Encrypts `plaintext` into the content `content` builds around the ciphertext, and MACs the associated data
    /// followed by the content's serialized bytes, with the format's key derivation and MAC length.
    private static func seal<Content: MACCoveredContent>(
        _ plaintext: [UInt8],
        messageKey: [UInt8],
        associatedData: [UInt8],
        format: OMEMOWireFormat,
        content: (_ ciphertext: [UInt8]) -> Content
    ) throws -> (content: Content, mac: [UInt8]) {
        let keys = deriveKeys(from: messageKey, for: .messageKey(of: format))
        let content = try content(OMEMOAESCBC.encrypt(plaintext: plaintext, key: keys.encryptionKey, iv: keys.iv))
        let mac = truncatedMAC(key: keys.authenticationKey, over: [associatedData, content.serialized], length: format.macLength)
        return (content, mac)
    }

    /// Verifies `mac` over the associated data followed by the content's received bytes BEFORE decrypting its
    /// ciphertext, with the format's key derivation and MAC length.
    private static func open(
        _ content: some MACCoveredContent,
        mac: [UInt8],
        messageKey: [UInt8],
        associatedData: [UInt8],
        format: OMEMOWireFormat
    ) throws -> [UInt8] {
        let keys = deriveKeys(from: messageKey, for: .messageKey(of: format))
        try verifyMAC(mac, key: keys.authenticationKey, over: [associatedData, content.serialized], length: format.macLength)
        return try OMEMOAESCBC.decrypt(ciphertext: content.ciphertext, key: keys.encryptionKey, iv: keys.iv)
    }

    /// What a key is expanded for. The HKDF info string keeps the uses apart.
    enum KeyUse {
        /// An OMEMO 2 Double Ratchet message key.
        case messageKey
        /// A legacy Double Ratchet message key.
        case legacyMessageKey
        /// The key that encrypts a message's `<payload>`.
        case payloadKey

        var info: [UInt8] {
            switch self {
            case .messageKey: OMEMOWireFormat.omemo2.messageKeyInfo
            case .legacyMessageKey: OMEMOWireFormat.legacy.messageKeyInfo
            case .payloadKey: Array("OMEMO Payload".utf8)
            }
        }

        /// The use of a Double Ratchet message key in `format`.
        static func messageKey(of format: OMEMOWireFormat) -> Self {
            switch format {
            case .omemo2: .messageKey
            case .legacy: .legacyMessageKey
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

    /// HMAC-SHA256 over the concatenated segments, truncated to `length` bytes.
    static func truncatedMAC(key: [UInt8], over segments: [[UInt8]], length: Int) -> [UInt8] {
        Array(OMEMOCrypto.hmacSHA256(key: key, dataSegments: segments).prefix(length))
    }

    /// Throws `hmacVerificationFailed` unless `mac` is the MAC over `segments` truncated to `length` bytes, comparing in
    /// constant time to prevent timing attacks.
    static func verifyMAC(_ mac: [UInt8], key: [UInt8], over segments: [[UInt8]], length: Int) throws {
        let expected = truncatedMAC(key: key, over: segments, length: length)
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

/// The part of a Double Ratchet message its MAC covers, in either version's encoding.
private protocol MACCoveredContent {
    var ciphertext: [UInt8] { get }
    /// The exact bytes the MAC covers after the associated data.
    var serialized: [UInt8] { get }
}

extension OMEMOMessage: MACCoveredContent {}
extension OMEMOLegacyMessage.Content: MACCoveredContent {}

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
        self.keyMaterial = key + OMEMOMessageCrypto.truncatedMAC(
            key: keys.authenticationKey, over: [ciphertext], length: OMEMOAuthenticatedMessage.macLength
        )
    }

    /// Verifies the MAC BEFORE AES-CBC decrypt. Throws `invalidPayload` when the key material is not a key and a MAC.
    func decrypt() throws -> [UInt8] {
        guard keyMaterial.count == Self.keyLength + OMEMOAuthenticatedMessage.macLength else {
            throw OMEMOModuleError.invalidPayload
        }
        let keys = OMEMOMessageCrypto.deriveKeys(from: Array(keyMaterial.prefix(Self.keyLength)), for: .payloadKey)
        try OMEMOMessageCrypto.verifyMAC(
            Array(keyMaterial.dropFirst(Self.keyLength)), key: keys.authenticationKey, over: [ciphertext],
            length: OMEMOAuthenticatedMessage.macLength
        )
        return try OMEMOAESCBC.decrypt(ciphertext: ciphertext, key: keys.encryptionKey, iv: keys.iv)
    }
}
