/// A single PEP Native Bookmark per XEP-0402.
public struct Bookmark: Sendable {
    public let jid: BareJID
    public let name: String?
    public let autojoin: Bool
    public let nickname: String?
    public let password: String?
    /// The `<extensions/>` element as received, kept whole so a republish carries other clients' data.
    public let extensions: XMLElement?

    public init(
        jid: BareJID,
        name: String? = nil,
        autojoin: Bool = false,
        nickname: String? = nil,
        password: String? = nil,
        extensions: XMLElement? = nil
    ) {
        self.jid = jid
        self.name = name
        self.autojoin = autojoin
        self.nickname = nickname
        self.password = password
        self.extensions = extensions
    }

    // MARK: - Parsing

    /// Parses a bookmark from a PEP item. The item ID is the room JID (XEP-0402 §3).
    public static func parse(itemID: String, payload: XMLElement) -> Bookmark? {
        guard payload.name == "conference",
              payload.namespace == XMPPNamespaces.bookmarks2,
              let jid = BareJID.parse(itemID) else {
            return nil
        }

        let name = payload.attribute("name")
        let autojoinStr = payload.attribute("autojoin")
        let autojoin = autojoinStr == "true" || autojoinStr == "1"
        let nickname = payload.child(named: "nick")?.textContent
        let password = payload.child(named: "password")?.textContent

        return Bookmark(
            jid: jid,
            name: name,
            autojoin: autojoin,
            nickname: nickname,
            password: password,
            extensions: payload.child(named: "extensions")
        )
    }

    // MARK: - Building

    /// Builds the `<conference xmlns='urn:xmpp:bookmarks:1'>` payload element.
    public func toXMLElement() -> XMLElement {
        var attrs: [String: String] = [:]
        if let name {
            attrs["name"] = name
        }
        if autojoin {
            attrs["autojoin"] = "true"
        }

        var conference = XMLElement(name: "conference", namespace: XMPPNamespaces.bookmarks2, attributes: attrs)

        if let nickname {
            var nick = XMLElement(name: "nick")
            nick.addText(nickname)
            conference.addChild(nick)
        }

        if let password {
            var pw = XMLElement(name: "password")
            pw.addText(password)
            conference.addChild(pw)
        }

        if let extensions {
            conference.addChild(extensions)
        }

        return conference
    }

    // MARK: - XEP-0223 Publish Options

    /// Publish options for persistent, private PEP storage (XEP-0223).
    public static let publishOptions: [DataFormField] = [
        DataFormField.pubsubPublishOptionsHeader,
        DataFormField(variable: "pubsub#persist_items", values: ["true"]),
        DataFormField(variable: "pubsub#access_model", values: ["whitelist"]),
        DataFormField(variable: "pubsub#max_items", values: ["max"])
    ]
}
