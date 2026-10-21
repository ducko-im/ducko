import DuckoXMPP
import Foundation

/// Retracting the user's own messages (XEP-0424) in a 1:1 chat or a room. A retraction to a contact is a content
/// message, so it carries `<active/>` where chat states go (XEP-0085).
extension ChatService {
    /// Retracts the user's own `original`, sent as `stanzaID`, to the contact of the 1:1 `conversation`.
    func retractMessage(_ original: ChatMessage, stanzaID: String, toContactIn conversation: Conversation, accountID: UUID) async throws {
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let chatModule = await client.module(ofType: ChatModule.self) else { return }
        let jid = conversation.jid

        let attachesChatState = sendsChatStates(to: .contact(jid), accountID: accountID)
        if let trustedDeviceIDs = try await trustedDeviceIDsForSend(jid: jid, accountID: accountID, conversation: conversation) {
            let retractElement = DuckoXMPP.XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": stanzaID])
            try await sendEncrypted(
                Self.envelopeContent(
                    body: retractionFallbackBody, [retractElement, FallbackIndication(for: XMPPNamespaces.messageRetract).element],
                    carriesChatState: attachesChatState
                ),
                to: jid, id: client.generateID(), trustedDeviceIDs: trustedDeviceIDs, accountID: accountID
            )
        } else {
            try await chatModule.sendRetraction(
                to: recipientJID(for: jid, accountID: accountID), originalID: stanzaID, includeChatState: attachesChatState
            )
        }
        didSendContentMessage(to: .contact(jid), carryingChatState: attachesChatState, accountID: accountID)
        try await recordLocalRetraction(of: original, stanzaID: stanzaID, in: conversation.id)
    }

    /// Retracts the user's own `original`, sent as `stanzaID`, in the room `conversation`. A room message is retracted
    /// by the stanza-id the room assigned to it (XEP-0424 §5.1), so only once the room has echoed it.
    func retractGroupMessage(_ original: ChatMessage, stanzaID: String, inRoom conversation: Conversation, accountID: UUID) async throws {
        guard let serverID = original.serverID else { throw ChatServiceError.unconfirmedRoomMessage }
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }

        let retractElement = DuckoXMPP.XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": serverID])
        let fallbackElement = FallbackIndication(for: XMPPNamespaces.messageRetract).element
        _ = try await encryptAndSendGroupMessage(
            room: conversation.jid, body: retractionFallbackBody, stanzaID: client.generateID(),
            conversation: conversation, mucModule: mucModule,
            additionalElements: [retractElement, fallbackElement]
        )
        try await recordLocalRetraction(of: original, stanzaID: stanzaID, in: conversation.id)
    }

    /// Stores `message`, sent as `stanzaID`, as retracted. A message whose send failed is retracted this way alone, so
    /// it does not stay in the chat although it never reached the server.
    func recordLocalRetraction(of message: ChatMessage, stanzaID: String, in conversationID: UUID) async throws {
        try await transcripts.appendAmendment(
            TranscriptAmendment(action: .retract, targetMessageID: message.id, targetStanzaID: stanzaID, timestamp: Date()),
            conversationID: conversationID
        )
        await messagesChanged(in: conversationID)
    }

    /// Stores the message the room assigned the stanza-id `serverID` to as removed by a moderator (XEP-0425).
    func recordModeration(of serverID: String, in conversationID: UUID) async throws {
        try await transcripts.appendAmendment(
            TranscriptAmendment(action: .retract, targetServerID: serverID, timestamp: Date()),
            conversationID: conversationID
        )
        await messagesChanged(in: conversationID)
    }
}
