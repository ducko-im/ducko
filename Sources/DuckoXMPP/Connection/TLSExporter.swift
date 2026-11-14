import CryptoKit
import NIOCore

// swift-nio-ssl exposes no keying-material exporter (the open apple/swift-nio-ssl#595 would add one), so the
// `tls-exporter` binding is derived from the TLS 1.3 exporter secret that BoringSSL hands to the key-log callback during
// the handshake. Once swift-nio-ssl ships an exporter, a call to it after the handshake replaces both the key-log
// capture and this file's derivation.
//
// The key-log hook leaves short-lived copies of every TLS secret that Ducko cannot wipe: BoringSSL's hex line and the
// buffer swift-nio-ssl copies it into, including the traffic secrets this side discards. Whoever can read process memory
// already has the same secrets in BoringSSL's state.

/// What one key-log line says about the exporter secret.
enum KeyLogExporterLine: Equatable {
    /// A line for another secret.
    case notExporter
    case exporter([UInt8])
    /// An exporter line that does not have the expected shape.
    case malformed
}

/// What the key-log lines of one handshake left of its exporter secret. Only a single well-formed exporter line is
/// usable: a second one or a malformed one makes the capture unusable for good.
enum ExporterSecretCapture: Equatable {
    case none
    case captured([UInt8])
    case unusable

    mutating func record(_ line: KeyLogExporterLine) {
        switch (self, line) {
        case (_, .notExporter), (.unusable, .exporter):
            break
        case let (.none, .exporter(secret)):
            self = .captured(secret)
        case (.captured, .exporter), (_, .malformed):
            self = .unusable
        }
    }
}

private let exporterLabel = Array("EXPORTER_SECRET".utf8)
private let space = UInt8(ascii: " ")
private let clientRandomHexDigits = 64

/// Reads a key-log line, `<label> <client random hex> <secret hex>` with an optional trailing newline, for the
/// exporter secret.
func exporterSecret(fromKeyLogLine line: ByteBuffer) -> KeyLogExporterLine {
    var body = line.readableBytesView
    if body.last == UInt8(ascii: "\n") { body = body.dropLast() }
    let labelEnd = body.firstIndex(of: space) ?? body.endIndex
    guard body[..<labelEnd].elementsEqual(exporterLabel) else { return .notExporter }
    let fields = body[labelEnd...].split(separator: space, omittingEmptySubsequences: false)
    guard fields.count == 3, fields[0].isEmpty,
          fields[1].count == clientRandomHexDigits, fields[1].allSatisfy({ hexValue($0) != nil }),
          let secret = decodeHex(fields[2]), !secret.isEmpty else {
        return .malformed
    }
    return .exporter(secret)
}

/// The RFC 9266 `tls-exporter` binding: 32 bytes of the RFC 8446 §7.5 exporter with the label
/// `EXPORTER-Channel-Binding` and no context. The secret's length names the cipher suite's hash, and any length but
/// SHA-256's or SHA-384's gives `nil`.
func tlsExporterChannelBinding(exporterSecret: [UInt8]) -> [UInt8]? {
    switch exporterSecret.count {
    case SHA256.byteCount: exportedChannelBinding(SHA256.self, secret: exporterSecret)
    case SHA384.byteCount: exportedChannelBinding(SHA384.self, secret: exporterSecret)
    default: nil
    }
}

/// The bindings a completed handshake gives: always `tls-server-end-point`, and `tls-exporter` on TLS 1.3 when the
/// handshake left exactly one usable exporter secret.
func handshakeBindings(serverEndPoint: [UInt8], capture: ExporterSecretCapture, isTLS13: Bool) -> [ChannelBindingType: [UInt8]] {
    var bindings: [ChannelBindingType: [UInt8]] = [.tlsServerEndPoint: serverEndPoint]
    if isTLS13, case let .captured(secret) = capture, let exporter = tlsExporterChannelBinding(exporterSecret: secret) {
        bindings[.tlsExporter] = exporter
    }
    return bindings
}

private func exportedChannelBinding<H: HashFunction>(_: H.Type, secret: [UInt8]) -> [UInt8] {
    let emptyHash = Array(H.hash(data: [UInt8]()))
    let derived = hkdfExpandLabel(H.self, secret: secret, label: "EXPORTER-Channel-Binding", context: emptyHash, length: H.Digest.byteCount)
    return hkdfExpandLabel(H.self, secret: derived, label: "exporter", context: emptyHash, length: 32)
}

/// HKDF-Expand-Label (RFC 8446 §7.1).
private func hkdfExpandLabel<H: HashFunction>(_: H.Type, secret: [UInt8], label: String, context: [UInt8], length: Int) -> [UInt8] {
    let fullLabel = Array("tls13 \(label)".utf8)
    let info = [UInt8(length >> 8), UInt8(length & 0xFF), UInt8(fullLabel.count)] + fullLabel + [UInt8(context.count)] + context
    return HKDF<H>.expand(pseudoRandomKey: secret, info: info, outputByteCount: length).withUnsafeBytes { Array($0) }
}

private func decodeHex(_ digits: some Collection<UInt8>) -> [UInt8]? {
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

private func hexValue(_ digit: UInt8) -> UInt8? {
    switch digit {
    case UInt8(ascii: "0") ... UInt8(ascii: "9"): digit - UInt8(ascii: "0")
    case UInt8(ascii: "a") ... UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A") ... UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
    default: nil
    }
}
