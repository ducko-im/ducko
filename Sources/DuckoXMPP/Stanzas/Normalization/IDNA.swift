import Darwin
import Foundation

/// IDNA2008 (RFC 5891/5892, RFC 7622 §3.2) domainpart handling.
///
/// `toUnicode` produces the **U-label canonical form** stored in a JID's `.description`;
/// `toASCII` produces the A-label/Punycode form used **only** for DNS/SRV/TLS-SNI lookups.
/// `BareJID.init?` calls `toUnicode`. IP-literal domains (IPv4 dotted-quad, bracketed IPv6)
/// bypass IDNA entirely and are returned identically by both entry points.
enum IDNA {
    private static let maxLabelOctets = 63
    private static let maxDomainOctets = 253
    private static let maxDomainpartOctets = 1023

    /// U-label canonical form (native Unicode); the JID's stored domainpart.
    static func toUnicode(_ domain: String) -> String? {
        process(domain, ascii: false)
    }

    /// A-label/Punycode form for DNS/SRV/TLS lookups only.
    static func toASCII(_ domain: String) -> String? {
        process(domain, ascii: true)
    }

    /// The (U-label stream domain, A-label lookup name) pair for a configured domain, or `nil` if
    /// no A-label can be derived. The stream form is canonical Unicode (for JIDs/stream headers);
    /// the lookup form is the A-label (for DNS/SRV/TLS-SNI).
    static func names(for domain: String) -> (stream: String, lookup: String)? {
        guard let stream = toUnicode(domain), let lookup = toASCII(stream) else { return nil }
        return (stream, lookup)
    }

    // MARK: - Pipeline

    private static func process(_ domain: String, ascii: Bool) -> String? {
        guard !domain.isEmpty else { return nil }

        // (a) Strip a single trailing root dot before any other canonicalization (RFC 7622 §3.2).
        var working = domain
        if working.hasSuffix(".") { working.removeLast() }
        guard !working.isEmpty else { return nil }
        // Bound work up front: a domainpart over the octet cap can never be valid, so reject it
        // before running Punycode decode / NFC on attacker-controlled labels.
        guard working.utf8.count <= maxDomainpartOctets else { return nil }

        // (b) IP-literal fast path (identical under toUnicode/toASCII).
        if working.hasPrefix("[") {
            return processIPv6Literal(working)
        }
        if isValidIPv4(working) {
            return working // digits and dots only; lowercase is a no-op
        }

        // (c) Per-label processing.
        guard let (uLabels, aLabels) = splitLabels(working), bidiContextValid(uLabels) else { return nil }
        guard aLabels.joined(separator: ".").utf8.count <= maxDomainOctets else { return nil }

        let output = ascii
            ? aLabels.joined(separator: ".")
            : uLabels.map { String(String.UnicodeScalarView($0)) }.joined(separator: ".")
        guard output.utf8.count <= maxDomainpartOctets else { return nil }
        return output
    }

    /// Splits and processes each label into (U-label scalars, A-label string) pairs, enforcing the
    /// per-label length limit. Returns `nil` if any label is empty or invalid.
    private static func splitLabels(_ working: String) -> (u: [[Unicode.Scalar]], a: [String])? {
        var uLabels: [[Unicode.Scalar]] = []
        var aLabels: [String] = []
        for raw in working.split(separator: ".", omittingEmptySubsequences: false) {
            guard !raw.isEmpty, let (uLabel, aLabel) = processLabel(raw) else { return nil }
            guard !aLabel.isEmpty, aLabel.utf8.count <= maxLabelOctets else { return nil }
            uLabels.append(uLabel)
            aLabels.append(aLabel)
        }
        return (uLabels, aLabels)
    }

    /// In a Bidi domain name (any RTL label), every label must satisfy the RFC 5893 rule.
    private static func bidiContextValid(_ uLabels: [[Unicode.Scalar]]) -> Bool {
        guard uLabels.contains(where: BidiRule.isRTLLabel) else { return true }
        return uLabels.allSatisfy(BidiRule.satisfies)
    }

    /// Returns a label's (U-label scalars, A-label string), or `nil` if invalid.
    private static func processLabel(_ raw: Substring) -> ([Unicode.Scalar], String)? {
        if raw.unicodeScalars.allSatisfy({ $0.value < 0x80 }) {
            return processASCIILabel(raw.lowercased())
        }
        // RFC 7622 §3.2.2: width-map, then case-map, then NFC (NFC last keeps the U-label idempotent).
        let widthMapped = raw.unicodeScalars.flatMap { UnicodeProperties.widthMapping($0) ?? [$0] }
        let normalized = String(String.UnicodeScalarView(widthMapped)).lowercased().precomposedStringWithCanonicalMapping
        // Width/case mapping can fold a non-ASCII label to pure ASCII (e.g. KELVIN SIGN → "k",
        // fullwidth "Ａ" → "a"); the result is then an LDH label, not an A-label.
        if normalized.unicodeScalars.allSatisfy({ $0.value < 0x80 }) {
            return processASCIILabel(normalized)
        }
        let scalars = Array(normalized.unicodeScalars)
        guard passesStructuralRules(scalars), validate(scalars), let punycode = Punycode.encode(scalars) else { return nil }
        return (scalars, "xn--" + punycode)
    }

    /// Processes an already-lowercased all-ASCII label: an A-label when `xn--`-prefixed, else LDH.
    private static func processASCIILabel(_ lower: String) -> ([Unicode.Scalar], String)? {
        if lower.hasPrefix("xn--") {
            return processALabel(lower)
        }
        guard isValidLDH(lower) else { return nil }
        return (Array(lower.unicodeScalars), lower)
    }

    /// Decodes and re-validates an `xn--` A-label, keeping the U-label (RFC 7622 §3.2.1).
    private static func processALabel(_ lowerLabel: String) -> ([Unicode.Scalar], String)? {
        let suffix = lowerLabel.dropFirst(4)
        guard !suffix.isEmpty, let decoded = Punycode.decode(suffix) else { return nil }
        // An A-label that decodes to pure ASCII is a spoofing vector (e.g. `xn--trusted-` →
        // `trusted`); a real A-label must contain at least one non-ASCII scalar.
        guard decoded.contains(where: { $0.value >= 0x80 }) else { return nil }

        // NFC-stability by scalar identity (String == is canonical-equivalence-based, so it would
        // accept a non-NFC decoded label as "stable").
        let decodedString = String(String.UnicodeScalarView(decoded))
        guard Array(decodedString.precomposedStringWithCanonicalMapping.unicodeScalars) == decoded, passesStructuralRules(decoded), validate(decoded) else { return nil }
        // Re-encode round-trip rejects non-canonical A-labels.
        guard let reencoded = Punycode.encode(decoded), reencoded == suffix else { return nil }
        return (decoded, "xn--" + reencoded)
    }

    // MARK: - Validation

    private static func validate(_ scalars: [Unicode.Scalar]) -> Bool {
        for (index, scalar) in scalars.enumerated() {
            switch UnicodeProperties.idna(scalar) {
            case .pvalid:
                continue
            case .contextj, .contexto:
                if !ContextualRules.satisfied(scalars, at: index) { return false }
            case .disallowed, .unassigned:
                return false
            }
        }
        return true
    }

    private static func isValidLDH(_ label: String) -> Bool {
        let scalars = Array(label.unicodeScalars)
        for scalar in scalars {
            let value = scalar.value
            let isLetter = (0x61 ... 0x7A).contains(value)
            let isDigit = (0x30 ... 0x39).contains(value)
            let isHyphen = value == 0x2D
            guard isLetter || isDigit || isHyphen else { return false }
        }
        return passesStructuralRules(scalars)
    }

    /// RFC 5891 §4.2.3 label-structure rules that apply to every label (ASCII LDH, decoded
    /// A-labels, and non-ASCII U-labels): no leading/trailing hyphen, no `??--` in positions 3–4
    /// (reserved for `xn--`), and no leading combining mark.
    private static func passesStructuralRules(_ scalars: [Unicode.Scalar]) -> Bool {
        guard let first = scalars.first, let last = scalars.last, first.value != 0x2D, last.value != 0x2D else { return false }
        if scalars.count >= 4, scalars[2].value == 0x2D, scalars[3].value == 0x2D { return false }
        switch first.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return false
        default: return true
        }
    }

    // MARK: - IP literals

    private static func processIPv6Literal(_ domain: String) -> String? {
        guard domain.hasSuffix("]") else { return nil }
        let inner = domain.dropFirst().dropLast()

        // RFC 6874 zone-id form `[<addr>%25<zone>]`: the zone-id is a case-sensitive
        // percent-encoded interface name and must be preserved verbatim.
        let address: Substring
        let zone: Substring?
        if let separator = inner.range(of: "%25") {
            address = inner[..<separator.lowerBound]
            zone = inner[separator.upperBound...]
        } else {
            address = inner
            zone = nil
        }

        guard isValidIPv6(String(address)) else { return nil }
        let lowered = address.lowercased()
        if let zone, !zone.isEmpty {
            return "[\(lowered)%25\(zone)]"
        }
        return "[\(lowered)]"
    }

    private static func isValidIPv4(_ string: String) -> Bool {
        var address = in_addr()
        return string.withCString { inet_pton(AF_INET, $0, &address) == 1 }
    }

    private static func isValidIPv6(_ string: String) -> Bool {
        var address = in6_addr()
        return string.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }
}
