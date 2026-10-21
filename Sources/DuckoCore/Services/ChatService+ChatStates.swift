import DuckoXMPP
import Foundation

/// Where the user's chat states (XEP-0085) go: a contact, a room, or a room's occupant in a private chat. Each is a
/// conversation of its own, with its own last state sent and its own pending `paused`.
enum ChatStateRecipient: Hashable {
    case contact(BareJID)
    case room(BareJID)
    case occupant(FullJID)
}

/// The chat states the user sends. One goes out only when it changes, and a contact or occupant whose last message came
/// without one gets none, standalone or attached to a message, until they send one again (XEP-0085 §5.1). A room gets
/// them whatever its occupants send.
public extension ChatService {
    /// `occupantNickname` names the occupant of the room `jid` in a private chat.
    func userIsTyping(in jid: BareJID, occupantNickname: String? = nil, accountID: UUID) async {
        guard let recipient = chatStateRecipient(for: jid, occupantNickname: occupantNickname, accountID: accountID),
              sendsChatStates(to: recipient, accountID: accountID),
              let client = accountService?.connectedClient(for: accountID),
              let module = await client.module(ofType: ChatStatesModule.self) else { return }

        typingDebounce[accountID]?[recipient]?.cancel()
        typingDebounce[accountID, default: [:]][recipient] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            typingDebounce[accountID]?[recipient] = nil
            await sendChatState(.paused, to: recipient, module: module, accountID: accountID)
        }
        await sendChatState(.composing, to: recipient, module: module, accountID: accountID)
    }

    func userIsTyping(inJIDString jidString: String, occupantNickname: String? = nil, accountID: UUID) async {
        guard let jid = BareJID.parse(jidString) else { return }
        await userIsTyping(in: jid, occupantNickname: occupantNickname, accountID: accountID)
    }
}

extension ChatService {
    /// The `<active/>` a content message to `recipient` carries when chat states go there, for a send that adds its
    /// own elements.
    func attachedChatState(for recipient: ChatStateRecipient, accountID: UUID) -> [DuckoXMPP.XMLElement] {
        guard sendsChatStates(to: recipient, accountID: accountID) else { return [] }
        return [DuckoXMPP.XMLElement(name: ChatState.active.rawValue, namespace: XMPPNamespaces.chatStates)]
    }

    func sendsChatStates(to recipient: ChatStateRecipient, accountID: UUID) -> Bool {
        ChatPreferences.shared.enableChatStates && chatStateSilentPeers[accountID]?.contains(recipient) != true
    }

    /// Notes a content message sent to `recipient`, which ends the typing there. The state it carried, if any, is the
    /// last one sent.
    func didSendContentMessage(to recipient: ChatStateRecipient, carryingChatState: Bool, accountID: UUID) {
        typingDebounce[accountID]?.removeValue(forKey: recipient)?.cancel()
        sentChatStates[accountID, default: [:]][recipient] = carryingChatState ? .active : nil
    }

    /// Learns from a content message `peer` sent whether they use chat states. An encrypted message's state travels
    /// inside the encryption, so the stanza around it tells nothing.
    func learnChatStateUse(of peer: ChatStateRecipient, from message: XMPPMessage, accountID: UUID) {
        guard !message.isEncrypted else { return }
        learnChatStateUse(of: peer, uses: message.chatState != nil, accountID: accountID)
    }

    /// Records whether `peer` uses chat states: a content message without one says they do not, and any state from them
    /// says they do. Never fed by a room's own messages, since a room keeps getting the user's states.
    func learnChatStateUse(of peer: ChatStateRecipient, uses: Bool, accountID: UUID) {
        if uses {
            chatStateSilentPeers[accountID]?.remove(peer)
        } else {
            chatStateSilentPeers[accountID, default: []].insert(peer)
        }
    }

    /// The contact or occupant a chat state from `sender` comes from. An occupant writes from the room's address, with
    /// their nickname as the resource.
    func chatStatePeer(_ sender: JID, accountID: UUID) -> ChatStateRecipient {
        if case let .full(occupant) = sender, isOpenRoom(occupant.bareJID, accountID: accountID) {
            return .occupant(occupant)
        }
        return .contact(sender.bareJID)
    }

    /// Forgets the account's chat states sent and pending `paused`s, which belong to the session that ended. What was
    /// learned about its peers stays, since a peer that sends no chat states gets none in the next session either.
    func clearOutgoingChatStates(for accountID: UUID) {
        let pendingPauses = typingDebounce.removeValue(forKey: accountID) ?? [:]
        for task in pendingPauses.values {
            task.cancel()
        }
        sentChatStates.removeValue(forKey: accountID)
    }

    /// Forgets which of a deleted account's peers send no chat states.
    func forgetAccount(_ accountID: UUID) {
        chatStateSilentPeers.removeValue(forKey: accountID)
    }

    private func chatStateRecipient(for jid: BareJID, occupantNickname: String?, accountID: UUID) -> ChatStateRecipient? {
        if let occupantNickname {
            return FullJID(bareJID: jid, resourcePart: occupantNickname).map(ChatStateRecipient.occupant)
        }
        return isOpenRoom(jid, accountID: accountID) ? .room(jid) : .contact(jid)
    }

    private func isOpenRoom(_ jid: BareJID, accountID: UUID) -> Bool {
        openConversations.contains { $0.jid == jid && $0.type == .groupchat && $0.accountID == accountID }
    }

    /// Sends `state` to `recipient` unless it is the last state sent there. Once chat states no longer go there, the
    /// last one sent is forgotten instead.
    private func sendChatState(_ state: ChatState, to recipient: ChatStateRecipient, module: ChatStatesModule, accountID: UUID) async {
        guard sendsChatStates(to: recipient, accountID: accountID) else {
            sentChatStates[accountID]?[recipient] = nil
            return
        }
        guard sentChatStates[accountID]?[recipient] != state else { return }
        sentChatStates[accountID, default: [:]][recipient] = state
        switch recipient {
        case let .contact(jid):
            try? await module.sendChatState(state, to: recipientJID(for: jid, accountID: accountID))
        case let .room(room):
            try? await module.sendChatState(state, to: .bare(room), messageType: .groupchat)
        case let .occupant(occupant):
            try? await module.sendChatState(state, to: .full(occupant))
        }
    }
}
