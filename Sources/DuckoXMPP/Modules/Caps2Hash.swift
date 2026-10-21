import CryptoKit

/// Hash algorithms supported by XEP-0390 Entity Capabilities 2.0.
enum Caps2HashAlgorithm: String, CaseIterable {
    case sha256 = "sha-256"
    case sha512 = "sha-512"

    func hash(_ data: [UInt8]) -> [UInt8] {
        switch self {
        case .sha256: Array(SHA256.hash(data: data))
        case .sha512: Array(SHA512.hash(data: data))
        }
    }
}

extension String {
    /// Whether the string sorts before `other` in the i;octet collation (RFC 4790 §9.3), which both caps hashes sort
    /// by. It compares UTF-8 bytes, where `String`'s `<` compares normalized Unicode scalars.
    func octetPrecedes(_ other: String) -> Bool {
        utf8.lexicographicallyPrecedes(other.utf8)
    }
}

extension Sequence<String> {
    /// The strings in i;octet order.
    func octetSorted() -> [String] {
        sorted { $0.octetPrecedes($1) }
    }
}

/// XEP-0390 capability hash input generation.
///
/// Uses ASCII control characters as delimiters per XEP-0390 §5.2:
/// - `0x1f` (Unit Separator): terminates individual attribute values
/// - `0x1e` (Record Separator): terminates complete identities
/// - `0x1d` (Group Separator): terminates form sections within extensions
/// - `0x1c` (File Separator): terminates each major section
enum Caps2Hash {
    /// Generates the XEP-0390 capability hash input bytes.
    static func generateHashInput(
        identities: [ServiceDiscoveryModule.Identity],
        features: Set<String>,
        forms: [[DataFormField]] = []
    ) -> [UInt8] {
        var result: [UInt8] = []

        // Features section: sort by i;octet (byte-wise), each terminated by 0x1f
        for feature in features.octetSorted() {
            result.append(contentsOf: Array(feature.utf8))
            result.append(0x1F)
        }
        result.append(0x1C)

        // Identities section: encode each as category 0x1f type 0x1f lang 0x1f name 0x1f 0x1e
        // Sort the concatenated identity byte strings by i;octet
        let identityBytes: [[UInt8]] = identities.map { identity in
            var bytes: [UInt8] = []
            bytes.append(contentsOf: Array(identity.category.utf8))
            bytes.append(0x1F)
            bytes.append(contentsOf: Array(identity.type.utf8))
            bytes.append(0x1F)
            bytes.append(contentsOf: Array(identity.lang.utf8))
            bytes.append(0x1F)
            bytes.append(contentsOf: Array((identity.name ?? "").utf8))
            bytes.append(0x1F)
            bytes.append(0x1E)
            return bytes
        }
        for bytes in identityBytes.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            result.append(contentsOf: bytes)
        }
        result.append(0x1C)

        // Extensions section: encode data forms per XEP-0390 §5.2
        encodeFormsSection(forms, into: &result)
        result.append(0x1C)

        return result
    }

    /// Encodes data forms into the extensions section per XEP-0390 §4.1.
    ///
    /// FORM_TYPE is treated as a regular field (encoded with var + values + 0x1e).
    /// Fields within each form are sorted by byte representation.
    /// Forms are sorted by byte representation (FORM_TYPE sorts early as uppercase).
    private static func encodeFormsSection(_ forms: [[DataFormField]], into result: inout [UInt8]) {
        // Only include forms that have a FORM_TYPE field
        let validForms = forms.filter { fields in
            fields.contains { $0.variable == "FORM_TYPE" }
        }

        // Encode each form: all fields as var 0x1f values 0x1f 0x1e, sorted, then 0x1d
        var encodedForms: [[UInt8]] = validForms.map { fields in
            encodeForm(fields)
        }
        encodedForms.sort { $0.lexicographicallyPrecedes($1) }

        for formBytes in encodedForms {
            result.append(contentsOf: formBytes)
        }
    }

    private static func encodeForm(_ fields: [DataFormField]) -> [UInt8] {
        var encodedFields: [[UInt8]] = fields.compactMap { field in
            guard let variable = field.variable else { return nil }
            var bytes: [UInt8] = []
            bytes.append(contentsOf: Array(variable.utf8))
            bytes.append(0x1F)
            for value in field.values.octetSorted() {
                bytes.append(contentsOf: Array(value.utf8))
                bytes.append(0x1F)
            }
            bytes.append(0x1E)
            return bytes
        }
        encodedFields.sort { $0.lexicographicallyPrecedes($1) }

        var formBytes: [UInt8] = []
        for fieldBytes in encodedFields {
            formBytes.append(contentsOf: fieldBytes)
        }
        formBytes.append(0x1D)
        return formBytes
    }
}
