import CryptoKit

/// Signed pre-key signatures in the legacy OMEMO (libsignal) form.
///
/// The signature is a plain Ed25519 signature by the identity key over `0x05` ‖ SPK, with the sign bit of the
/// identity's Edwards public key stored in the top bit of the signature's last byte. A legacy bundle publishes only the
/// Curve25519 identity key, so a verifier needs that bit to rebuild the Edwards key. Ed25519's S is below 2^253, which
/// leaves the bit free.
enum OMEMOLegacySignature {
    /// Signs a raw 32-byte X25519 signed pre-key, to which this adds the `0x05` type prefix.
    static func sign(signedPreKey: [UInt8], with identity: OMEMOIdentityKeyPair) throws -> [UInt8] {
        var signature = try identity.sign(prefixed(signedPreKey))
        signature[63] |= identity.publicKeyBytes[31] & 0x80
        return signature
    }

    /// Verifies a signature over a raw 32-byte X25519 signed pre-key, to which this adds the `0x05` type prefix.
    /// `identityCurveKey` is the 32-byte Curve25519 identity key, without the prefix.
    static func verify(_ signature: [UInt8], signedPreKey: [UInt8], identityCurveKey: [UInt8]) -> Bool {
        guard signature.count == 64 else { return false }

        var edSignature = signature
        let signBit = edSignature[63] >> 7
        edSignature[63] &= 0x7F

        guard let edKey = OMEMOCurveConversion.x25519ToEd25519(identityCurveKey, signBit: signBit),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: edKey)
        else { return false }
        return publicKey.isValidSignature(edSignature, for: prefixed(signedPreKey))
    }

    private static func prefixed(_ key: [UInt8]) -> [UInt8] {
        [legacyKeyType] + key
    }
}
