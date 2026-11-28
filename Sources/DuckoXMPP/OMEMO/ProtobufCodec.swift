/// Writes fields in the order appended, with minimal varints. Callers append in field-number order, as proto2 encoders
/// write them.
struct ProtobufWriter {
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
struct ProtobufFields {
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

    /// A public key of `length` bytes: 32 for a raw Curve25519 or Ed25519 key, 33 for one after its `0x05` type byte.
    func key(_ field: some RawRepresentable<UInt32>, length: Int) throws -> [UInt8] {
        let value = try bytes(field)
        guard value.count == length else { throw OMEMOModuleError.invalidKeyData }
        return value
    }

    private func only(_ field: some RawRepresentable<UInt32>) throws -> Value {
        guard let occurrences = values[field.rawValue], occurrences.count == 1 else {
            throw OMEMOModuleError.invalidKeyData
        }
        return occurrences[0]
    }
}

struct ProtobufReader {
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

enum WireType {
    static let varint: UInt64 = 0
    static let fixed64: UInt64 = 1
    static let lengthDelimited: UInt64 = 2
    static let fixed32: UInt64 = 5
}
