/// The constants in which the two OMEMO versions' X3DH and Double Ratchet differ.
extension OMEMOWireFormat {
    /// The HKDF info of the X3DH shared secret.
    var x3dhInfo: [UInt8] {
        switch self {
        case .omemo2: Array("OMEMO X3DH".utf8)
        case .legacy: Array("WhisperText".utf8)
        }
    }

    /// The HKDF info of a root chain step.
    var rootChainInfo: [UInt8] {
        switch self {
        case .omemo2: Array("OMEMO Root Chain".utf8)
        case .legacy: Array("WhisperRatchet".utf8)
        }
    }

    /// The HKDF info that expands a message key into its encryption key, MAC key and IV.
    var messageKeyInfo: [UInt8] {
        switch self {
        case .omemo2: Array("OMEMO Message Key Material".utf8)
        case .legacy: Array("WhisperMessageKeys".utf8)
        }
    }

    /// The length a ratchet message's HMAC-SHA-256 is truncated to.
    var macLength: Int {
        switch self {
        case .omemo2: 16
        case .legacy: 8
        }
    }

    /// A 32-byte identity key as the associated data encodes it: the Ed25519 key in OMEMO 2, and the Curve25519 key
    /// after its `0x05` type byte in legacy.
    func encodedIdentityKey(_ key: [UInt8]) -> [UInt8] {
        switch self {
        case .omemo2: key
        case .legacy: [legacyKeyType] + key
        }
    }
}
