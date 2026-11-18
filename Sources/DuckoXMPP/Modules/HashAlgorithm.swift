import CryptoKit

/// XEP-0300 hash functions Ducko computes and verifies.
enum HashAlgorithm: String, CaseIterable {
    case sha256 = "sha-256"
    case sha512 = "sha-512"

    /// The disco feature that advertises support for this algorithm (XEP-0300 §4).
    var feature: String {
        "urn:xmpp:hash-function-text-names:\(rawValue)"
    }

    /// Ranks the algorithms for `preferredHash(in:)`; higher is stronger.
    private var strength: Int {
        switch self {
        case .sha256: 0
        case .sha512: 1
        }
    }

    func hash(_ data: [UInt8]) -> [UInt8] {
        switch self {
        case .sha256: Array(SHA256.hash(data: data))
        case .sha512: Array(SHA512.hash(data: data))
        }
    }

    /// The `urn:xmpp:hashes:2` `<hash>` children of `element`.
    static func hashElements(in element: XMLElement) -> [XMLElement] {
        element.children(named: "hash").filter { $0.namespace == XMPPNamespaces.hashes2 }
    }

    /// The `urn:xmpp:hashes:2` `<hash>` child of `element` with the strongest supported algorithm. When none is
    /// supported, the first such child, so the caller can report its algorithm as unsupported.
    static func preferredHash(in element: XMLElement) -> XMLElement? {
        let hashes = hashElements(in: element)
        let supported = hashes.compactMap { hash in
            hash.attribute("algo").flatMap(HashAlgorithm.init(rawValue:)).map { (algorithm: $0, element: hash) }
        }
        let strongest = supported.max { $0.algorithm.strength < $1.algorithm.strength }
        return strongest?.element ?? hashes.first
    }
}
