import CryptoKit

// MARK: - Errors

/// Errors thrown by OMEMO cryptographic operations.
enum OMEMOCryptoError: Error {
    case invalidKeyLength
    case invalidIVLength
    case encryptionFailed(status: Int32)
    case decryptionFailed(status: Int32)
    case invalidSignature
    case invalidPublicKey
    case sessionNotInitialized
    case tooManySkippedMessages
    case hmacVerificationFailed
    case wireFormatMismatch

    var displayText: String {
        switch self {
        case .invalidKeyLength: "Invalid key length"
        case .invalidIVLength: "Invalid initialization vector length"
        case let .encryptionFailed(status), let .decryptionFailed(status): cryptorStatusText(status)
        case .invalidSignature: "The signed pre-key signature is invalid"
        case .invalidPublicKey: "Invalid public key"
        case .sessionNotInitialized: "The encryption session is not initialized"
        case .tooManySkippedMessages: "Too many skipped messages"
        case .hmacVerificationFailed: "Message authentication failed"
        case .wireFormatMismatch: "The message is in another OMEMO version than its session"
        }
    }
}

// MARK: - Device ID

/// Typed wrapper for an OMEMO device ID (random integer in 1..2^31-1).
package struct OMEMODeviceID: Hashable {
    let value: UInt32

    package init(value: UInt32) {
        self.value = value
    }

    /// Generates a random device ID in the valid range 1..2^31-1.
    static func random() -> OMEMODeviceID {
        let value = UInt32.random(in: 1 ... 0x7FFF_FFFE)
        return OMEMODeviceID(value: value)
    }
}

// MARK: - Identity Key Pair

/// An OMEMO identity key pair: Ed25519 for signing, X25519 for DH.
///
/// The Ed25519 private key and X25519 private key share the same 32-byte scalar,
/// so one can be derived from the other via `rawRepresentation`.
package struct OMEMOIdentityKeyPair {
    let signingKey: Curve25519.Signing.PrivateKey

    /// Generates a new random identity key pair.
    init() {
        self.signingKey = Curve25519.Signing.PrivateKey()
    }

    /// Restores an identity key pair from stored raw bytes.
    package init(rawRepresentation: [UInt8]) throws {
        self.signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    /// Ed25519 public key bytes (32 bytes).
    var publicKeyBytes: [UInt8] {
        Array(signingKey.publicKey.rawRepresentation)
    }

    /// Private key bytes for storage (32 bytes).
    var rawRepresentation: [UInt8] {
        Array(signingKey.rawRepresentation)
    }

    /// Derives the X25519 agreement private key from the Ed25519 signing key.
    ///
    /// Ed25519 stores a 32-byte seed; the actual secret scalar is `SHA512(seed)[0..31]`.
    /// The X25519 private key must use this same scalar so that the X25519 public key
    /// matches the birational map of the Ed25519 public key.
    func agreementPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        let hash = SHA512.hash(data: signingKey.rawRepresentation)
        let scalar = Array(hash.prefix(32))
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar)
    }

    /// Signs data with the Ed25519 identity key.
    func sign(_ data: [UInt8]) throws -> [UInt8] {
        let signature = try signingKey.signature(for: data)
        return Array(signature)
    }
}

// MARK: - Signed Pre-Key

/// A medium-term X25519 key pair signed with the identity key.
package struct OMEMOSignedPreKey {
    let keyID: UInt32
    let keyPair: Curve25519.KeyAgreement.PrivateKey
    let signature: [UInt8]

    /// Generates a new signed pre-key, signing it with the identity key.
    init(keyID: UInt32, identityKey: OMEMOIdentityKeyPair) throws {
        self.keyID = keyID
        self.keyPair = Curve25519.KeyAgreement.PrivateKey()
        self.signature = try identityKey.sign(Array(keyPair.publicKey.rawRepresentation))
    }

    /// Restores a signed pre-key from stored raw bytes.
    package init(keyID: UInt32, rawRepresentation: [UInt8], signature: [UInt8]) throws {
        self.keyID = keyID
        self.keyPair = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
        self.signature = signature
    }

    /// X25519 public key bytes (32 bytes).
    var publicKeyBytes: [UInt8] {
        Array(keyPair.publicKey.rawRepresentation)
    }

    /// Private key bytes for storage (32 bytes).
    var rawRepresentation: [UInt8] {
        Array(keyPair.rawRepresentation)
    }
}

// MARK: - Pre-Key

/// A single-use X25519 key pair for one-time pre-key exchanges.
public struct OMEMOPreKey: Sendable {
    public let keyID: UInt32
    let keyPair: Curve25519.KeyAgreement.PrivateKey

    /// Generates a new random pre-key.
    public init(keyID: UInt32) {
        self.keyID = keyID
        self.keyPair = Curve25519.KeyAgreement.PrivateKey()
    }

    /// Restores a pre-key from stored raw bytes.
    public init(keyID: UInt32, rawRepresentation: [UInt8]) throws {
        self.keyID = keyID
        self.keyPair = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    }

    /// X25519 public key bytes (32 bytes).
    public var publicKeyBytes: [UInt8] {
        Array(keyPair.publicKey.rawRepresentation)
    }

    /// Private key bytes for storage (32 bytes).
    public var rawRepresentation: [UInt8] {
        Array(keyPair.rawRepresentation)
    }
}

// MARK: - Bundle

/// A published OMEMO bundle containing all public key material for a device. The node it was read from or is published
/// to names its version, which sets the form of the identity key and the signature. Every key is held without the
/// `0x05` type byte legacy bundles carry.
package struct OMEMOBundle {
    let deviceID: OMEMODeviceID
    /// Ed25519 public key in OMEMO 2, Curve25519 public key in legacy (32 bytes).
    package let identityKey: [UInt8]
    package let signedPreKeyID: UInt32
    /// X25519 public key (32 bytes).
    package let signedPreKey: [UInt8]
    /// The identity key's signature over the signed pre-key (64 bytes): plain Ed25519 in OMEMO 2, and the libsignal form
    /// `OMEMOLegacySignature` reads in legacy.
    package let signedPreKeySignature: [UInt8]
    /// One-time pre-keys: (id, X25519 public key bytes).
    package let preKeys: [PreKeyPublic]

    /// A single pre-key's public data within a bundle.
    package struct PreKeyPublic {
        package let id: UInt32
        package let publicKey: [UInt8]
    }
}
