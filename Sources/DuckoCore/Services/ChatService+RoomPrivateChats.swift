import DuckoXMPP
import Foundation

/// Sending in the private chat with a room's occupant (XEP-0045 §7.5). Everything goes to the occupant's address in the
/// room, `room@service/nick`, and is stored in the private chat, never in the room or a 1:1 chat with the room. Nothing
/// sent in a private chat is encrypted, so no message or correction is sent in one that has encryption switched on.
extension ChatService {
    /// Sends `body` in the private chat `conversation`, as a reply to `quoted` when given.
    func sendPrivateMessage(_ body: String, inPrivateChat conversation: Conversation, replyingTo quoted: ChatMessage?, accountID: UUID) async throws {
        guard !conversation.encryptionEnabled else { throw ChatServiceError.encryptionFailed(Self.privateChatsUnencrypted) }
        let chat = try await privateChat(conversation, accountID: accountID)
        var reply: MessageReply?
        if let quoted {
            reply = try await messageReply(quoting: quoted, by: roomAuthor(of: quoted, in: chat.room, accountID: accountID), inPlaintext: true)
        }
        let filtered = await filterBody(body, direction: .outgoing, accountID: accountID, fallback: chat.room)
        let wireBody = reply?.body(replying: filtered.body) ?? filtered.body
        let stanzaID = chat.client.generateID()

        let message = ChatMessage(
            id: UUID(),
            conversationID: chat.conversation.id,
            stanzaID: stanzaID,
            fromJID: chat.nickname,
            body: wireBody,
            htmlBody: filtered.htmlBody,
            timestamp: Date(),
            isOutgoing: true,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            replyToID: reply?.id,
            replyToJID: reply?.author.description,
            replyFallbackRange: reply?.fallbackRange
        )
        try await persistMessage(message, in: chat.conversation, accountID: accountID)

        // Persist-before-send + retract-on-failure (MUC PMs aren't echoed back to the sender, so the
        // optimistic row is never doubled).
        let chatState = attachedChatState(for: .occupant(chat.occupant), accountID: accountID)
        do {
            try await chat.mucModule.sendPrivateMessage(
                to: chat.room, nickname: chat.nickname, body: wireBody, id: stanzaID, additionalElements: (reply?.elements ?? []) + chatState
            )
        } catch {
            try? await recordLocalRetraction(of: message, stanzaID: stanzaID, in: chat.conversation.id)
            throw error
        }
        didSendContentMessage(to: .occupant(chat.occupant), carryingChatState: !chatState.isEmpty, accountID: accountID)
    }

    /// Sends the correction (XEP-0308) of the user's own `original`, sent as `stanzaID`, in the private chat `conversation`.
    func sendPrivateCorrection(
        of original: ChatMessage, stanzaID: String, newBody: String, inPrivateChat conversation: Conversation, accountID: UUID
    ) async throws {
        guard !conversation.encryptionEnabled else { throw ChatServiceError.encryptionFailed(Self.privateChatsUnencrypted) }
        let chat = try await privateChat(conversation, accountID: accountID)
        let correction = await ownCorrection(of: original, newBody: newBody, accountID: accountID, fallback: chat.room)

        let replaceElement = DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": stanzaID])
        let chatState = attachedChatState(for: .occupant(chat.occupant), accountID: accountID)
        try await chat.mucModule.sendPrivateMessage(
            to: chat.room, nickname: chat.nickname, body: correction.body, id: chat.client.generateID(),
            additionalElements: [replaceElement] + correction.attachmentElements + correction.replyElements + chatState
        )
        didSendContentMessage(to: .occupant(chat.occupant), carryingChatState: !chatState.isEmpty, accountID: accountID)
        try await record(correction, in: chat.conversation.id)
    }

    /// Retracts the user's own `original` (XEP-0424), sent as `stanzaID`, in the private chat `conversation`.
    func retractPrivateMessage(_ original: ChatMessage, stanzaID: String, inPrivateChat conversation: Conversation, accountID: UUID) async throws {
        // One the user sent encrypted from another device cannot be retracted in the clear.
        guard !original.isEncrypted else { throw ChatServiceError.encryptionFailed(Self.privateChatsUnencrypted) }
        let chat = try await privateChat(conversation, accountID: accountID)

        let retractElement = DuckoXMPP.XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": stanzaID])
        let fallbackElement = FallbackIndication(for: XMPPNamespaces.messageRetract).element
        let storeHint = DuckoXMPP.XMLElement(name: "store", namespace: XMPPNamespaces.processingHints)
        let chatState = attachedChatState(for: .occupant(chat.occupant), accountID: accountID)
        try await chat.mucModule.sendPrivateMessage(
            to: chat.room, nickname: chat.nickname, body: retractionFallbackBody, id: chat.client.generateID(),
            additionalElements: [retractElement, fallbackElement, storeHint] + chatState
        )
        didSendContentMessage(to: .occupant(chat.occupant), carryingChatState: !chatState.isEmpty, accountID: accountID)
        try await recordLocalRetraction(of: original, stanzaID: stanzaID, in: chat.conversation.id)
    }

    private static let privateChatsUnencrypted = "a room's private chats are not encrypted"

    private struct PrivateChat {
        let occupant: FullJID
        let conversation: Conversation
        let client: XMPPClient
        let mucModule: MUCModule

        var room: BareJID {
            occupant.bareJID
        }

        var nickname: String {
            occupant.resourcePart
        }
    }

    /// The occupant the private chat `conversation` is with, and the connection to send to them.
    private func privateChat(_ conversation: Conversation, accountID: UUID) async throws -> PrivateChat {
        guard let client = accountService?.connectedClient(for: accountID), let mucModule = await client.module(ofType: MUCModule.self) else {
            throw ChatServiceError.notConnected(accountID)
        }
        guard let nickname = conversation.occupantNickname, let occupant = FullJID(bareJID: conversation.jid, resourcePart: nickname) else {
            throw ChatServiceError.invalidJID(conversation.occupantNickname ?? conversation.jid.description)
        }
        return PrivateChat(occupant: occupant, conversation: conversation, client: client, mucModule: mucModule)
    }
}
