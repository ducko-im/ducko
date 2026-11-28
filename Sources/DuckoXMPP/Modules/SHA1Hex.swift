import CryptoKit

/// Computes the SHA-1 hash of the given data and returns a lowercase hex string.
public func sha1Hex(_ data: [UInt8]) -> String {
    hexString(Insecure.SHA1.hash(data: data))
}

/// Renders bytes as a lowercase hex string.
func hexString(_ bytes: some Sequence<UInt8>) -> String {
    bytes
        .map { byte in
            byte < 16 ? "0" + String(byte, radix: 16) : String(byte, radix: 16)
        }
        .joined()
}

/// Reads ASCII hex digits of either case as bytes, or nil on an odd count or a non-hex digit.
package func decodeHex(_ digits: some Collection<UInt8>) -> [UInt8]? {
    guard digits.count.isMultiple(of: 2) else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(digits.count / 2)
    var high: UInt8?
    for digit in digits {
        guard let value = hexValue(digit) else { return nil }
        if let pending = high {
            bytes.append(pending << 4 | value)
            high = nil
        } else {
            high = value
        }
    }
    return bytes
}

func hexValue(_ digit: UInt8) -> UInt8? {
    switch digit {
    case UInt8(ascii: "0") ... UInt8(ascii: "9"): digit - UInt8(ascii: "0")
    case UInt8(ascii: "a") ... UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A") ... UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
    default: nil
    }
}
