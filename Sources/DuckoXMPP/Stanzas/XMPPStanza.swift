/// Base protocol for XMPP stanzas (message, presence, iq).
public protocol XMPPStanza: Sendable {
    var element: XMLElement { get set }
}

public extension XMPPStanza {
    var to: JID? {
        get { element.attribute("to").flatMap(JID.parse) }
        set { element.attributes["to"] = newValue?.description }
    }

    var from: JID? {
        get { element.attribute("from").flatMap(JID.parse) }
        set { element.attributes["from"] = newValue?.description }
    }

    var id: String? {
        get { element.attribute("id") }
        set { element.attributes["id"] = newValue }
    }

    var type: String? {
        get { element.attribute("type") }
        set { element.attributes["type"] = newValue }
    }
}

extension XMPPStanza {
    /// Whether the stanza comes from the account itself: no `from`, or exactly the own bare JID.
    /// RFC 6120 §8.1.2.1 lets the server leave out `from` on the account's behalf. RFC 6121 §2.1.6 and
    /// XEP-0280 §11 otherwise require the own bare JID.
    /// Reads the raw attribute, so an unparseable `from` is rejected instead of passing as absent.
    func isFromOwnAccount(_ ownJID: BareJID?) -> Bool {
        guard let rawFrom = element.attribute("from") else { return true }
        guard let ownJID, let from = JID.parse(rawFrom), case let .bare(bare) = from else { return false }
        return bare == ownJID
    }
}
