import DuckoXMPP
import Foundation
import UniformTypeIdentifiers

/// Stanza metadata without origin-specific trust, filtering, or persistence decisions.
struct InboundMessageMetadata {
    struct ServerIdentifier {
        let id: String?
        let by: String?
    }

    let stanzaID: String?
    let originID: String?
    let serverIdentifiers: [ServerIdentifier]
    let replyToID: String?
    let replyToJID: String?
    let replyFallback: FallbackIndication?
    let attachments: [Attachment]

    init(_ message: XMPPMessage) {
        self.stanzaID = message.id
        self.originID = message.originID
        self.serverIdentifiers = message.element.children(named: "stanza-id")
            .filter { $0.namespace == XMPPNamespaces.stanzaID }
            .map { ServerIdentifier(id: $0.attribute("id"), by: $0.attribute("by")) }
        let reply = message.element.child(named: "reply", namespace: XMPPNamespaces.messageReply)
        self.replyToID = reply?.attribute("id")
        self.replyToJID = reply?.attribute("to")
        self.replyFallback = message.fallbackIndication(for: XMPPNamespaces.messageReply)
        self.attachments = Self.parseAttachments(message)
    }

    /// The part of `body` that quotes the message replied to. An encrypted message's quote is in its decrypted body.
    func replyFallbackRange(in body: String?) -> Range<Int>? {
        body.flatMap { replyFallback?.bodyRange(in: $0) }
    }

    private static func parseAttachments(_ message: XMPPMessage) -> [Attachment] {
        message.oobData.compactMap { oob in
            let url = URL(string: oob.url)
            // A peer's `file:` URL names a path on the recipient's machine, which no peer can legitimately point at, so
            // the link is dropped rather than kept as an attachment.
            guard url?.isFileURL != true else { return nil }
            // The type the peer's link implies, so a shared image renders like any other image rather than as a file.
            let mimeType = url.flatMap { UTType(filenameExtension: $0.pathExtension)?.preferredMIMEType }
            return Attachment(id: UUID(), url: oob.url, mimeType: mimeType, fileName: url?.lastPathComponent, oobDescription: oob.desc)
        }
    }
}
