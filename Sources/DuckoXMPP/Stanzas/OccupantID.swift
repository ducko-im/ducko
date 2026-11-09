/// XEP-0421 occupant id: the room's stable, opaque id for the occupant that sent a stanza. Only meaningful from a
/// room that advertises the feature, so readers check that before trusting it.
public extension XMPPStanza {
    var occupantID: String? {
        element.child(named: "occupant-id", namespace: XMPPNamespaces.occupantID)?.attribute("id")
    }
}
