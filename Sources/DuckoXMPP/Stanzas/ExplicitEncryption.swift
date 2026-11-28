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
        XMPPNamespaces.omemoLegacy: "OMEMO",
        "urn:xmpp:omemo:1": "OMEMO 1",
        XMPPNamespaces.omemo: "OMEMO 2"
    ]

    public init(namespace: String, name: String? = nil) {
        self.namespace = namespace
        self.name = Self.knownNames[namespace] ?? name ?? namespace
    }

    /// Whether the method is OMEMO 2 or legacy OMEMO, the versions this client reads.
    public var isOMEMO: Bool {
        namespace == XMPPNamespaces.omemo || namespace == XMPPNamespaces.omemoLegacy
    }
}

public extension XMPPMessage {
    /// The method the message's `<encryption>` element names.
    var encryptionMethod: EncryptionMethod? {
        guard let encryption = element.child(named: "encryption", namespace: XMPPNamespaces.eme),
              let namespace = encryption.attribute("namespace") else { return nil }
        return EncryptionMethod(namespace: namespace, name: encryption.attribute("name"))
    }

    /// Whether the message is encrypted: it names an encryption method or carries an OMEMO `<encrypted>` element.
    var isEncrypted: Bool {
        element.child(named: "encryption", namespace: XMPPNamespaces.eme) != nil || carriesOMEMOPayload
    }

    /// Whether the message carries an OMEMO 2 `<encrypted>` element, with or without a payload, whether or not it names
    /// the method.
    var isOMEMO2Encrypted: Bool {
        element.child(named: "encrypted", namespace: XMPPNamespaces.omemo) != nil
    }

    /// Whether the message carries a legacy OMEMO `<encrypted>` element, with or without a payload, whether or not it
    /// names the method.
    var isLegacyOMEMOEncrypted: Bool {
        element.child(named: "encrypted", namespace: XMPPNamespaces.omemoLegacy) != nil
    }

    /// Whether the message carries an OMEMO `<encrypted>` element of either version, with or without a payload.
    var carriesOMEMOPayload: Bool {
        isOMEMO2Encrypted || isLegacyOMEMOEncrypted
    }

    /// Whether the message is an OMEMO message without a payload, which only carries key material: a key exchange's
    /// answer, a heartbeat or an empty reply. The elements of a stanza carrying both versions come from one send, so
    /// they carry a payload together or not at all.
    var carriesOnlyOMEMOKeys: Bool {
        [XMPPNamespaces.omemo, XMPPNamespaces.omemoLegacy].contains { namespace in
            element.child(named: "encrypted", namespace: namespace).map { $0.child(named: "payload") == nil } ?? false
        }
    }

    /// The method a message encrypted with something other than OMEMO names. Its body is at most the sender's fallback
    /// text, never the message.
    var otherEncryptionMethod: EncryptionMethod? {
        guard !carriesOMEMOPayload, let method = encryptionMethod, !method.isOMEMO else { return nil }
        return method
    }
}
