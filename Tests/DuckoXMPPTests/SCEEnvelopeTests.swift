import Testing
@testable import DuckoXMPP

/// The Stanza Content Encryption envelope (XEP-0420) an OMEMO payload carries.
struct SCEEnvelopeTests {
    private let alice = BareJID(localPart: "alice", domainPart: "example.com")!
    private let bob = BareJID(localPart: "bob", domainPart: "example.com")!

    @Test func `the reference's envelopes read with their content and affixes`() throws {
        let messages = try OMEMO2Fixtures.conversation().messages.filter { $0.plaintext != nil }

        for message in messages {
            let envelope = try SCEEnvelope(parsing: Array(#require(message.plaintext).utf8))
            let recipient = message.sender == "alice" ? "bob" : "alice"

            #expect(envelope.content.map(\.name) == ["body"])
            #expect(envelope.content.first?.namespace == nil)
            #expect(envelope.time?.hasPrefix("2026-10-20T12:0") == true)
            #expect(try envelope.to == BareJID.parse(OMEMO2Fixtures.device(recipient).jid))
            #expect(try envelope.from == BareJID.parse(OMEMO2Fixtures.device(message.sender).jid))
        }
        #expect(!messages.isEmpty)
    }

    @Test func `an envelope reads back with every element it carries, in the client namespace unless it has its own`() throws {
        let reply = XMLElement(name: "reply", namespace: XMPPNamespaces.messageReply, attributes: ["id": "m0", "to": alice.description])
        let content = [bodyElement("Fish & chips <tonight>?"), reply, XMLElement(name: "active", namespace: XMPPNamespaces.chatStates)]

        let bytes = SCEEnvelope.build(content: content, time: testEnvelopeTime, to: bob, from: alice)
        let envelope = try SCEEnvelope(parsing: bytes)

        #expect(String(decoding: bytes, as: UTF8.self).contains(#"<body xmlns="jabber:client">"#))
        // Entities split text into several nodes, so the elements are compared as written.
        #expect(envelope.content.map(\.xmlString) == content.map(\.xmlString))
        #expect(envelope.time == testEnvelopeTime)
        #expect(envelope.to == bob)
        #expect(envelope.from == alice)
    }

    /// The minimum keeps a short message from giving its length away, and every message gets a random amount of padding
    /// on top.
    @Test(arguments: [1, 150, 400])
    func `padding makes content and padding at least the minimum length`(bodyLength: Int) throws {
        let body = bodyElement(String(repeating: "a", count: bodyLength))

        let envelope = try stanza(String(decoding: SCEEnvelope.build(content: [body], time: testEnvelopeTime, to: bob, from: alice), as: UTF8.self))
        let contentLength = #"<content><body xmlns="jabber:client">"#.utf8.count + bodyLength + "</body></content>".utf8.count
        // The random amount can be zero, which leaves `<rpad/>` empty when the content already reaches the minimum.
        let paddingLength = try #require(envelope.child(named: "rpad")).textContent?.count ?? 0

        #expect(paddingLength >= SCEEnvelope.minimumPaddedLength - contentLength)
        #expect(paddingLength <= max(0, SCEEnvelope.minimumPaddedLength - contentLength) + SCEEnvelope.maximumRandomPadding)
    }

    @Test(arguments: [
        "not xml at all",
        "<envelope xmlns='urn:xmpp:sce:1'><content>",
        "<envelope xmlns='urn:xmpp:sce:1'/>",
        "<envelope xmlns='urn:xmpp:other'><content/></envelope>",
        "<content xmlns='urn:xmpp:sce:1'/>",
        "<envelope xmlns='urn:xmpp:sce:1'><content/></envelope><envelope xmlns='urn:xmpp:sce:1'><content/></envelope>",
        "<envelope xmlns='urn:xmpp:sce:1'><content/></envelope></sce><sce>",
        "<?xml version='1.0'?><envelope xmlns='urn:xmpp:sce:1'><content/></envelope>",
        "<envelope xmlns='urn:xmpp:sce:1'><content/><to/></envelope>",
        "<envelope xmlns='urn:xmpp:sce:1'><content/><from jid='@example.com'/></envelope>"
    ])
    func `anything but one well-formed envelope is rejected`(xml: String) {
        #expect(throws: OMEMOModuleError.invalidPayload) {
            try SCEEnvelope(parsing: Array(xml.utf8))
        }
    }
}
