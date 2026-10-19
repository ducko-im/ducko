import CryptoKit

/// Pre-key generation and bundle construction for OMEMO.
public enum OMEMOPreKeyManager {
    /// Minimum number of pre-keys to include when publishing a bundle.
    public static let minimumPreKeyCount = 25

    /// Target number of pre-keys to maintain in storage.
    public static let targetPreKeyCount = 100

    /// Generates a batch of one-time pre-keys with sequential IDs starting at `startID`.
    public static func generatePreKeys(startID: UInt32, count: Int) -> [OMEMOPreKey] {
        (0 ..< count).map { offset in
            OMEMOPreKey(keyID: startID + UInt32(offset))
        }
    }

    /// Generates a signed pre-key, signed with the identity key.
    static func generateSignedPreKey(
        keyID: UInt32,
        identityKey: OMEMOIdentityKeyPair
    ) throws -> OMEMOSignedPreKey {
        try OMEMOSignedPreKey(keyID: keyID, identityKey: identityKey)
    }

    /// Generates a signed pre-key for the identity whose raw key is `identityKeyRaw`, as the raw private key and the
    /// signature over its public half, for storing beside that identity.
    package static func generateSignedPreKeyData(
        keyID: UInt32,
        identityKeyRaw: [UInt8]
    ) throws -> (keyRaw: [UInt8], signature: [UInt8]) {
        let signedPreKey = try generateSignedPreKey(
            keyID: keyID, identityKey: OMEMOIdentityKeyPair(rawRepresentation: identityKeyRaw)
        )
        return (signedPreKey.rawRepresentation, signedPreKey.signature)
    }

    /// Builds a publishable OMEMO bundle from local key material.
    static func buildBundle(
        deviceID: OMEMODeviceID,
        identityKeyPair: OMEMOIdentityKeyPair,
        signedPreKey: OMEMOSignedPreKey,
        preKeys: [OMEMOPreKey]
    ) -> OMEMOBundle {
        OMEMOBundle(
            deviceID: deviceID,
            identityKey: identityKeyPair.publicKeyBytes,
            signedPreKeyID: signedPreKey.keyID,
            signedPreKey: signedPreKey.publicKeyBytes,
            signedPreKeySignature: signedPreKey.signature,
            preKeys: preKeys.map { OMEMOBundle.PreKeyPublic(id: $0.keyID, publicKey: $0.publicKeyBytes) }
        )
    }
}
