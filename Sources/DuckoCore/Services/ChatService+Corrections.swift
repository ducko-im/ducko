import DuckoXMPP
import Foundation

/// A correction of one of the user's own messages (XEP-0308). It re-sends the whole message (§4): the new text, after
/// the quote of the message it replies to, and everything else the message carried.
struct OwnCorrection {
    /// The corrected message, as stored.
    let original: ChatMessage
    let reply: MessageReply?
    /// The new text, filtered.
    let content: MessageContent

    /// The corrected body, as sent and stored.
    var body: String {
        reply?.body(replying: content.body) ?? content.body
    }

    /// The reply reference the corrected message carried, with the marker of its quote.
    var replyElements: [DuckoXMPP.XMLElement] {
        reply?.elements ?? []
    }

    /// The attachments the corrected message carried.
    var attachmentElements: [DuckoXMPP.XMLElement] {
        original.attachments.map(ChatService.oobElement)
    }
}

extension ChatService {
    /// Sends the correction of the user's own `original`, sent as `stanzaID`, to the contact of the 1:1 `conversation`.
    func sendCorrection(
        of original: ChatMessage, stanzaID: String, newBody: String, toContactIn conversation: Conversation, accountID: UUID
    ) async throws {
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let chatModule = await client.module(ofType: ChatModule.self) else { return }
        let jid = conversation.jid

        let attachesChatState = sendsChatStates(to: .contact(jid), accountID: accountID)
        let trustedDeviceIDs = try await trustedDeviceIDsForSend(jid: jid, accountID: accountID, conversation: conversation)
        let correction = await ownCorrection(of: original, newBody: newBody, accountID: accountID, fallback: jid)

        // Each path re-sends the original's other payloads along with the new body (XEP-0308 §4).
        if let trustedDeviceIDs {
            let replaceElement = DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": stanzaID])
            try await sendEncrypted(
                Self.envelopeContent(
                    body: correction.body, [replaceElement] + correction.replyElements + correction.attachmentElements,
                    requestsReceipt: true, isMarkable: true, carriesChatState: attachesChatState
                ),
                to: jid, id: client.generateID(), trustedDeviceIDs: trustedDeviceIDs, accountID: accountID
            )
        } else {
            try await chatModule.sendCorrection(
                to: recipientJID(for: jid, accountID: accountID), body: correction.content.body, replacingID: stanzaID,
                reply: correction.reply, requestReceipt: true, markable: true, includeChatState: attachesChatState,
                additionalElements: correction.attachmentElements
            )
        }
        didSendContentMessage(to: .contact(jid), carryingChatState: attachesChatState, accountID: accountID)
        try await record(correction, in: conversation.id)
    }

    /// Sends the correction of the user's own `original`, sent as `stanzaID`, to the room `conversation`.
    func sendGroupCorrection(
        of original: ChatMessage, stanzaID: String, newBody: String, inRoom conversation: Conversation, accountID: UUID
    ) async throws {
        guard let client = accountService?.connectedClient(for: accountID) else { throw ChatServiceError.notConnected(accountID) }
        guard let mucModule = await client.module(ofType: MUCModule.self) else { return }
        let room = conversation.jid

        let correction = await ownCorrection(of: original, newBody: newBody, accountID: accountID, fallback: room)

        let replaceElement = DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": stanzaID])
        _ = try await encryptAndSendGroupMessage(
            room: room, body: correction.body, stanzaID: client.generateID(),
            conversation: conversation, mucModule: mucModule,
            additionalElements: [replaceElement] + correction.attachmentElements + correction.replyElements
        )
        didSendContentMessage(to: .room(room), carryingChatState: false, accountID: accountID)
        try await record(correction, in: conversation.id)
    }

    /// The correction of `original` to `newBody`. The message is read back as stored, since a copy drawn in a chat can
    /// have its reply quote hidden.
    func ownCorrection(of original: ChatMessage, newBody: String, accountID: UUID, fallback: BareJID) async -> OwnCorrection {
        let stored = await (try? transcripts.findMessage(id: original.id, conversationID: original.conversationID)) ?? original
        let content = await filterBody(newBody, direction: .outgoing, accountID: accountID, fallback: fallback)
        return OwnCorrection(original: stored, reply: stored.messageReply, content: content)
    }

    /// Stores `correction`, once sent, as the edit of its message.
    func record(_ correction: OwnCorrection, in conversationID: UUID) async throws {
        try await transcripts.appendAmendment(
            TranscriptAmendment(
                action: .edit, targetMessageID: correction.original.id, targetStanzaID: correction.original.stanzaID, timestamp: Date(),
                body: correction.body, htmlBody: correction.content.htmlBody, replyFallbackRange: correction.reply?.fallbackRange
            ),
            conversationID: conversationID
        )
        await messagesChanged(in: conversationID)
    }
}
