import CryptoKit

/// Extended Triple Diffie-Hellman (X3DH) key agreement protocol for OMEMO.
///
/// Both initiator and responder derive the same shared secret and associated data,
/// which are then used to initialize a Double Ratchet session.
package enum OMEMOX3DH {
    /// Initiator (Alice) computes a shared secret from the peer's published bundle.
    ///
    /// - Parameters:
    ///   - identityKeyPair: Our Ed25519 identity key pair.
    ///   - peerBundle: The peer's published key material.
    ///   - format: The OMEMO version of the peer's bundle.
    /// - Returns: Shared secret and associated data for Double Ratchet initialization.
    package static func initiatorKeyAgreement(
        identityKeyPair: OMEMOIdentityKeyPair,
        peerBundle: OMEMOX3DHPeerBundle,
        format: OMEMOWireFormat
    ) throws -> X3DHResult {
        // 1. Verify the signed pre-key signature
        guard try verifySignedPreKey(
            signedPreKeyPublic: peerBundle.signedPreKey,
            signature: peerBundle.signedPreKeySignature,
            identityKey: peerBundle.identityKey,
            format: format
        ) else {
            throw OMEMOCryptoError.invalidSignature
        }

        // 2. Take the identity keys' X25519 forms for DH
        let ourAgreementKey = try identityKeyPair.agreementPrivateKey()
        let peerIdentityX25519 = try agreementPublicKey(ofIdentityKey: peerBundle.identityKey, format: format)
        let peerSPK = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerBundle.signedPreKey)

        // 3. Generate ephemeral key pair
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()

        // 4. Perform DH operations and derive shared secret
        let dhOutput = try performDHOperations(
            ourIdentityKey: ourAgreementKey,
            ephemeralKey: ephemeralKey,
            peerIdentityKey: peerIdentityX25519,
            peerSignedPreKey: peerSPK,
            peerOneTimePreKey: peerBundle.oneTimePreKey
        )

        let result = try deriveSharedSecret(
            dhOutput: dhOutput,
            initiatorIdentityKey: identityKey(of: identityKeyPair, format: format),
            responderIdentityKey: peerBundle.identityKey,
            format: format
        )

        return X3DHResult(
            sharedSecret: result.sharedSecret,
            associatedData: result.associatedData,
            ephemeralPublicKey: Array(ephemeralKey.publicKey.rawRepresentation)
        )
    }

    /// Responder (Bob) computes a shared secret from the initiator's initial message.
    static func responderKeyAgreement( // swiftlint:disable:this function_parameter_count
        identityKeyPair: OMEMOIdentityKeyPair,
        signedPreKey: OMEMOSignedPreKey,
        oneTimePreKey: OMEMOPreKey?,
        peerIdentityKey: [UInt8],
        peerEphemeralKey: [UInt8],
        format: OMEMOWireFormat
    ) throws -> X3DHResult {
        let ourAgreementKey = try identityKeyPair.agreementPrivateKey()
        let peerIdentityX25519 = try agreementPublicKey(ofIdentityKey: peerIdentityKey, format: format)
        let peerEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeralKey)

        // DH operations mirrored from initiator
        let dh1 = try OMEMOCrypto.dh(privateKey: signedPreKey.keyPair, publicKey: peerIdentityX25519)
        let dh2 = try OMEMOCrypto.dh(privateKey: ourAgreementKey, publicKey: peerEphemeral)
        let dh3 = try OMEMOCrypto.dh(privateKey: signedPreKey.keyPair, publicKey: peerEphemeral)

        var dhOutput = dh1 + dh2 + dh3
        if let opk = oneTimePreKey {
            let dh4 = try OMEMOCrypto.dh(privateKey: opk.keyPair, publicKey: peerEphemeral)
            dhOutput += dh4
        }

        let result = try deriveSharedSecret(
            dhOutput: dhOutput,
            initiatorIdentityKey: peerIdentityKey,
            responderIdentityKey: identityKey(of: identityKeyPair, format: format),
            format: format
        )

        return X3DHResult(
            sharedSecret: result.sharedSecret,
            associatedData: result.associatedData,
            ephemeralPublicKey: peerEphemeralKey
        )
    }

    /// Validates a signed pre-key's signature against the identity key: a plain Ed25519 signature in OMEMO 2, and the
    /// libsignal form `OMEMOLegacySignature` reads in legacy.
    static func verifySignedPreKey(
        signedPreKeyPublic: [UInt8],
        signature: [UInt8],
        identityKey: [UInt8],
        format: OMEMOWireFormat
    ) throws -> Bool {
        switch format {
        case .omemo2:
            let edPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: identityKey)
            return edPublicKey.isValidSignature(signature, for: signedPreKeyPublic)
        case .legacy:
            return OMEMOLegacySignature.verify(signature, signedPreKey: signedPreKeyPublic, identityCurveKey: identityKey)
        }
    }

    /// Performs the 3 or 4 DH operations for the initiator side.
    private static func performDHOperations(
        ourIdentityKey: Curve25519.KeyAgreement.PrivateKey,
        ephemeralKey: Curve25519.KeyAgreement.PrivateKey,
        peerIdentityKey: Curve25519.KeyAgreement.PublicKey,
        peerSignedPreKey: Curve25519.KeyAgreement.PublicKey,
        peerOneTimePreKey: [UInt8]?
    ) throws -> [UInt8] {
        let dh1 = try OMEMOCrypto.dh(privateKey: ourIdentityKey, publicKey: peerSignedPreKey)
        let dh2 = try OMEMOCrypto.dh(privateKey: ephemeralKey, publicKey: peerIdentityKey)
        let dh3 = try OMEMOCrypto.dh(privateKey: ephemeralKey, publicKey: peerSignedPreKey)

        var dhOutput = dh1 + dh2 + dh3

        if let opkBytes = peerOneTimePreKey {
            let opk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: opkBytes)
            let dh4 = try OMEMOCrypto.dh(privateKey: ephemeralKey, publicKey: opk)
            dhOutput += dh4
        }

        return dhOutput
    }

    /// Derives shared secret and associated data from concatenated DH outputs. libsignal derives 64 bytes and seeds the
    /// root key with the first 32, which HKDF makes the same as deriving 32.
    private static func deriveSharedSecret(
        dhOutput: [UInt8],
        initiatorIdentityKey: [UInt8],
        responderIdentityKey: [UInt8],
        format: OMEMOWireFormat
    ) -> DerivedSecret {
        // IKM = 32 bytes of 0xFF || DH outputs
        let ikm = [UInt8](repeating: 0xFF, count: 32) + dhOutput

        let sharedSecret = OMEMOCrypto.hkdfSHA256(
            inputKeyMaterial: ikm,
            salt: [UInt8](repeating: 0, count: 32),
            info: format.x3dhInfo,
            outputByteCount: 32
        )

        // AD = Encode(IK_A) || Encode(IK_B)
        let associatedData = format.encodedIdentityKey(initiatorIdentityKey) + format.encodedIdentityKey(responderIdentityKey)

        return DerivedSecret(sharedSecret: sharedSecret, associatedData: associatedData)
    }

    /// Our identity public key as the format names it: the Ed25519 key in OMEMO 2, and the Curve25519 key in legacy.
    package static func identityKey(of identityKeyPair: OMEMOIdentityKeyPair, format: OMEMOWireFormat) throws -> [UInt8] {
        switch format {
        case .omemo2: identityKeyPair.publicKeyBytes
        case .legacy: try Array(identityKeyPair.agreementPrivateKey().publicKey.rawRepresentation)
        }
    }

    /// A peer identity key's X25519 form: the birational map of the Ed25519 key in OMEMO 2, and the key itself in legacy.
    private static func agreementPublicKey(
        ofIdentityKey identityKey: [UInt8], format: OMEMOWireFormat
    ) throws -> Curve25519.KeyAgreement.PublicKey {
        switch format {
        case .omemo2:
            guard let x25519Bytes = OMEMOCurveConversion.ed25519ToX25519(identityKey) else {
                throw OMEMOCryptoError.invalidPublicKey
            }
            return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: x25519Bytes)
        case .legacy:
            return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: identityKey)
        }
    }

    // MARK: - Types

    private struct DerivedSecret {
        let sharedSecret: [UInt8]
        let associatedData: [UInt8]
    }
}

// MARK: - Public Types

/// Peer's published key material for X3DH key agreement.
package struct OMEMOX3DHPeerBundle {
    /// Ed25519 public key in OMEMO 2, Curve25519 public key without its `0x05` type byte in legacy (32 bytes).
    let identityKey: [UInt8]
    /// X25519 public key (32 bytes).
    let signedPreKey: [UInt8]
    /// The identity key's signature over the signed pre-key (64 bytes).
    let signedPreKeySignature: [UInt8]
    /// X25519 public key (32 bytes), optional.
    let oneTimePreKey: [UInt8]?

    package init(identityKey: [UInt8], signedPreKey: [UInt8], signedPreKeySignature: [UInt8], oneTimePreKey: [UInt8]?) {
        self.identityKey = identityKey
        self.signedPreKey = signedPreKey
        self.signedPreKeySignature = signedPreKeySignature
        self.oneTimePreKey = oneTimePreKey
    }
}

/// Result of an X3DH key agreement.
package struct X3DHResult {
    /// Shared secret for Double Ratchet initialization (32 bytes).
    package let sharedSecret: [UInt8]
    /// Associated data: Encode(IK_A) || Encode(IK_B) (64 bytes in OMEMO 2, 66 in legacy).
    package let associatedData: [UInt8]
    /// Ephemeral public key sent/received in the initial message (32 bytes).
    package let ephemeralPublicKey: [UInt8]
}
