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
    func isFromOwnAccount(_ ownJID: BareJID?) -> Bool {
        isSender(element.attribute("from"), exactly: ownJID, orAbsent: true)
    }

    /// The stanza's sender when it is a bare JID, or `ownJID` when the server left `from` out on the account's
    /// behalf (RFC 6120 §8.1.2.1).
    func bareSender(orOwn ownJID: BareJID?) -> BareJID? {
        DuckoXMPP.bareSender(element.attribute("from"), ifAbsent: ownJID)
    }
}

/// A raw sender that is a bare JID, or `fallback` when the sender is left out.
/// Takes the raw attribute, so a sender that does not parse, or a full JID, gives nil instead of passing as left out.
func bareSender(_ rawSender: String?, ifAbsent fallback: BareJID?) -> BareJID? {
    guard let rawSender else { return fallback }
    guard case let .bare(bare)? = JID.parse(rawSender) else { return nil }
    return bare
}

/// Whether a raw sender is exactly the bare JID `expected`, or is left out where `absentAllowed`.
func isSender(_ rawSender: String?, exactly expected: BareJID?, orAbsent absentAllowed: Bool) -> Bool {
    guard rawSender != nil else { return absentAllowed }
    guard let expected else { return false }
    return bareSender(rawSender, ifAbsent: nil) == expected
}
