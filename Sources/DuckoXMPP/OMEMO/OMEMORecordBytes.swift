/// Writes a stored OMEMO record, such as a session and its ratchet: raw bytes and little-endian 32-bit numbers.
struct OMEMORecordWriter {
    private(set) var bytes: [UInt8] = []

    mutating func append(_ value: some Sequence<UInt8>) {
        bytes.append(contentsOf: value)
    }

    mutating func append(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func append(_ value: UInt32) {
        bytes.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }
}

/// Reads a record `OMEMORecordWriter` wrote, front to back. Reading past its end throws `invalidKeyData`.
struct OMEMORecordReader {
    private var remaining: ArraySlice<UInt8>

    init(_ bytes: [UInt8]) {
        self.remaining = bytes[...]
    }

    var isAtEnd: Bool {
        remaining.isEmpty
    }

    mutating func read(_ count: Int) throws -> [UInt8] {
        guard remaining.count >= count else { throw OMEMOModuleError.invalidKeyData }
        defer { remaining = remaining.dropFirst(count) }
        return Array(remaining.prefix(count))
    }

    mutating func readByte() throws -> UInt8 {
        try read(1)[0]
    }

    mutating func readUInt32() throws -> UInt32 {
        try read(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Everything not read yet, which leaves nothing to read.
    mutating func readRest() -> [UInt8] {
        defer { remaining = [] }
        return Array(remaining)
    }
}
