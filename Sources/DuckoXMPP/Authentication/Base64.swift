/// Standalone base64 encode/decode using only the Swift stdlib (no Foundation).
enum Base64 {
    private static let eq = UInt8(ascii: "=")

    private static let encodeTable: [UInt8] = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
    )

    /// Decoding lookup: ASCII value → 6-bit value, or 0xFF for invalid.
    private static let decodeTable: [UInt8] = {
        var table = [UInt8](repeating: 0xFF, count: 256)
        for (i, byte) in encodeTable.enumerated() {
            table[Int(byte)] = UInt8(i)
        }
        return table
    }()

    // MARK: - Encode

    static func encode(_ bytes: [UInt8]) -> String {
        var result: [UInt8] = []
        result.reserveCapacity((bytes.count + 2) / 3 * 4)

        var i = 0
        while i + 2 < bytes.count {
            let b0 = bytes[i], b1 = bytes[i + 1], b2 = bytes[i + 2]
            result.append(encodeTable[Int(b0 >> 2)])
            result.append(encodeTable[Int((b0 & 0x03) << 4 | b1 >> 4)])
            result.append(encodeTable[Int((b1 & 0x0F) << 2 | b2 >> 6)])
            result.append(encodeTable[Int(b2 & 0x3F)])
            i += 3
        }

        let remaining = bytes.count - i
        if remaining == 1 {
            let b0 = bytes[i]
            result.append(encodeTable[Int(b0 >> 2)])
            result.append(encodeTable[Int((b0 & 0x03) << 4)])
            result.append(eq)
            result.append(eq)
        } else if remaining == 2 {
            let b0 = bytes[i], b1 = bytes[i + 1]
            result.append(encodeTable[Int(b0 >> 2)])
            result.append(encodeTable[Int((b0 & 0x03) << 4 | b1 >> 4)])
            result.append(encodeTable[Int((b1 & 0x0F) << 2)])
            result.append(eq)
        }

        return String(decoding: result, as: UTF8.self)
    }

    static func encode(_ string: String) -> String {
        encode(Array(string.utf8))
    }

    // MARK: - Decode

    static func decode(_ string: String) -> [UInt8]? {
        var input: [UInt8] = []
        input.reserveCapacity(string.utf8.count)
        for byte in string.utf8 {
            // Skip whitespace (CR, LF, space, tab)
            if byte == 0x0D || byte == 0x0A || byte == 0x20 || byte == 0x09 { continue }
            input.append(byte)
        }
        return decode(input)
    }

    /// Decodes base64 that holds nothing outside the alphabet and padding, not even whitespace, as XEP-0047 §10 requires
    /// of IBB data.
    static func decodeStrict(_ string: String) -> [UInt8]? {
        decode(Array(string.utf8))
    }

    private static func decode(_ input: [UInt8]) -> [UInt8]? {
        guard input.count % 4 == 0 else { return nil }
        if input.isEmpty { return [] }

        // Count padding from the end
        var paddingCount = 0
        if input[input.count - 1] == eq { paddingCount += 1 }
        if input.count >= 2, input[input.count - 2] == eq { paddingCount += 1 }

        var result: [UInt8] = []
        result.reserveCapacity(input.count / 4 * 3 - paddingCount)

        let lastQuartetStart = input.count - 4
        var i = 0
        while i < input.count {
            guard let bytes = decodeQuartet(
                input[i], input[i + 1], input[i + 2], input[i + 3],
                isLastQuartet: i == lastQuartetStart
            ) else { return nil }
            result.append(contentsOf: bytes)
            i += 4
        }

        return result
    }

    /// Decodes a single 4-character quartet into 1-3 output bytes, or `nil` on invalid input.
    private static func decodeQuartet(
        _ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8,
        isLastQuartet: Bool
    ) -> [UInt8]? {
        // Padding is only valid in the final quartet
        if !isLastQuartet, b2 == eq || b3 == eq { return nil }

        // If 3rd char is padding, 4th must also be padding
        if b2 == eq, b3 != eq { return nil }

        let c0 = decodeTable[Int(b0)]
        let c1 = decodeTable[Int(b1)]
        let c2 = b2 == eq ? UInt8(0) : decodeTable[Int(b2)]
        let c3 = b3 == eq ? UInt8(0) : decodeTable[Int(b3)]

        if c0 == 0xFF || c1 == 0xFF { return nil }
        if b2 != eq, c2 == 0xFF { return nil }
        if b3 != eq, c3 == 0xFF { return nil }

        var bytes: [UInt8] = [c0 << 2 | c1 >> 4]
        if b2 != eq { bytes.append((c1 & 0x0F) << 4 | c2 >> 2) }
        if b3 != eq { bytes.append((c2 & 0x03) << 6 | c3) }
        return bytes
    }

    /// Decodes a base64 string to a UTF-8 string, or `nil` if invalid.
    static func decodeString(_ string: String) -> String? {
        guard let bytes = decode(string) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
