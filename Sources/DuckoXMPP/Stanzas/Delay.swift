/// XEP-0203 delayed delivery: a stanza delivered later than it was sent, such as room history or an offline message.
public extension XMPPMessage {
    /// Whether a delay is stamped on the message, by anyone.
    var isDelayed: Bool {
        element.child(named: "delay", namespace: XMPPNamespaces.delay) != nil
    }
}
