import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.chat")

/// A decrypted message someone else sent, as the rules for requests for unencrypted messages and for switching
/// encryption on read it: who sent it and when, and whether their device is trusted for encryption.
struct ReceivedDecryptedMessage {
    let message: XMPPMessage
    let sender: String
    let sentTime: Date
    let isFromUntrustedDevice: Bool
}

/// A contact's request for unencrypted messages (XEP-0384 §5.7). It blocks encrypted sends in the conversation until the
/// user switches encryption off, and a later encrypted message from the contact, once the user has, is noted without
/// switching encryption back on. Only a message from a device trusted for encryption records a request or counts as
/// the contact sending encrypted messages again.
extension ChatService {
    /// Refuses an encrypted send in `conversation` while a request for unencrypted messages waits for the user's answer.
    func refuseWhilePlaintextRequested(in conversation: Conversation) throws {
        guard let request = conversation.unansweredPlaintextRequest else { return }
        throw ChatServiceError.plaintextRequested(requester: request.requester, reason: request.reason)
    }

    /// Takes up an encrypted message as `takeUpDecryptedMessage` does, unless the user sent it, it is room history
    /// replayed on join, or it could not be read.
    func takeUpEncryptedMessage(_ arrival: EncryptedArrival, storedAs outcome: EncryptedMessageStoreOutcome?, in conversation: Conversation, accountID: UUID) async {
        guard !arrival.isOutgoing, !arrival.isReplayed, case let .decrypted(message, _, isFromUntrustedDevice) = arrival.content else { return }
        let received = ReceivedDecryptedMessage(
            message: message, sender: arrival.sender, sentTime: arrival.sentTime, isFromUntrustedDevice: isFromUntrustedDevice
        )
        await takeUpDecryptedMessage(received, storedAs: outcome, in: conversation, accountID: accountID)
    }

    /// Takes up `received`, stored with `outcome`, the same way whether it arrived live, from a carbon, or at catch-up.
    /// A copy stored already (`outcome` is `.duplicate`) says nothing new. An opt-out is recorded, and never counts as
    /// the contact sending encrypted messages. An opt-out without a body is never stored, so its `outcome` is nil.
    ///
    /// Any other message stored in a 1:1 chat, new or replacing a notice, switches encryption on unless the user's
    /// switch-off or a held request keeps it off. Once the user answered a request by switching encryption off, a new
    /// message from a trusted device notes instead that the contact sent encrypted messages again. A replaced notice
    /// does not, since it can be older than the user's answer.
    func takeUpDecryptedMessage(
        _ received: ReceivedDecryptedMessage, storedAs outcome: EncryptedMessageStoreOutcome?, in conversation: Conversation, accountID: UUID
    ) async {
        guard outcome != .duplicate else { return }
        guard received.message.omemoOptOut == nil else {
            await noteOptOut(carriedBy: received, in: conversation, accountID: accountID)
            return
        }
        guard let outcome, conversation.isDirectChat else { return }
        if outcome == .inserted, !received.isFromUntrustedDevice, await noteResumedEncryption(in: conversation, accountID: accountID) { return }
        await enableEncryptionForContact(in: conversation, accountID: accountID)
    }

    /// Records the opt-out that `received`, a new decrypted message, carries: the conversation holds the request,
    /// confirmed when encryption is off already, and its timeline gets a note stamped its sent time. A 1:1 chat's note
    /// names no subject, so it names the contact as the chat shows them, and a room's names the occupant. One from a
    /// device not trusted for encryption is not recorded.
    ///
    /// The request the conversation holds already, answered or not, is not recorded again. Neither is an opt-out not sent
    /// after the newest note of the sender's request: an opt-out without a body is never stored, so a catch-up that
    /// reads it again after the user switched encryption back on is told apart only by that note.
    func noteOptOut(carriedBy received: ReceivedDecryptedMessage, in conversation: Conversation, accountID: UUID) async {
        let requester = received.sender
        let sentTime = received.sentTime
        guard !received.isFromUntrustedDevice, let optOut = received.message.omemoOptOut, plaintextRequestsInFlight.insert(conversation.id).inserted else { return }
        defer { plaintextRequestsInFlight.remove(conversation.id) }
        let reason = optOut.reason
        let subject = conversation.isDirectChat ? nil : requester
        guard conversation.plaintextRequest?.isSame(requester: requester, reason: reason) != true else { return }
        do {
            let notes = try await transcripts.fetchNotes(for: conversation.id, since: nil, before: nil)
            let seconds = { (date: Date) in date.timeIntervalSince1970.rounded(.down) }
            let noted = notes.filter { $0.kind == .plaintextRequested && $0.subject == subject }.map { seconds($0.timestamp) }.max()
            if let noted, seconds(sentTime) <= noted { return }
            let stored = try await store.updateConversation(conversation.id) {
                guard $0.plaintextRequest?.isSame(requester: requester, reason: reason) != true else { return }
                $0.plaintextRequest = PlaintextRequest(requester: requester, reason: reason, isConfirmed: !$0.encryptionEnabled)
            }
            try await loadConversations(for: accountID)
            guard stored?.plaintextRequest?.isSame(requester: requester, reason: reason) == true else { return }
            try await transcripts.appendNote(TimelineNote(
                conversationID: conversation.id, timestamp: sentTime, kind: .plaintextRequested, subject: subject, detail: reason
            ))
        } catch {
            log.warning("Could not record a request for unencrypted messages")
            log.debug("Could not record a request for unencrypted messages: \(error)")
            return
        }
        bumpRevision(for: conversation.id)
    }

    /// Notes that the contact of the 1:1 `conversation` sent a new encrypted message after the user answered their request
    /// for unencrypted messages by switching encryption off. The request is dropped and encryption stays off. Returns
    /// whether it did, so the message does not also switch encryption on.
    @discardableResult
    func noteResumedEncryption(in conversation: Conversation, accountID: UUID) async -> Bool {
        guard conversation.plaintextRequest?.isConfirmed == true, !conversation.encryptionEnabled,
              encryptionSwitchesInFlight.insert(conversation.id).inserted else { return false }
        defer { encryptionSwitchesInFlight.remove(conversation.id) }
        do {
            let stored = try await store.updateConversation(conversation.id) {
                guard $0.plaintextRequest?.isConfirmed == true, !$0.encryptionEnabled else { return }
                $0.plaintextRequest = nil
                $0.encryptionOptedOut = true
            }
            try await loadConversations(for: accountID)
            guard let stored, stored.plaintextRequest == nil, !stored.encryptionEnabled else { return false }
        } catch {
            log.warning("Could not drop a request for unencrypted messages")
            log.debug("Could not drop a request for unencrypted messages: \(error)")
            return false
        }
        do {
            try await transcripts.appendNote(TimelineNote(conversationID: conversation.id, kind: .encryptionResumedByContact))
        } catch {
            log.warning("Could not note that a contact sent encrypted messages again")
            log.debug("Could not note that a contact sent encrypted messages again: \(error)")
        }
        bumpRevision(for: conversation.id)
        return true
    }
}
