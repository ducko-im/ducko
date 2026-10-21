import CryptoKit

/// Core cryptographic primitives for the OMEMO Double Ratchet and X3DH protocols.
enum OMEMOCrypto {
    /// The length of the keys a session record or an OMEMO message carries: Curve25519 and Ed25519 keys, and root,
    /// chain and message keys.
    static let keyLength = 32

    /// Root key derivation: advances the root key chain using a DH output.
    ///
    /// Computes `HKDF-SHA256(salt=rootKey, ikm=dhOutput, info="OMEMO Root Chain", output=64 bytes)`,
    /// then splits the result into a new root key (32 bytes) and chain key (32 bytes).
    static func kdfRK(rootKey: [UInt8], dhOutput: [UInt8]) -> KDFRKResult {
        let derived = hkdfSHA256(
            inputKeyMaterial: dhOutput,
            salt: rootKey,
            info: Array("OMEMO Root Chain".utf8),
            outputByteCount: 64
        )
        return KDFRKResult(
            rootKey: Array(derived[0 ..< 32]),
            chainKey: Array(derived[32 ..< 64])
        )
    }

    /// Chain key derivation: advances the symmetric ratchet, producing a message key.
    ///
    /// - `messageKey = HMAC-SHA256(chainKey, [0x01])`
    /// - `newChainKey = HMAC-SHA256(chainKey, [0x02])`
    static func kdfCK(chainKey: [UInt8]) -> KDFCKResult {
        KDFCKResult(
            messageKey: hmacSHA256(key: chainKey, data: [0x01]),
            chainKey: hmacSHA256(key: chainKey, data: [0x02])
        )
    }

    /// HMAC-SHA256 producing raw bytes.
    static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Array(mac)
    }

    /// Incremental HMAC-SHA256 over multiple data segments, avoiding concatenation.
    static func hmacSHA256(key: [UInt8], dataSegments: [[UInt8]]) -> [UInt8] {
        let symmetricKey = SymmetricKey(data: key)
        var hmac = HMAC<SHA256>(key: symmetricKey)
        for segment in dataSegments {
            hmac.update(data: segment)
        }
        return Array(hmac.finalize())
    }

    /// HKDF-SHA256 key derivation producing raw bytes.
    static func hkdfSHA256(
        inputKeyMaterial: [UInt8],
        salt: [UInt8],
        info: [UInt8],
        outputByteCount: Int
    ) -> [UInt8] {
        let ikm = SymmetricKey(data: inputKeyMaterial)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        )
        return derived.withUnsafeBytes { Array($0) }
    }

    /// X25519 Diffie-Hellman key agreement producing raw shared secret bytes.
    static func dh(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        publicKey: Curve25519.KeyAgreement.PublicKey
    ) throws -> [UInt8] {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return shared.withUnsafeBytes { Array($0) }
    }

    // MARK: - Result Types

    /// Result of a root key derivation step.
    struct KDFRKResult {
        let rootKey: [UInt8]
        let chainKey: [UInt8]
    }

    /// Result of a chain key derivation step.
    struct KDFCKResult {
        let messageKey: [UInt8]
        let chainKey: [UInt8]
    }
}
