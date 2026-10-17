import struct os.OSAllocatedUnfairLock

/// XEP-0424 fallback body for clients that don't support message retraction.
package let retractionFallbackBody = "This person attempted to retract a previous message, but it's unsupported by your client."

/// Handles 1:1 `<message>` stanzas with `type="chat"` or `type="normal"`,
/// including XEP-0308 corrections and XEP-0461 replies.
public final class ChatModule: XMPPModule, Sendable {
    private let state: OSAllocatedUnfairLock<ModuleContext?>

    public var features: [String] {
        [XMPPNamespaces.messageRetract, XMPPNamespaces.messageCorrect, XMPPNamespaces.oob]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: nil)
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0 = context }
    }

    public func handleMessage(_ message: XMPPMessage) throws {
        guard message.messageType == .chat || message.messageType == .normal || message.messageType == .error, let from = message.from else { return }

        let context = state.withLock { $0 }

        // Error messages
        if message.messageType == .error {
            let stanzaError = XMPPStanzaError.parse(from: message.element.child(named: "error"))
                ?? XMPPStanzaError(errorType: .cancel, condition: .undefinedCondition)
            context?.emitEvent(.messageError(messageID: message.id, from: from, error: stanzaError))
            return
        }

        // Encrypted corrections/retractions are classified by OMEMOModule after decryption
        if message.element.child(named: "encrypted", namespace: XMPPNamespaces.omemo) != nil {
            return
        }

        // XEP-0424: Message retraction
        if let retract = message.element.child(named: "retract", namespace: XMPPNamespaces.messageRetract),
           let originalID = retract.attribute("id") {
            context?.emitEvent(.messageRetracted(originalID: originalID, from: from))
            return
        }

        // XEP-0308: Message correction
        if let replace = message.element.child(named: "replace", namespace: XMPPNamespaces.messageCorrect),
           let originalID = replace.attribute("id"),
           let newBody = message.body {
            context?.emitEvent(.messageCorrected(originalID: originalID, newBody: newBody, from: from))
            return
        }

        // Regular chat messages require a body
        guard message.body != nil else { return }
    }

    // MARK: - Sending

    /// Sends a chat message to the given JID.
    public func sendMessage(
        to recipient: JID,
        body: String,
        id: String? = nil,
        requestReceipt: Bool = false,
        markable: Bool = false,
        includeChatState: Bool = true,
        additionalElements: [XMLElement] = []
    ) async throws {
        guard let context = state.withLock({ $0 }) else { return }
        let stanzaID = id ?? context.generateID()
        var message = XMPPMessage(type: .chat, to: recipient, id: stanzaID)
        message.body = body
        if requestReceipt {
            let request = XMLElement(name: "request", namespace: XMPPNamespaces.receipts)
            message.element.addChild(request)
        }
        if markable {
            let markableElement = XMLElement(name: "markable", namespace: XMPPNamespaces.chatMarkers)
            message.element.addChild(markableElement)
        }
        if includeChatState {
            let active = XMLElement(name: "active", namespace: XMPPNamespaces.chatStates)
            message.element.addChild(active)
        }
        for element in additionalElements {
            message.element.addChild(element)
        }
        try await context.sendStanza(message)
    }

    /// Sends a message correction (XEP-0308) replacing a previously sent message.
    public func sendCorrection(
        to recipient: JID,
        body: String,
        replacingID: String,
        id: String? = nil,
        includeChatState: Bool = true
    ) async throws {
        guard let context = state.withLock({ $0 }) else { return }
        let stanzaID = id ?? context.generateID()
        var message = XMPPMessage(type: .chat, to: recipient, id: stanzaID)
        message.body = body
        let replace = XMLElement(
            name: "replace",
            namespace: XMPPNamespaces.messageCorrect,
            attributes: ["id": replacingID]
        )
        message.element.addChild(replace)
        if includeChatState {
            let active = XMLElement(name: "active", namespace: XMPPNamespaces.chatStates)
            message.element.addChild(active)
        }
        try await context.sendStanza(message)
    }

    /// Sends a reply (XEP-0461) to a specific message.
    public func sendReply(
        to recipient: JID,
        body: String,
        replyToID: String,
        replyToJID: JID,
        id: String? = nil,
        includeChatState: Bool = true
    ) async throws {
        guard let context = state.withLock({ $0 }) else { return }
        let stanzaID = id ?? context.generateID()
        var message = XMPPMessage(type: .chat, to: recipient, id: stanzaID)
        message.body = body
        let reply = XMLElement(
            name: "reply",
            namespace: XMPPNamespaces.messageReply,
            attributes: ["to": replyToJID.description, "id": replyToID]
        )
        message.element.addChild(reply)
        if includeChatState {
            let active = XMLElement(name: "active", namespace: XMPPNamespaces.chatStates)
            message.element.addChild(active)
        }
        try await context.sendStanza(message)
    }

    /// Sends a message retraction (XEP-0424) for a previously sent message.
    public func sendRetraction(to recipient: JID, originalID: String) async throws {
        guard let context = state.withLock({ $0 }) else { return }
        var message = XMPPMessage(type: .chat, to: recipient, id: context.generateID())
        let retract = XMLElement(
            name: "retract",
            namespace: XMPPNamespaces.messageRetract,
            attributes: ["id": originalID]
        )
        message.element.addChild(retract)
        let fallback = XMLElement(name: "fallback", namespace: XMPPNamespaces.fallbackIndication, attributes: ["for": XMPPNamespaces.messageRetract])
        message.element.addChild(fallback)
        message.body = retractionFallbackBody
        let store = XMLElement(name: "store", namespace: XMPPNamespaces.processingHints)
        message.element.addChild(store)
        try await context.sendStanza(message)
    }
}
