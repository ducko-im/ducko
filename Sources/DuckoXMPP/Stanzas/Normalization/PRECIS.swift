import Foundation

/// PRECIS string-class enforcement (RFC 8264) for the two JID slots that need it:
/// `UsernameCaseMapped` (RFC 8265 §3) for localparts and `OpaqueString` (RFC 8265 §4) for
/// resourceparts. Both return `nil` on any disallowed code point, contextual-rule failure, empty
/// result, or over-length result; `usernameCaseMapped` additionally enforces the Bidi rule, while
/// `OpaqueString` has no directionality rule (RFC 8265 §4.2.2).
enum PRECIS {
    /// Maximum octet length of a localpart/resourcepart (RFC 6122 / RFC 7622).
    private static let maxOctets = 1023

    /// RFC 8265 §3.3 — width-map, validate, lowercase, NFC, Bidi, then re-validate.
    static func usernameCaseMapped(_ string: String) -> String? {
        let widthMapped = applyWidthMapping(string)
        // Pre-mapping pass only rejects DISALLOWED/UNASSIGNED (catches HasCompat singletons like
        // OHM SIGN that lowercase to PVALID). Contextual rules are positional and case-sensitive,
        // so they are evaluated only on the final form below (RFC 8264 §7).
        guard validate(widthMapped, freeform: false, checkContextual: false) else { return nil }

        let lowered = String(String.UnicodeScalarView(widthMapped)).lowercased()
        let normalized = lowered.precomposedStringWithCanonicalMapping
        let scalars = Array(normalized.unicodeScalars)

        if BidiRule.isRTLLabel(scalars), !BidiRule.satisfies(scalars) { return nil }

        guard validate(scalars, freeform: false, checkContextual: true), !scalars.isEmpty, normalized.utf8.count <= maxOctets else { return nil }
        return normalized
    }

    /// RFC 8265 §4.3 — map non-ASCII spaces to U+0020, NFC, then validate (case preserved).
    static func opaqueString(_ string: String) -> String? {
        let spaceMapped = string.unicodeScalars.map { scalar -> Unicode.Scalar in
            scalar.properties.generalCategory == .spaceSeparator && scalar.value != 0x20
                ? Unicode.Scalar(0x20)! : scalar
        }
        let normalized = String(String.UnicodeScalarView(spaceMapped)).precomposedStringWithCanonicalMapping
        let scalars = Array(normalized.unicodeScalars)

        guard validate(scalars, freeform: true, checkContextual: true), !scalars.isEmpty, normalized.utf8.count <= maxOctets else { return nil }
        return normalized
    }

    // MARK: - Private

    private static func applyWidthMapping(_ string: String) -> [Unicode.Scalar] {
        var result: [Unicode.Scalar] = []
        for scalar in string.unicodeScalars {
            if let mapped = UnicodeProperties.widthMapping(scalar) {
                result.append(contentsOf: mapped)
            } else {
                result.append(scalar)
            }
        }
        return result
    }

    private static func validate(_ scalars: [Unicode.Scalar], freeform: Bool, checkContextual: Bool) -> Bool {
        for (index, scalar) in scalars.enumerated() {
            let property = freeform
                ? UnicodeProperties.freeformClass(scalar)
                : UnicodeProperties.identifierClass(scalar)
            switch property {
            case .pvalid:
                continue
            case .contextj, .contexto:
                if checkContextual, !ContextualRules.satisfied(scalars, at: index) { return false }
            case .disallowed, .unassigned:
                return false
            }
        }
        return true
    }
}
