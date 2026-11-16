/// One XEP-0231 Bits of Binary item: data a stanza carries inline, named by its content ID.
public struct BitsOfBinaryData: Sendable, Equatable {
    /// The content ID a `cid:` URI names the data by.
    public let cid: String
    public let type: String
    public let bytes: [UInt8]

    /// The most decoded bytes one item may hold.
    static let maxBytes = 256 * 1024

    public init(cid: String, type: String, bytes: [UInt8]) {
        self.cid = cid
        self.type = type
        self.bytes = bytes
    }

    /// Parses a `<data xmlns='urn:xmpp:bob'>` element, or returns nil for one without a `cid` or `type`, with base64
    /// that isn't strict, or holding more than `maxBytes`.
    static func parse(_ element: XMLElement) -> BitsOfBinaryData? {
        guard element.name == "data", element.namespace == XMPPNamespaces.bitsOfBinary,
              let cid = element.attribute("cid"), let type = element.attribute("type")
        else { return nil }
        let text = element.textContent ?? ""
        // Pre-check the encoded length (base64 expands ~4/3) before decoding.
        guard text.utf8.count <= maxBytes / 3 * 4 + 4,
              let bytes = Base64.decodeStrict(text), bytes.count <= maxBytes
        else { return nil }
        return BitsOfBinaryData(cid: cid, type: type, bytes: bytes)
    }
}

/// XEP-0231 Bits of Binary — advertises support via disco#info.
///
/// Ducko reads only data a stanza carries inline and holds none of its own, so a request for data gets the client's
/// default `service-unavailable` reply.
public final class BitsOfBinaryModule: XMPPModule, Sendable {
    public var features: [String] {
        [XMPPNamespaces.bitsOfBinary]
    }

    public init() {}

    public func setUp(_ context: ModuleContext) {}
}
