import CryptoKit

/// Solves the SHA-256 proof of work a XEP-0158 CAPTCHA form can ask for: an answer, the prefix followed by a decimal
/// counter, whose hex SHA-256 digest ends with the field's label, in either case.
public enum CaptchaProofOfWorkSolver {
    /// The longest label solved. Each further hex digit multiplies the expected work by 16.
    public static let maxLabelDigits = 5
    /// The most attempts made. Keeping the counter below it bounds it to 7 digits.
    public static let maxAttempts = 8_000_000
    /// The longest prefix, in UTF-8 bytes, that keeps every answer within ejabberd's 256-byte limit.
    static let maxPrefixBytes = 249
    /// How many attempts pass between checks for cancellation and the time limit.
    private static let checkInterval = 1024

    /// The answer, or nil when the label is empty, not hex, or longer than `maxLabelDigits`, the prefix is too long,
    /// no answer turned up within `attempts` attempts or `timeLimit`, or the task was cancelled.
    @concurrent
    public static func solve(
        prefix: String, label: String, attempts: Int = maxAttempts, timeLimit: Duration = .seconds(3)
    ) async -> String? {
        let prefixBytes = Array(prefix.utf8)
        guard (1 ... maxLabelDigits).contains(label.count), prefixBytes.count <= maxPrefixBytes,
              let nibbles = hexNibbles(label)
        else { return nil }

        let deadline = ContinuousClock.now + timeLimit
        var candidate = prefixBytes
        for counter in 0 ..< min(attempts, maxAttempts) {
            if counter.isMultiple(of: checkInterval) {
                guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            }
            candidate.removeSubrange(prefixBytes.count...)
            appendDecimal(counter, to: &candidate)
            if digest(of: candidate, endsWith: nibbles) {
                return String(decoding: candidate, as: UTF8.self)
            }
        }
        return nil
    }

    /// The label's hex digits as nibble values, or nil when one is not a hex digit.
    private static func hexNibbles(_ label: String) -> [UInt8]? {
        var nibbles: [UInt8] = []
        for character in label {
            guard character.isASCII, let value = character.hexDigitValue else { return nil }
            nibbles.append(UInt8(value))
        }
        return nibbles
    }

    private static func appendDecimal(_ value: Int, to bytes: inout [UInt8]) {
        let start = bytes.count
        var remaining = value
        repeat {
            bytes.append(UInt8(ascii: "0") + UInt8(remaining % 10))
            remaining /= 10
        } while remaining > 0
        bytes[start...].reverse()
    }

    /// Whether the hex digest's last digits are `nibbles`, compared nibble by nibble so no hex string is built.
    private static func digest(of bytes: [UInt8], endsWith nibbles: [UInt8]) -> Bool {
        let hash = Array(SHA256.hash(data: bytes))
        for (offset, nibble) in nibbles.reversed().enumerated() {
            let byte = hash[hash.count - 1 - offset / 2]
            let digit = offset.isMultiple(of: 2) ? byte & 0x0F : byte >> 4
            guard digit == nibble else { return false }
        }
        return true
    }
}
