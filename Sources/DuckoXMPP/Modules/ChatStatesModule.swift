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

    public func handleMessage(_ message: XMPPMessage) throws {
        guard let from = message.from?.bareJID, let chatState = ChatState.allCases.first(where: {
            message.element.child(named: $0.rawValue, namespace: XMPPNamespaces.chatStates) != nil
        }) else { return }

        let context = state.withLock { $0 }
        context?.emitEvent(.chatStateChanged(from: from, state: chatState))
    }

    // MARK: - Sending

    /// Sends a standalone chat state notification to the given JID.
    /// Pass `messageType: .groupchat` for MUC — `<gone/>` will be suppressed per XEP-0085.
    public func sendChatState(_ chatState: ChatState, to recipient: JID, messageType: XMPPMessage.MessageType = .chat) async throws {
        // XEP-0085: "A client SHOULD NOT generate <gone/> notifications in groupchat"
        if messageType == .groupchat, chatState == .gone { return }

        guard let context = state.withLock({ $0 }) else { return }
        var message = XMPPMessage(type: messageType, to: recipient, id: context.generateID())
        let child = XMLElement(name: chatState.rawValue, namespace: XMPPNamespaces.chatStates)
        message.element.addChild(child)
        if messageType == .chat {
            message.element.addChild(XMLElement(name: "private", namespace: XMPPNamespaces.carbons))
        }
        try await context.sendStanza(message)
    }
}
