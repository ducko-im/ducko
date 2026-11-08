/// What a SCRAM sign-in checks the server's `h` (XEP-0474) and `t` (XEP-0515) attributes against: the offer as it
/// arrived and the TLS version this side negotiated.
struct SCRAMDowngradeContext: Sendable {
    /// Each `<mechanism>` of the SASL profile in use as received: not uppercased, in received order.
    let advertisedMechanisms: [String]
    /// `nil` when the features have no `<sasl-channel-binding>`, and empty when it lists no type.
    let channelBindingTypes: [String]?
    /// The negotiated TLS version's wire code, or `nil` without TLS.
    let tlsVersion: UInt16?

    static let empty = SCRAMDowngradeContext(advertisedMechanisms: [], channelBindingTypes: nil, tlsVersion: nil)
}

/// The string XEP-0474 §6.1 hashes: the mechanisms sorted bytewise (i;octet) and joined by 0x1E. When the features carry
/// `<sasl-channel-binding>`, 0x1F and its sorted types joined by 0x1E follow.
func xep0474HashInput(_ context: SCRAMDowngradeContext) -> [UInt8] {
    var input = joinedSorted(context.advertisedMechanisms)
    if let types = context.channelBindingTypes {
        input.append(0x1F)
        input += joinedSorted(types)
    }
    return input
}

/// The `t` attribute value XEP-0515 gives `version`: its wire code as four lowercase hex digits.
func xep0515VersionAttribute(_ version: UInt16) -> String {
    let digits = String(version, radix: 16)
    return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
}

/// The `<mechanism>` texts of the SASL1 `<mechanisms>` as received.
func advertisedSASL1Mechanisms(_ features: XMLElement) -> [String] {
    features.child(named: "mechanisms", namespace: saslNamespace)?
        .children(named: "mechanism").compactMap(\.textContent) ?? []
}

/// The `<mechanism>` texts of the SASL2 `<authentication>` as received.
func advertisedSASL2Mechanisms(_ features: XMLElement) -> [String] {
    features.child(named: "authentication", namespace: XMPPNamespaces.sasl2)?
        .children(named: "mechanism").compactMap(\.textContent) ?? []
}

/// The channel-binding types `<sasl-channel-binding>` lists as received, or `nil` when the features have none.
func advertisedChannelBindingTypeList(_ features: XMLElement) -> [String]? {
    features.child(named: "sasl-channel-binding", namespace: XMPPNamespaces.saslChannelBinding)
        .map { $0.children(named: "channel-binding").compactMap { $0.attribute("type") } }
}

private func joinedSorted(_ values: [String]) -> [UInt8] {
    let sorted = values.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
    return Array(sorted.joined(separator: [0x1E]))
}
