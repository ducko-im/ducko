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
        self.dhPublicKey = try fields.key(Field.dhPub)
        self.ciphertext = try fields.bytes(Field.ciphertext)
        self.serialized = serialized
    }
}

/// `OMEMOAuthenticatedMessage` (XEP-0384): an `OMEMOMessage` with its truncated MAC.
struct OMEMOAuthenticatedMessage {
    private enum Field: UInt32 {
        case mac = 1
        case message = 2
    }

    static let macLength = 16

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
        self.identityKey = try fields.key(Field.ik)
        self.ephemeralKey = try fields.key(Field.ek)
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

// MARK: - Proto2 Wire Format

/// Writes fields in the order appended, with minimal varints. Callers append in field-number order, as proto2 encoders
/// write them.
private struct ProtobufWriter {
    private(set) var bytes: [UInt8] = []

    mutating func append(_ field: some RawRepresentable<UInt32>, _ value: UInt32) {
        appendVarint(UInt64(field.rawValue) << 3 | WireType.varint)
        appendVarint(UInt64(value))
    }

    mutating func append(_ field: some RawRepresentable<UInt32>, _ value: [UInt8]) {
        appendVarint(UInt64(field.rawValue) << 3 | WireType.lengthDelimited)
        appendVarint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    private mutating func appendVarint(_ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            bytes.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
    }
}

/// The fields of one proto2 message. Unknown fields are skipped; a known field read here must occur exactly once
/// with the wire type its schema gives it. Every malformed input throws `OMEMOModuleError.invalidKeyData`.
private struct ProtobufFields {
    private enum Value {
        case varint(UInt64)
        case lengthDelimited([UInt8])
        case fixedWidth
    }

    private static let maxFieldNumber: UInt64 = (1 << 29) - 1

    private var values: [UInt32: [Value]] = [:]

    init(decoding bytes: [UInt8]) throws {
        var reader = ProtobufReader(bytes: bytes)
        while !reader.isAtEnd {
            let tag = try reader.readVarint()
            let fieldNumber = tag >> 3
            guard fieldNumber > 0, fieldNumber <= Self.maxFieldNumber else { throw OMEMOModuleError.invalidKeyData }
            let value: Value
            switch tag & 0x7 {
            case WireType.varint:
                value = try .varint(reader.readVarint())
            case WireType.fixed64:
                _ = try reader.read(count: 8)
                value = .fixedWidth
            case WireType.lengthDelimited:
                value = try .lengthDelimited(reader.read(count: reader.readVarint()))
            case WireType.fixed32:
                _ = try reader.read(count: 4)
                value = .fixedWidth
            default:
                // Groups (3, 4) are deprecated and no OMEMO encoder writes them; 6 and 7 are not wire types.
                throw OMEMOModuleError.invalidKeyData
            }
            values[UInt32(fieldNumber), default: []].append(value)
        }
    }

    func uint32(_ field: some RawRepresentable<UInt32>) throws -> UInt32 {
        guard case let .varint(value) = try only(field), let result = UInt32(exactly: value) else {
            throw OMEMOModuleError.invalidKeyData
        }
        return result
    }

    func bytes(_ field: some RawRepresentable<UInt32>) throws -> [UInt8] {
        guard case let .lengthDelimited(value) = try only(field) else { throw OMEMOModuleError.invalidKeyData }
        return value
    }

    /// A 32-byte Curve25519 or Ed25519 public key.
    func key(_ field: some RawRepresentable<UInt32>) throws -> [UInt8] {
        let value = try bytes(field)
        guard value.count == OMEMOCrypto.keyLength else { throw OMEMOModuleError.invalidKeyData }
        return value
    }

    private func only(_ field: some RawRepresentable<UInt32>) throws -> Value {
        guard let occurrences = values[field.rawValue], occurrences.count == 1 else {
            throw OMEMOModuleError.invalidKeyData
        }
        return occurrences[0]
    }
}

private struct ProtobufReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool {
        offset == bytes.count
    }

    /// A base-128 varint of at most 10 bytes whose value fits 64 bits.
    mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        for index in 0 ..< 10 {
            guard offset < bytes.count else { throw OMEMOModuleError.invalidKeyData }
            let byte = bytes[offset]
            offset += 1
            guard index < 9 || byte <= 1 else { throw OMEMOModuleError.invalidKeyData }
            value |= UInt64(byte & 0x7F) << (7 * index)
            if byte & 0x80 == 0 { return value }
        }
        throw OMEMOModuleError.invalidKeyData
    }

    mutating func read(count: UInt64) throws -> [UInt8] {
        guard count <= UInt64(bytes.count - offset) else { throw OMEMOModuleError.invalidKeyData }
        let end = offset + Int(count)
        defer { offset = end }
        return Array(bytes[offset ..< end])
    }
}

private enum WireType {
    static let varint: UInt64 = 0
    static let fixed64: UInt64 = 1
    static let lengthDelimited: UInt64 = 2
    static let fixed32: UInt64 = 5
}
