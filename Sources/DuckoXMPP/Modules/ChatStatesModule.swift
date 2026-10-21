import struct os.OSAllocatedUnfairLock

/// Implements XEP-0085 Chat State Notifications — sends and receives
/// typing indicators and other chat state changes.
public final class ChatStatesModule: XMPPModule, Sendable {
    private let state: OSAllocatedUnfairLock<ModuleContext?>

    public var features: [String] {
        [XMPPNamespaces.chatStates]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: nil)
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0 = context }
    }

    // MARK: - Message Handling

    /// A chat state next to an OMEMO payload is outside the encryption, so only the decrypted copy's counts.
    public func handleMessage(_ message: XMPPMessage) throws {
        guard !message.isOMEMOEncrypted else { return }
        handleChatState(in: message)
    }

    public func handleDecryptedMessage(_ message: XMPPMessage) {
        handleChatState(in: message)
    }

    private func handleChatState(in message: XMPPMessage) {
        // An error bounces the user's own stanza back, with the chat state it carried.
        guard let from = message.from, let messageType = message.messageType, messageType != .error,
              let chatState = message.chatState else { return }

        let context = state.withLock { $0 }
        context?.emitEvent(.chatStateChanged(from: from, state: chatState, messageType: messageType))
    }

    // MARK: - Sending

    /// Sends a standalone chat state notification to the given JID. A standalone notification carries no other child
    /// (XEP-0085 §5.6).
    /// Pass `messageType: .groupchat` for MUC — `<gone/>` will be suppressed per XEP-0085.
    public func sendChatState(_ chatState: ChatState, to recipient: JID, messageType: XMPPMessage.MessageType = .chat) async throws {
        // XEP-0085: "A client SHOULD NOT generate <gone/> notifications in groupchat"
        if messageType == .groupchat, chatState == .gone { return }

        guard let context = state.withLock({ $0 }) else { return }
        var message = XMPPMessage(type: messageType, to: recipient, id: context.generateID())
        let child = XMLElement(name: chatState.rawValue, namespace: XMPPNamespaces.chatStates)
        message.element.addChild(child)
        try await context.sendStanza(message)
    }
}

public extension XMPPMessage {
    /// The chat state the message carries, standalone or next to its content.
    var chatState: ChatState? {
        ChatState.allCases.first { element.child(named: $0.rawValue, namespace: XMPPNamespaces.chatStates) != nil }
    }
}
