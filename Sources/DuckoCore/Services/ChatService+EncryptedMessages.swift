import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.chat")

/// What an encrypted message holds for the transcript: the message as its sender wrote it, or why it cannot be read.
enum EncryptedContent {
    /// `message` carries the received stanza's attributes and the encrypted elements. `sentTime` is the envelope's
    /// `time` affix.
    case decrypted(XMPPMessage, sentTime: String?)
    case undecryptable(UndecryptableReason)

    init(_ outcome: OMEMOReceiveOutcome) {
        switch outcome {
        case let .decrypted(decrypted):
            self = .decrypted(decrypted.message, sentTime: decrypted.sentTime)
        case let .undecryptable(reason):
            self = switch reason {
            case .decryptionFailed: .undecryptable(.decryptionFailed)
            case .notForThisDevice: .undecryptable(.notForThisDevice)
            case .mismatchedEnvelope: .undecryptable(.mismatchedEnvelope)
            case .senderHidden: .undecryptable(.senderHidden)
            }
        }
    }
}

/// Where an encrypted message came from: live, or forwarded by a carbon (XEP-0280) that another of the user's devices
/// sent (`isOutgoing`) or received at `sentTime`.
enum EncryptedMessageOrigin {
    case live
    case carbon(isOutgoing: Bool, sentTime: Date)
}

extension ChatService {
    /// How far an envelope's `time` may be from when its message was sent (XEP-0420).
    private static let envelopeTimeTolerance: TimeInterval = 60 * 60

    /// Files an encrypted message: a decrypted one as its sender wrote it, an amendment on the message it names, and
    /// one that cannot be read as a notice. Elements next to the encrypted payload are outside the encryption, so only
    /// the stanza's ids, delay and addresses are read from it.
    func receiveEncryptedMessage(_ stanza: XMPPMessage, content: EncryptedContent, origin: EncryptedMessageOrigin, accountID: UUID) async {
        if stanza.messageType == .groupchat {
            guard case .live = origin else { return }
            await receiveEncryptedRoomMessage(stanza, content: content, accountID: accountID)
        } else {
            await receiveEncryptedChatMessage(stanza, content: content, origin: origin, accountID: accountID)
        }
    }

    /// Shows a live encrypted message without an OMEMO payload as a notice, since its body is at most the sender's
    /// fallback text (XEP-0380): a room message when `inRoom`, else a chat or private message. A headline, which is
    /// otherwise not kept, has its notice kept in the chat with its sender. Returns whether `message` was shown as a
    /// notice.
    func showsEncryptionNotice(for message: XMPPMessage, inRoom: Bool, accountID: UUID) async -> Bool {
        let types: [XMPPMessage.MessageType?] = inRoom ? [.groupchat] : [.chat, .normal, .headline, nil]
        guard let reason = message.unreadableEncryption, types.contains(message.messageType) else { return false }
        await receiveEncryptedMessage(message, content: .undecryptable(reason), origin: .live, accountID: accountID)
        return true
    }

    /// Files a live encrypted room message. The room echoes the user's own messages, and the sending device never
    /// encrypts for itself. An undecryptable echo of a row this device stored therefore only records the room's
    /// stanza-id on that row.
    private func receiveEncryptedRoomMessage(_ stanza: XMPPMessage, content: EncryptedContent, accountID: UUID) async {
        guard let from = stanza.from, case let .full(occupant) = from else { return }
        let room = occupant.bareJID
        let metadata = InboundMessageMetadata(stanza)
        let (sentTime, isJoinHistory) = roomArrival(of: stanza, in: room, accountID: accountID)
        let isOwn = await isOwnRoomMessage(nickname: occupant.resourcePart, room: room, accountID: accountID)
        // One under the user's nickname that matches no row this device sent came from another device of theirs, and
        // shows its notice.
        if isOwn, case .undecryptable = content,
           let ownRow = await ownRow(echoedBy: metadata, ofEncrypted: true, body: "", in: room, accountID: accountID) {
            if let serverID = trustedServerID(in: metadata, trustedBy: room) {
                try? await recordServerID(serverID, on: ownRow)
            }
            return
        }
        let content = checkingTime(of: content, sentAt: sentTime)
        if case let .decrypted(message, _) = content,
           await applyAmendment(carriedBy: message, chatWith: from, sentAt: sentTime, isDecrypted: true, accountID: accountID) {
            return
        }
        // A message claiming to come from a room the user has no conversation with creates none.
        guard let conversation = try? await store.fetchConversation(jid: room.description, type: .groupchat, accountID: accountID, importSourceJID: nil)
        else { return }
        let arrival = EncryptedArrival(
            stanza: stanza, content: content, sender: occupant.resourcePart, isOutgoing: isOwn, sentTime: sentTime, isReplayed: isJoinHistory
        )
        await ingestEncryptedMessage(arrival, in: conversation, accountID: accountID)
    }

    /// A 1:1 message or a room's private message, live or from a carbon, filed in the chat with its peer: the recipient
    /// of a sent carbon, else the sender.
    private func receiveEncryptedChatMessage(
        _ stanza: XMPPMessage, content: EncryptedContent, origin: EncryptedMessageOrigin, accountID: UUID
    ) async {
        // Captured before the first wait, so the resource lock learned below advances in arrival order.
        let lockSequence = nextLockSequence()
        let isSentCarbon = if case .carbon(isOutgoing: true, _) = origin { true } else { false }
        guard let peer = isSentCarbon ? stanza.to : stanza.from else { return }
        let sentTime = switch origin {
        case .live: sentTime(of: stanza, accountID: accountID)
        case let .carbon(_, sentTime): sentTime
        }
        let content = checkingTime(of: content, sentAt: sentTime)
        if case let .decrypted(message, _) = content,
           await applyAmendment(carriedBy: message, chatWith: peer, sentAt: sentTime, isDecrypted: true, accountID: accountID) {
            return
        }
        guard let chat = await chat(with: peer, accountID: accountID) else { return }
        let isOutgoing = switch origin {
        case .live: await isOwnMessage(from: peer, in: chat.conversation, accountID: accountID)
        case let .carbon(isOutgoing, _): isOutgoing
        }
        let arrival = EncryptedArrival(
            stanza: stanza, content: content, sender: chat.occupant?.resourcePart ?? peer.bareJID.description, isOutgoing: isOutgoing,
            sentTime: sentTime
        )
        let outcome = await ingestEncryptedMessage(arrival, in: chat.conversation, accountID: accountID)
        // Only a new message from the contact that this device could read says something about them. A copy already
        // stored, as a stanza re-sent after a resume is, says nothing new, and a failed decrypt must not steer routing
        // or ground encrypting the reply.
        guard let outcome, outcome != .duplicate, !isOutgoing, case let .decrypted(message, _) = content else { return }
        learnChatStateUse(of: chat.occupant.map(ChatStateRecipient.occupant) ?? .contact(peer.bareJID), uses: message.chatState != nil, accountID: accountID)
        guard chat.occupant == nil else { return }
        if case .live = origin, let from = stanza.from {
            learnResourceLock(from: from, accountID: accountID, sequence: lockSequence)
        }
        await enableEncryptionForContact(in: chat.conversation.id, accountID: accountID)
    }

    /// A decrypted message whose envelope is stamped more than an hour off when it was sent is not trusted (XEP-0420),
    /// so a replayed old message cannot pass for a new one.
    private func checkingTime(of content: EncryptedContent, sentAt sentTime: Date) -> EncryptedContent {
        guard case let .decrypted(_, stamp?) = content else { return content }
        guard let time = Date(xmppTimestamp: stamp), abs(time.timeIntervalSince(sentTime)) <= Self.envelopeTimeTolerance else {
            log.warning("Encrypted message stamped at another time than it was sent")
            return .undecryptable(.mismatchedEnvelope)
        }
        return content
    }

    /// Whether a message from `from` is the user's own, sent from this or another of their devices.
    func isOwnMessage(from: JID, in conversation: Conversation, accountID: UUID) async -> Bool {
        switch conversation.type {
        case .groupchat:
            guard case let .full(occupant) = from else { return false }
            return await isOwnRoomMessage(nickname: occupant.resourcePart, room: conversation.jid, accountID: accountID)
        case .chat:
            return from.bareJID == resolvedAccountJID(for: accountID)
        }
    }

    /// Stores an encrypted message unless a copy of it is stored already, and gives a new one the attention a received
    /// message gets. Returns nil when there is nothing to store or the message could not be stored.
    @discardableResult
    func ingestEncryptedMessage(_ arrival: EncryptedArrival, in conversation: Conversation, accountID: UUID) async -> EncryptedMessageStoreOutcome? {
        guard var message = await transcriptRow(for: arrival, in: conversation, accountID: accountID) else { return nil }
        let outcome: EncryptedMessageStoreOutcome
        do {
            outcome = try await transcripts.storeEncryptedMessage(message, fromArchive: false)
        } catch {
            log.warning("Could not store an encrypted message: \(error)")
            return nil
        }
        switch outcome {
        case .inserted:
            await persistAndNotify(message, in: conversation, accountID: accountID, isStored: true, isReplayed: arrival.isReplayed)
        case let .upgraded(placeholderID, timestamp):
            // The archive's undecryptable copy now reads as this message, which is new to the user. The row is read
            // back, because a correction that reached the copy first keeps its text.
            message.id = placeholderID
            message.timestamp = timestamp
            let stored = try? await transcripts.findMessage(id: placeholderID, conversationID: conversation.id)
            await persistAndNotify(stored ?? message, in: conversation, accountID: accountID, isStored: true, isReplayed: arrival.isReplayed)
        case .duplicate:
            break
        }
        return outcome
    }

    /// The row an encrypted message is stored as: its ids from the stanza, the rest from what was encrypted. Nil for a
    /// decrypted message without a body or attachment, which carried only a chat state, a receipt or a marker.
    private func transcriptRow(for arrival: EncryptedArrival, in conversation: Conversation, accountID: UUID) async -> ChatMessage? {
        let metadata = InboundMessageMetadata(arrival.stanza)
        var message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            stanzaID: metadata.stanzaID,
            serverID: trustedServerID(in: metadata, trustedBy: conversation.type == .groupchat ? conversation.jid : resolvedAccountJID(for: accountID)),
            fromJID: arrival.sender,
            body: "",
            timestamp: arrival.sentTime,
            isOutgoing: arrival.isOutgoing,
            isDelivered: false,
            isEdited: false,
            type: conversation.type == .groupchat ? "groupchat" : "chat",
            isEncrypted: true
        )
        switch arrival.content {
        case let .decrypted(decrypted, _):
            let inner = InboundMessageMetadata(decrypted)
            guard let body = decrypted.body ?? inner.attachments.first?.url else { return nil }
            let replyFallbackRange = inner.replyFallbackRange(in: decrypted.body)
            let filtered = await filterBody(
                body, direction: arrival.isOutgoing ? .outgoing : .incoming, accountID: accountID, fallback: conversation.jid,
                isUnstyled: decrypted.isUnstyled, isEncrypted: true, attachments: inner.attachments, replyFallbackRange: replyFallbackRange
            )
            message.body = filtered.body
            message.htmlBody = filtered.htmlBody
            message.replyToID = inner.replyToID
            message.replyToJID = inner.replyToJID
            message.replyFallbackRange = replyFallbackRange
            message.attachments = inner.attachments
        case let .undecryptable(reason):
            message.isUndecryptable = true
            message.undecryptableReason = reason
        }
        return message
    }
}

extension XMPPMessage {
    /// Why an encrypted message without an OMEMO payload is shown only as a notice: it is encrypted with another
    /// method, or it names OMEMO but carries no payload to decrypt. Nil for any other message.
    var unreadableEncryption: UndecryptableReason? {
        guard isEncrypted, !isOMEMOEncrypted else { return nil }
        return otherEncryptionMethod.map { .otherMethod(name: $0.name) } ?? .decryptionFailed
    }
}

/// An encrypted message on its way to the transcript: the stanza it came in, what it holds, and who sent it when.
struct EncryptedArrival {
    let stanza: XMPPMessage
    let content: EncryptedContent
    /// What the row names as its sender: the contact's bare JID, or the occupant's nickname in a room or its private
    /// chat.
    let sender: String
    let isOutgoing: Bool
    let sentTime: Date
    /// Room history replayed on join, which neither counts as unread nor draws attention.
    var isReplayed = false
}
