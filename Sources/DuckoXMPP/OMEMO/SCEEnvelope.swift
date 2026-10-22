/// A Stanza Content Encryption envelope (XEP-0420): the elements a message encrypts, and the affixes that bind them to
/// the stanza that carries them.
struct SCEEnvelope {
    /// The encrypted elements, as the stanza would carry them in the clear.
    let content: [XMLElement]
    /// The `time` affix's stamp, as the sender wrote it.
    let time: String?
    /// Nil when the envelope has no `to` affix.
    let to: BareJID?
    /// Nil when the envelope has no `from` affix.
    let from: BareJID?

    /// How long content and padding are together at least, so a short message does not give its length away.
    static let minimumPaddedLength = 200
    /// The most padding added past that minimum.
    static let maximumRandomPadding = 200

    /// The envelope as it is encrypted. A content element in no namespace is a stanza child, so it is written in the
    /// client namespace rather than the envelope's.
    static func build(content: [XMLElement], time: String, to: BareJID, from: BareJID) -> [UInt8] {
        var contentElement = XMLElement(name: "content")
        for var element in content {
            if element.namespace == nil {
                element.namespace = XMPPNamespaces.client
            }
            contentElement.addChild(element)
        }
        var envelope = XMLElement(name: "envelope", namespace: XMPPNamespaces.sce)
        envelope.addChild(contentElement)
        var rpad = XMLElement(name: "rpad")
        rpad.addText(padding(after: contentElement.xmlString.utf8.count))
        envelope.addChild(rpad)
        envelope.addChild(XMLElement(name: "time", attributes: ["stamp": time]))
        envelope.addChild(XMLElement(name: "to", attributes: ["jid": to.description]))
        envelope.addChild(XMLElement(name: "from", attributes: ["jid": from.description]))
        return Array(envelope.xmlString.utf8)
    }

    /// Reads a decrypted envelope. Anything but one well-formed `<envelope>` with `<content>`, and with an address in
    /// each `to` and `from` affix it has, is rejected.
    init(parsing bytes: [UInt8]) throws {
        let parser = XMPPStreamParser()
        let events = parser.parse(Array("<sce xmlns='\(XMPPNamespaces.client)'>".utf8) + bytes + Array("</sce>".utf8)) + parser.close()
        guard events.count == 3, case .streamOpened = events[0], case let .stanzaReceived(envelope) = events[1],
              case .streamClosed = events[2], envelope.name == "envelope", envelope.namespace == XMPPNamespaces.sce,
              let content = envelope.child(named: "content", namespace: XMPPNamespaces.sce)
        else { throw OMEMOModuleError.invalidPayload }
        // A content element in the client namespace is a stanza child, so it reads like one: unqualified.
        self.content = content.children.compactMap { node in
            guard case var .element(element) = node else { return nil }
            if element.namespace == XMPPNamespaces.client {
                element.namespace = nil
            }
            return element
        }
        self.time = envelope.child(named: "time", namespace: XMPPNamespaces.sce)?.attribute("stamp")
        self.to = try Self.address(in: envelope.child(named: "to", namespace: XMPPNamespaces.sce))
        self.from = try Self.address(in: envelope.child(named: "from", namespace: XMPPNamespaces.sce))
    }

    /// Nil for a missing affix. An affix without an address can name no one, so it is rejected rather than read as missing.
    private static func address(in affix: XMLElement?) throws -> BareJID? {
        guard let affix else { return nil }
        guard let address = affix.attribute("jid").flatMap(BareJID.parse) else { throw OMEMOModuleError.invalidPayload }
        return address
    }

    private static let paddingCharacters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    private static func padding(after contentLength: Int) -> String {
        let length = max(0, minimumPaddedLength - contentLength) + Int.random(in: 0 ... maximumRandomPadding)
        return String((0 ..< length).map { _ in paddingCharacters[Int.random(in: paddingCharacters.indices)] })
    }
}
