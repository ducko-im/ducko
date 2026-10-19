import CryptoKit

/// XEP-0392 Consistent Color Generation — computes a hue angle from a string identifier.
///
/// Algorithm: SHA-1 hash the UTF-8 bytes, read the hash as little endian, take its
/// least-significant 16 bits, and map them to 0..<360 degrees.
public enum ConsistentColorHue {
    public static func hue(for identifier: String) -> Double {
        let hash = Insecure.SHA1.hash(data: Array(identifier.utf8))
        let bytes = Array(hash)
        let lsb = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        return Double(lsb) / 65536.0 * 360.0
    }
}
