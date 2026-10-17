import CryptoKit
import Foundation
import Security

// MARK: - Certificate Signature Hash Algorithm (RFC 5929 §4.1)

/// Hash algorithm to use for `tls-server-end-point` channel binding.
enum CertHashAlgorithm: Equatable {
    case sha256
    case sha384
    case sha512
}

/// Extracts the signature hash algorithm from a DER-encoded X.509 certificate.
///
/// Parses the outer `signatureAlgorithm` OID (after the TBS body) and maps it
/// to the corresponding hash function. Returns `.sha256` as fallback for
/// MD5/SHA-1 signatures or unknown OIDs per RFC 5929 §4.1.
func signatureHashAlgorithm(fromDER der: [UInt8]) -> CertHashAlgorithm {
    // X.509 Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
    // We skip the outer SEQUENCE, skip the TBS SEQUENCE body, then read the OID.
    var offset = 0

    // 1. Outer SEQUENCE
    guard skipTagAndLength(&offset, in: der, expected: 0x30) else { return .sha256 }

    // 2. TBS Certificate SEQUENCE — skip its entire body
    guard skipTagAndBody(&offset, in: der, expected: 0x30) else { return .sha256 }

    // 3. signatureAlgorithm SEQUENCE
    guard skipTagAndLength(&offset, in: der, expected: 0x30) else { return .sha256 }

    // 4. OID inside signatureAlgorithm
    guard offset < der.count, der[offset] == 0x06 else { return .sha256 }
    offset += 1
    guard let oidLength = readDERLength(&offset, in: der),
          offset + oidLength <= der.count else { return .sha256 }
    let oid = Array(der[offset ..< offset + oidLength])

    return hashAlgorithm(forOID: oid)
}

// MARK: DER Parsing Helpers

/// Reads a DER length field starting at `offset`, advancing past it.
private func readDERLength(_ offset: inout Int, in der: [UInt8]) -> Int? {
    guard offset < der.count else { return nil }
    let first = der[offset]
    offset += 1
    if first & 0x80 == 0 {
        return Int(first)
    }
    let numBytes = Int(first & 0x7F)
    guard numBytes > 0, numBytes <= 4, offset + numBytes <= der.count else { return nil }
    var length = 0
    for i in 0 ..< numBytes {
        length = (length << 8) | Int(der[offset + i])
    }
    offset += numBytes
    return length
}

/// Skips past a DER tag byte and its length field, leaving `offset` at the start of the value body.
private func skipTagAndLength(_ offset: inout Int, in der: [UInt8], expected: UInt8) -> Bool {
    guard offset < der.count, der[offset] == expected else { return false }
    offset += 1
    return readDERLength(&offset, in: der) != nil
}

/// Skips past a DER tag byte, its length field, and its entire value body.
private func skipTagAndBody(_ offset: inout Int, in der: [UInt8], expected: UInt8) -> Bool {
    guard offset < der.count, der[offset] == expected else { return false }
    offset += 1
    guard let length = readDERLength(&offset, in: der),
          offset + length <= der.count else { return false }
    offset += length
    return true
}

// MARK: OID → Hash Mapping

/// Maps a DER OID to its hash algorithm. OID families identified by prefix; EdDSA and unknown fall back to SHA-256.
private func hashAlgorithm(forOID oid: [UInt8]) -> CertHashAlgorithm {
    // RSA: 1.2.840.113549.1.1.{11=SHA256, 12=SHA384, 13=SHA512}
    let rsaPrefix: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01]
    if oid.count == rsaPrefix.count + 1, oid.starts(with: rsaPrefix) {
        return hashFromTrailingByte(oid.last, sha256: 0x0B, sha384: 0x0C, sha512: 0x0D)
    }

    // ECDSA: 1.2.840.10045.4.3.{2=SHA256, 3=SHA384, 4=SHA512}
    let ecdsaPrefix: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03]
    if oid.count == ecdsaPrefix.count + 1, oid.starts(with: ecdsaPrefix) {
        return hashFromTrailingByte(oid.last, sha256: 0x02, sha384: 0x03, sha512: 0x04)
    }

    return .sha256
}

/// Maps the trailing OID byte to a hash algorithm using the given per-family byte values.
private func hashFromTrailingByte(_ byte: UInt8?, sha256: UInt8, sha384: UInt8, sha512: UInt8) -> CertHashAlgorithm {
    switch byte {
    case sha256: return .sha256
    case sha384: return .sha384
    case sha512: return .sha512
    default: return .sha256
    }
}

struct CertInfo {
    let subject: String?
    let issuer: String?
    let expiry: Date?
    let sha256: String?
}

func extractCertificateInfo(_ cert: SecCertificate) -> CertInfo? {
    let subject = SecCertificateCopySubjectSummary(cert) as String?

    // Extract certificate DER data for fingerprint
    let derData = SecCertificateCopyData(cert) as Data
    let sha256Hash = SHA256.hash(data: derData)
    let fingerprint = sha256Hash.map { String(format: "%02X", $0) }.joined(separator: ":")

    // Extract issuer and expiry from certificate values
    var issuer: String?
    let expiry = SecCertificateCopyNotValidAfterDate(cert) as Date?
    let issuerKey = kSecOIDX509V1IssuerName as String
    if let values = SecCertificateCopyValues(cert, [issuerKey] as CFArray, nil) as? [String: Any], let issuerEntry = values[issuerKey] as? [String: Any],
       let issuerValue = issuerEntry[kSecPropertyKeyValue as String] {
        issuer = readableDistinguishedName(issuerValue)
    }

    return CertInfo(subject: subject, issuer: issuer, expiry: expiry, sha256: fingerprint)
}

/// Renders a `SecCertificateCopyValues` name as its attribute values, most specific first (e.g. "R11, Let's Encrypt, US").
/// The attribute dictionaries arrive in certificate order, which runs from least to most specific.
func readableDistinguishedName(_ value: Any) -> String? {
    guard let attributes = value as? [[String: Any]] else { return nil }
    let values = attributes.reversed().compactMap { $0[kSecPropertyKeyValue as String] as? String }
    return values.isEmpty ? nil : values.joined(separator: ", ")
}

func certificateChannelBinding(_ cert: SecCertificate) -> [UInt8] {
    let derData = SecCertificateCopyData(cert) as Data
    let derBytes = [UInt8](derData)
    switch signatureHashAlgorithm(fromDER: derBytes) {
    case .sha256: return Array(SHA256.hash(data: derBytes))
    case .sha384: return Array(SHA384.hash(data: derBytes))
    case .sha512: return Array(SHA512.hash(data: derBytes))
    }
}
