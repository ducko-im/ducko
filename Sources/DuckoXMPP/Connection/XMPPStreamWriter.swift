/// Serializes XMPP stream-level XML to UTF-8 bytes.
enum XMPPStreamWriter {
    /// The `xml:lang` of the streams this client opens.
    static let lang = "en"

    /// Generates the XML declaration and `<stream:stream>` opening tag.
    static func streamOpening(
        to domain: String,
        from jid: String? = nil,
        version: String = "1.0",
        xmlLang: String = lang
    ) -> [UInt8] {
        var xml = "<?xml version='1.0'?>"
        xml += "<stream:stream"
        xml += " xmlns=\"jabber:client\""
        xml += " xmlns:stream=\"http://etherx.jabber.org/streams\""
        xml += " to=\"\(XMLElement.escape(domain))\""
        if let jid {
            xml += " from=\"\(XMLElement.escape(jid))\""
        }
        xml += " version=\"\(XMLElement.escape(version))\""
        xml += " xml:lang=\"\(XMLElement.escape(xmlLang))\""
        xml += ">"
        return Array(xml.utf8)
    }

    static func stanza(_ element: XMLElement) -> [UInt8] {
        Array(element.xmlString.utf8)
    }

    static func streamClosing() -> [UInt8] {
        Array("</stream:stream>".utf8)
    }
}
