import DuckoXMPP

/// Bridge type for an XEP-0191 block-list item so DuckoUI can use it without importing DuckoXMPP. An address with a
/// resource blocks only that device of the contact.
public struct BlockListEntry: Sendable, Hashable, Identifiable {
    public var id: String {
        jidString
    }

    public let jidString: String

    public init(_ jid: JID) {
        self.jidString = jid.description
    }
}
