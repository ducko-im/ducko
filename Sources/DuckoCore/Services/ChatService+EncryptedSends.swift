import DuckoXMPP
import Foundation

/// Sending encrypted messages (XEP-0384). Everything a plaintext message carries goes inside the envelope
/// (XEP-0420): the body, the reply, correction and retraction references with their fallback markers, attachments, the
/// receipt request, the marker and the chat state. Only the ids, the encryption and the storage hint stay outside, and
/// no plaintext body goes along. A message legacy OMEMO devices receive also carries all of it but the body and
/// attachments in the clear, and a fallback body when no device receives OMEMO 2 (`stanzaParts(framing:)`).
extension ChatService {
    /// The elements an encrypted message carries in its envelope: its body, then `elements`, then the requests it makes.
    static func envelopeContent(
        body: String, _ elements: [DuckoXMPP.XMLElement] = [], requestsReceipt: Bool = false, isMarkable: Bool = false,
        carriesChatState: Bool = false
    ) -> [DuckoXMPP.XMLElement] {
        var bodyElement = DuckoXMPP.XMLElement(name: "body")
        bodyElement.addText(body)
        var content = [bodyElement] + elements
        if requestsReceipt {
            content.append(DuckoXMPP.XMLElement(name: "request", namespace: XMPPNamespaces.receipts))
        }
        if isMarkable {
            content.append(DuckoXMPP.XMLElement(name: "markable", namespace: XMPPNamespaces.chatMarkers))
        }
        if carriesChatState {
            content.append(DuckoXMPP.XMLElement(name: ChatState.active.rawValue, namespace: XMPPNamespaces.chatStates))
        }
        return content
    }

    /// Sends `content` to `jid`, encrypted for `trustedDeviceIDs` and the account's own devices, as message `id`.
    func sendEncrypted(_ content: [DuckoXMPP.XMLElement], to jid: BareJID, id: String, trustedDeviceIDs: [UInt32], accountID: UUID) async throws {
        guard let omemoService else { throw ChatServiceError.omemoServiceUnavailable(conversationJID: jid) }
        guard let chatModule = await accountService?.connectedClient(for: accountID)?.module(ofType: ChatModule.self) else {
            throw ChatServiceError.notConnected(accountID)
        }
        let elements = try await omemoService.encryptMessage(
            content: content, legacyBody: Self.legacyBody(of: content), to: jid, trustedDeviceIDs: trustedDeviceIDs, accountID: accountID
        )
        let stanza = elements.stanzaParts(framing: content)
        try await chatModule.sendMessage(
            to: recipientJID(for: jid, accountID: accountID), body: stanza.body, id: id, includeChatState: false, additionalElements: stanza.elements
        )
    }

    /// The body and elements of a stanza that sends `content` to `room`, encrypted for `recipients` and the account's
    /// own devices.
    func encryptedGroupStanza(
        _ content: [DuckoXMPP.XMLElement], in room: BareJID, for recipients: [(jid: BareJID, deviceIDs: [UInt32])],
        omemoService: OMEMOService, accountID: UUID
    ) async throws -> (body: String?, elements: [DuckoXMPP.XMLElement]) {
        let elements = try await omemoService.encryptGroupMessage(
            content: content, legacyBody: Self.legacyBody(of: content), roomJID: room, recipients: recipients, accountID: accountID
        )
        return elements.stanzaParts(framing: content)
    }
}
