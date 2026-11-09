/// XEP-0359 origin-id: the ID the sending client gave a message, which survives a room or server that restamps the
/// stanza's own `id`.
extension XMPPMessage {
    /// A message this client originates, with `id` as both its stanza ID and its origin-id. A client that sets stanza
    /// IDs must also send them as origin-id.
    init(type: MessageType, to: JID, originID id: String) {
        self.init(type: type, to: to, id: id)
        element.addChild(XMLElement(name: "origin-id", namespace: XMPPNamespaces.stanzaID, attributes: ["id": id]))
    }

    public var originID: String? {
        element.child(named: "origin-id", namespace: XMPPNamespaces.stanzaID)?.attribute("id")
    }
}

public extension ServiceDiscoveryModule.InfoResult {
    /// Whether the entity whose disco#info this is stamps the messages it handles with stanza-ids (XEP-0359).
    var supportsStanzaIDs: Bool {
        features.contains(XMPPNamespaces.stanzaID)
    }
}
