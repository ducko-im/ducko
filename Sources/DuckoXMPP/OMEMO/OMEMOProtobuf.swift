/// `OMEMOMessage` (XEP-0384): one Double Ratchet message.
struct OMEMOMessage {
    private enum Field: UInt32 {
        case n = 1
        case pn = 2
        case dhPub = 3
        case ciphertext = 4
    }

    let messageNumber: UInt32
    let previousChainCount: UInt32
    /// The sender's current ratchet public key (32 bytes).
    let dhPublicKey: [UInt8]
    /// Optional in the schema, but a message without it has nothing to decrypt, so decoding requires it.
    let ciphertext: [UInt8]
    /// The message in its wire encoding, made once. The MAC covers these exact bytes, so a decoded message keeps
    /// the bytes it arrived as.
    let serialized: [UInt8]

    init(messageNumber: UInt32, previousChainCount: UInt32, dhPublicKey: [UInt8], ciphertext: [UInt8]) {
        self.messageNumber = messageNumber
        self.previousChainCount = previousChainCount
        self.dhPublicKey = dhPublicKey
        self.ciphertext = ciphertext
        var writer = ProtobufWriter()
        writer.append(Field.n, messageNumber)
        writer.append(Field.pn, previousChainCount)
        writer.append(Field.dhPub, dhPublicKey)
        writer.append(Field.ciphertext, ciphertext)
        self.serialized = writer.bytes
    }

    init(serialized: [UInt8]) throws {
        let fields = try ProtobufFields(decoding: serialized)
        self.messageNumber = try fields.uint32(Field.n)
        self.previousChainCount = try fields.uint32(Field.pn)
        self.dhPublicKey = try fields.key(Field.dhPub, length: OMEMOCrypto.keyLength)
        self.ciphertext = try fields.bytes(Field.ciphertext)
        self.serialized = serialized
    }
}

/// `OMEMOAuthenticatedMessage` (XEP-0384): an `OMEMOMessage` with its truncated MAC.
package struct OMEMOAuthenticatedMessage {
    private enum Field: UInt32 {
        case mac = 1
        case message = 2
    }

    static let macLength = OMEMOWireFormat.omemo2.macLength

    let mac: [UInt8]
    let message: OMEMOMessage

    init(mac: [UInt8], message: OMEMOMessage) {
        self.mac = mac
        self.message = message
    }

    init(serialized: [UInt8]) throws {
        let fields = try ProtobufFields(decoding: serialized)
        let mac = try fields.bytes(Field.mac)
        guard mac.count == Self.macLength else { throw OMEMOModuleError.invalidKeyData }
        self.mac = mac
        self.message = try OMEMOMessage(serialized: fields.bytes(Field.message))
    }

    var serialized: [UInt8] {
        var writer = ProtobufWriter()
        writer.append(Field.mac, mac)
        writer.append(Field.message, message.serialized)
        return writer.bytes
    }
}

/// `OMEMOKeyExchange` (XEP-0384): the X3DH values that start a session, around its first authenticated message.
struct OMEMOKeyExchange {
    private enum Field: UInt32 {
        case pkID = 1
        case spkID = 2
        case ik = 3
        case ek = 4
        case message = 5
    }

    let preKeyID: UInt32
    let signedPreKeyID: UInt32
    /// The sender's Ed25519 identity key.
    let identityKey: [UInt8]
    let ephemeralKey: [UInt8]
    let message: OMEMOAuthenticatedMessage

    init(
        preKeyID: UInt32,
        signedPreKeyID: UInt32,
        identityKey: [UInt8],
        ephemeralKey: [UInt8],
        message: OMEMOAuthenticatedMessage
    ) {
        self.preKeyID = preKeyID
        self.signedPreKeyID = signedPreKeyID
        self.identityKey = identityKey
        self.ephemeralKey = ephemeralKey
        self.message = message
    }

    init(serialized: [UInt8]) throws {
        let fields = try ProtobufFields(decoding: serialized)
        self.preKeyID = try fields.uint32(Field.pkID)
        self.signedPreKeyID = try fields.uint32(Field.spkID)
        self.identityKey = try fields.key(Field.ik, length: OMEMOCrypto.keyLength)
        self.ephemeralKey = try fields.key(Field.ek, length: OMEMOCrypto.keyLength)
        self.message = try OMEMOAuthenticatedMessage(serialized: fields.bytes(Field.message))
    }

    var serialized: [UInt8] {
        var writer = ProtobufWriter()
        writer.append(Field.pkID, preKeyID)
        writer.append(Field.spkID, signedPreKeyID)
        writer.append(Field.ik, identityKey)
        writer.append(Field.ek, ephemeralKey)
        writer.append(Field.message, message.serialized)
        return writer.bytes
    }
}
