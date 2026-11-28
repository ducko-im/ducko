/// A legacy OMEMO Double Ratchet message (libsignal's `SignalMessage`): the version byte `0x33`, the protobuf, and
/// the 8-byte truncated MAC over the associated data and both.
package struct OMEMOLegacyMessage {
    /// The version byte and the protobuf, the part of the message its MAC covers.
    struct Content {
        private enum Field: UInt32 {
            case dhPub = 1
            case n = 2
            case pn = 3
            case ciphertext = 4
        }

        let messageNumber: UInt32
        let previousChainCount: UInt32
        /// The sender's current ratchet public key (32 bytes), without the `0x05` type byte it travels with.
        let dhPublicKey: [UInt8]
        /// Optional in the schema, but a message without it has nothing to decrypt, so decoding requires it.
        let ciphertext: [UInt8]
        /// The content in its wire encoding, made once. The MAC covers these exact bytes, so a decoded message keeps
        /// the bytes it arrived as.
        let serialized: [UInt8]

        init(messageNumber: UInt32, previousChainCount: UInt32, dhPublicKey: [UInt8], ciphertext: [UInt8]) {
            self.messageNumber = messageNumber
            self.previousChainCount = previousChainCount
            self.dhPublicKey = dhPublicKey
            self.ciphertext = ciphertext
            var writer = ProtobufWriter()
            writer.appendLegacyKey(Field.dhPub, dhPublicKey)
            writer.append(Field.n, messageNumber)
            writer.append(Field.pn, previousChainCount)
            writer.append(Field.ciphertext, ciphertext)
            self.serialized = [legacyVersion] + writer.bytes
        }

        init(serialized: [UInt8]) throws {
            let fields = try ProtobufFields(decoding: legacyProtobuf(in: serialized))
            self.dhPublicKey = try fields.legacyKey(Field.dhPub)
            self.messageNumber = try fields.uint32(Field.n)
            self.previousChainCount = try fields.uint32(Field.pn)
            self.ciphertext = try fields.bytes(Field.ciphertext)
            self.serialized = serialized
        }
    }

    static let macLength = OMEMOWireFormat.legacy.macLength

    let content: Content
    let mac: [UInt8]

    init(content: Content, mac: [UInt8]) {
        self.content = content
        self.mac = mac
    }

    package init(serialized: [UInt8]) throws {
        guard serialized.count > Self.macLength else { throw OMEMOModuleError.invalidKeyData }
        self.content = try Content(serialized: Array(serialized.dropLast(Self.macLength)))
        self.mac = Array(serialized.suffix(Self.macLength))
    }

    var serialized: [UInt8] {
        content.serialized + mac
    }
}

/// A legacy OMEMO key exchange (libsignal's `PreKeySignalMessage`): the version byte `0x33` and the protobuf holding
/// the X3DH values that start a session around its first message.
///
/// Field 5 is libsignal's registration id. Ducko has no use for it and does not write it, as the reference stack
/// does not, and decoding skips it as an unknown field.
struct OMEMOLegacyKeyExchange {
    private enum Field: UInt32 {
        case pkID = 1
        case ek = 2
        case ik = 3
        case message = 4
        case spkID = 6
    }

    let preKeyID: UInt32
    let signedPreKeyID: UInt32
    /// The sender's Curve25519 identity key (32 bytes), without the `0x05` type byte it travels with.
    let identityKey: [UInt8]
    /// The sender's ephemeral key (32 bytes), without the `0x05` type byte it travels with.
    let ephemeralKey: [UInt8]
    let message: OMEMOLegacyMessage

    init(
        preKeyID: UInt32,
        signedPreKeyID: UInt32,
        identityKey: [UInt8],
        ephemeralKey: [UInt8],
        message: OMEMOLegacyMessage
    ) {
        self.preKeyID = preKeyID
        self.signedPreKeyID = signedPreKeyID
        self.identityKey = identityKey
        self.ephemeralKey = ephemeralKey
        self.message = message
    }

    init(serialized: [UInt8]) throws {
        let fields = try ProtobufFields(decoding: legacyProtobuf(in: serialized))
        self.preKeyID = try fields.uint32(Field.pkID)
        self.signedPreKeyID = try fields.uint32(Field.spkID)
        self.identityKey = try fields.legacyKey(Field.ik)
        self.ephemeralKey = try fields.legacyKey(Field.ek)
        self.message = try OMEMOLegacyMessage(serialized: fields.bytes(Field.message))
    }

    var serialized: [UInt8] {
        var writer = ProtobufWriter()
        writer.append(Field.pkID, preKeyID)
        writer.appendLegacyKey(Field.ek, ephemeralKey)
        writer.appendLegacyKey(Field.ik, identityKey)
        writer.append(Field.message, message.serialized)
        writer.append(Field.spkID, signedPreKeyID)
        return [legacyVersion] + writer.bytes
    }
}

// MARK: - Legacy Framing

/// The byte before every legacy protobuf: libsignal's message version 3 in both halves.
private let legacyVersion: UInt8 = 0x33

/// The type byte before every legacy public key: libsignal's Curve25519 key type.
let legacyKeyType: UInt8 = 0x05

/// The protobuf after the version byte, which must be `legacyVersion`.
private func legacyProtobuf(in serialized: [UInt8]) throws -> [UInt8] {
    guard serialized.first == legacyVersion else { throw OMEMOModuleError.invalidKeyData }
    return Array(serialized.dropFirst())
}

private extension ProtobufWriter {
    mutating func appendLegacyKey(_ field: some RawRepresentable<UInt32>, _ key: [UInt8]) {
        append(field, [legacyKeyType] + key)
    }
}

private extension ProtobufFields {
    /// A 32-byte Curve25519 key that travels after its `0x05` type byte, returned without it.
    func legacyKey(_ field: some RawRepresentable<UInt32>) throws -> [UInt8] {
        let value = try key(field, length: OMEMOCrypto.keyLength + 1)
        guard value[0] == legacyKeyType else { throw OMEMOModuleError.invalidKeyData }
        return Array(value.dropFirst())
    }
}
