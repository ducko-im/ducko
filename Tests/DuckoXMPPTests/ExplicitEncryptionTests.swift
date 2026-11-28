import Testing
@testable import DuckoXMPP

/// What a message's encryption elements say about it: which OMEMO versions it carries, whether it carries only key
/// material, and which other method it names (XEP-0380).
struct ExplicitEncryptionTests {
    /// A chat message carrying an `<encrypted>` element in each of `namespaces`, each with a payload when `hasPayload`,
    /// and an `<encryption>` element naming `method` when given.
    private func message(omemo namespaces: [String], hasPayload: Bool = true, naming method: String? = nil) -> XMPPMessage {
        var message = XMPPMessage(type: .chat, id: "m1")
        for namespace in namespaces {
            var encrypted = XMLElement(name: "encrypted", namespace: namespace)
            encrypted.addChild(XMLElement(name: "header", attributes: ["sid": "1"]))
            if hasPayload {
                var payload = XMLElement(name: "payload")
                payload.addText("AAAA")
                encrypted.addChild(payload)
            }
            message.element.addChild(encrypted)
        }
        if let method {
            message.element.addChild(XMLElement(name: "encryption", namespace: XMPPNamespaces.eme, attributes: ["namespace": method]))
        }
        return message
    }

    /// A stanza carrying both versions comes from one send, which gives both a payload or neither.
    @Test(arguments: [[XMPPNamespaces.omemo], [XMPPNamespaces.omemoLegacy], [XMPPNamespaces.omemo, XMPPNamespaces.omemoLegacy]], [true, false])
    func `an OMEMO element of either version makes the message encrypted, and one without a payload carries only keys`(
        namespaces: [String], hasPayload: Bool
    ) {
        let message = message(omemo: namespaces, hasPayload: hasPayload)

        #expect(message.isEncrypted)
        #expect(message.carriesOMEMOPayload)
        #expect(message.isOMEMO2Encrypted == namespaces.contains(XMPPNamespaces.omemo))
        #expect(message.isLegacyOMEMOEncrypted == namespaces.contains(XMPPNamespaces.omemoLegacy))
        #expect(message.carriesOnlyOMEMOKeys == !hasPayload)
        #expect(message.otherEncryptionMethod == nil)
    }

    @Test(arguments: [XMPPNamespaces.omemo, XMPPNamespaces.omemoLegacy])
    func `a message naming either OMEMO version without its element is encrypted, with no other method`(method: String) {
        let message = message(omemo: [], naming: method)

        #expect(message.isEncrypted)
        #expect(!message.carriesOMEMOPayload)
        #expect(message.otherEncryptionMethod == nil)
    }

    /// A method's name is the only thing such a message shows, and an OMEMO element of either version is read instead.
    @Test(arguments: [[], [XMPPNamespaces.omemoLegacy]])
    func `a method other than OMEMO counts only on a message without an OMEMO element`(namespaces: [String]) {
        let message = message(omemo: namespaces, naming: "urn:xmpp:openpgp:0")

        #expect(message.otherEncryptionMethod?.name == (namespaces.isEmpty ? "OpenPGP for XMPP" : nil))
    }
}
