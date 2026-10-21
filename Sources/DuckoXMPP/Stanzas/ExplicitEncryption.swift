/// The encryption method a message says it is encrypted with (XEP-0380).
public struct EncryptionMethod: Sendable, Equatable {
    public let namespace: String
    /// What the method is called: the name XEP-0380 lists for its namespace, else the name the message gives, else the
    /// namespace itself.
    public let name: String

    /// The names XEP-0380 lists. A message's own `name` is used only for a namespace missing here, so a sender cannot
    /// pass one known method off as another.
    private static let knownNames = [
        "urn:xmpp:otr:0": "OTR",
        "jabber:x:encrypted": "Legacy OpenPGP",
        "urn:xmpp:openpgp:0": "OpenPGP for XMPP",
        "eu.siacs.conversations.axolotl": "OMEMO",
        "urn:xmpp:omemo:1": "OMEMO 1",
        XMPPNamespaces.omemo: "OMEMO 2"
    ]

    public init(namespace: String, name: String? = nil) {
        self.namespace = namespace
        self.name = Self.knownNames[namespace] ?? name ?? namespace
    }

    public var isOMEMO: Bool {
        namespace == XMPPNamespaces.omemo
    }
}

public extension XMPPMessage {
    /// The method the message's `<encryption>` element names.
    var encryptionMethod: EncryptionMethod? {
        guard let encryption = element.child(named: "encryption", namespace: XMPPNamespaces.eme),
              let namespace = encryption.attribute("namespace") else { return nil }
        return EncryptionMethod(namespace: namespace, name: encryption.attribute("name"))
    }

    /// Whether the message is encrypted: it names an encryption method or carries an OMEMO payload.
    var isEncrypted: Bool {
        element.child(named: "encryption", namespace: XMPPNamespaces.eme) != nil || isOMEMOEncrypted
    }

    /// Whether the message carries an OMEMO payload, whether or not it names the method.
    var isOMEMOEncrypted: Bool {
        element.child(named: "encrypted", namespace: XMPPNamespaces.omemo) != nil
    }

    /// Whether the message is an OMEMO message without a payload, which only carries key material: a key exchange's
    /// answer, a heartbeat or an empty reply.
    var carriesOnlyOMEMOKeys: Bool {
        element.child(named: "encrypted", namespace: XMPPNamespaces.omemo).map { $0.child(named: "payload") == nil } ?? false
    }

    /// The method a message encrypted with something other than OMEMO 2 names. Its body is at most the sender's
    /// fallback text, never the message.
    var otherEncryptionMethod: EncryptionMethod? {
        guard !isOMEMOEncrypted, let method = encryptionMethod, !method.isOMEMO else { return nil }
        return method
    }
}
