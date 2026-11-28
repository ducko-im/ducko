import DuckoXMPP
import Foundation

/// Framing an encrypted message for the devices that receive it as legacy OMEMO (XEP-0384 v0.3), whose element encrypts
/// the body alone. As legacy clients frame it, the requests and references the envelope carries then travel in the clear
/// beside the payload, so a legacy device can apply them. A message with no legacy element keeps them inside the
/// envelope alone (XEP-0420).
extension ChatService {
    /// The body of a message only legacy OMEMO devices receive, for a client that reads neither version.
    nonisolated static let legacyFallbackBody = "This message is encrypted with OMEMO, which your client does not support."

    /// The body a legacy element encrypts: the one `content`, an envelope's elements, carries.
    nonisolated static func legacyBody(of content: [DuckoXMPP.XMLElement]) -> String? {
        content.first { $0.name == "body" && $0.namespace == nil }?.textContent
    }

    /// The elements of `content` that travel beside a legacy payload: the receipt request, the marker, the chat state,
    /// the correction, retraction and reply references, and their fallback markers. Nothing else of the envelope, such
    /// as an attachment, leaves the encryption.
    nonisolated static func legacyOuterMetadata(of content: [DuckoXMPP.XMLElement]) -> [DuckoXMPP.XMLElement] {
        content.filter { element in
            if OMEMOModule.isKeptBesideLegacyPayload(element) { return true }
            return switch element.namespace {
            case XMPPNamespaces.messageCorrect: element.name == "replace"
            case XMPPNamespaces.messageRetract: element.name == "retract"
            case XMPPNamespaces.messageReply: element.name == "reply"
            case XMPPNamespaces.fallbackIndication: element.name == "fallback"
            default: false
            }
        }
    }
}

extension OMEMOModule.EncryptedMessageElements {
    /// The body and the elements outside the envelope of a stanza whose envelope carries `content`. The elements are
    /// the encrypted elements, the method's name (XEP-0380) and a store hint, since the message may have no body that
    /// would tell a server to store it. With a legacy element, the metadata legacy devices read in the clear goes
    /// beside it. When the legacy element is the only one, a fallback body goes too. A message with an OMEMO 2 element
    /// carries no body (XEP-0420).
    func stanzaParts(framing content: [DuckoXMPP.XMLElement]) -> (body: String?, elements: [DuckoXMPP.XMLElement]) {
        let elements = [omemo2Encrypted, legacyEncrypted].compactMap(\.self)
            + [encryption, DuckoXMPP.XMLElement(name: "store", namespace: XMPPNamespaces.processingHints)]
        guard legacyEncrypted != nil else { return (nil, elements) }
        let body = omemo2Encrypted == nil ? ChatService.legacyFallbackBody : nil
        return (body, elements + ChatService.legacyOuterMetadata(of: content))
    }
}
