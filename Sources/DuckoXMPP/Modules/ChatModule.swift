import struct os.OSAllocatedUnfairLock

/// XEP-0424 fallback body for clients that don't support message retraction.
package let retractionFallbackBody = "This person attempted to retract a previous message, but it's unsupported by your client."

/// Handles 1:1 `<message>` stanzas with `type="chat"` or `type="normal"`,
/// including XEP-0308 corrections and XEP-0461 replies.
public final class ChatModule: XMPPModule, Sendable {
    private let state: OSAllocatedUnfairLock<ModuleContext?>

    public var features: [String] {
        [XMPPNamespaces.messageRetract, XMPPNamespaces.messageCorrect, XMPPNamespaces.messageReply, XMPPNamespaces.oob]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: nil)
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0 = context }
    }

    public func handleMessage(_ message: XMPPMessage) throws {
        guard let messageType = message.messageType, messageType == .chat || messageType == .normal || messageType == .error,
              let from = message.from else { return }

        let context = state.withLock { $0 }

        // Error messages
        if messageType == .error {
            let stanzaError = XMPPStanzaError.parse(from: message.element.child(named: "error"))
                ?? XMPPStanzaError(errorType: .cancel, condition: .undefinedCondition)
            context?.emitEvent(.messageError(messageID: message.id, from: from, error: stanzaError))
            return
        }

        // An encrypted message's corrections and retractions are only read from inside its encryption, by OMEMOModule
        // after decryption. One encrypted with another method shows only its notice (XEP-0380).
        if message.isEncrypted {
            return
        }

        // XEP-0424: Message retraction
        if let retract = message.element.child(named: "retract", namespace: XMPPNamespaces.messageRetract),
           let originalID = retract.attribute("id") {
            context?.emitEvent(.messageRetracted(originalID: originalID, from: from, messageType: messageType))
            return
        }

        // XEP-0308: Message correction
        if let replace = message.element.child(named: "replace", namespace: XMPPNamespaces.messageCorrect),
           let originalID = replace.attribute("id"),
           let newBody = message.body {
            context?.emitEvent(.messageCorrected(
                originalID: originalID, newBody: newBody, replyFallbackRange: message.replyFallbackRange(in: newBody), from: from, messageType: messageType
            ))
            return
        }

        // Regular chat messages require a body
        guard message.body != nil else { return }
    }

    // MARK: - Sending

    /// Sends a chat message to the given JID. An encrypted message carries no body.
    public func sendMessage(
        to recipient: JID,
        body: String?,
        id: String? = nil,
        requestReceipt: Bool = false,
        markable: Bool = false,
        includeChatState: Bool = true,
        additionalElements: [XMLElement] = []
    ) async throws {
        guard let context = state.withLock({ $0 }) else { return }
        let stanzaID = id ?? context.generateID()
        var message = XMPPMessage(type: .chat, to: recipient, originID: stanzaID)
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

    /// Sends a message correction (XEP-0308) replacing a previously sent message. A correction re-sends everything the
    /// original carried (§4). `reply` re-adds the reply reference and puts its quote before `body`, and the other
    /// arguments re-add the original's other elements.
    public func sendCorrection(
        to recipient: JID,
        body: String,
        replacingID: String,
        reply: MessageReply? = nil,
        id: String? = nil,
        requestReceipt: Bool = false,
        markable: Bool = false,
        includeChatState: Bool = true,
        additionalElements: [XMLElement] = []
    ) async throws {
        let replace = XMLElement(
            name: "replace",
            namespace: XMPPNamespaces.messageCorrect,
            attributes: ["id": replacingID]
        )
        try await sendMessage(
            to: recipient, body: reply?.body(replying: body) ?? body, id: id,
            requestReceipt: requestReceipt, markable: markable, includeChatState: includeChatState,
            additionalElements: [replace] + (reply?.elements ?? []) + additionalElements
        )
    }

    /// Sends a message retraction (XEP-0424) for a previously sent message.
    public func sendRetraction(to recipient: JID, originalID: String, includeChatState: Bool = true) async throws {
        let retract = XMLElement(
            name: "retract",
            namespace: XMPPNamespaces.messageRetract,
            attributes: ["id": originalID]
        )
        let store = XMLElement(name: "store", namespace: XMPPNamespaces.processingHints)
        try await sendMessage(
            to: recipient, body: retractionFallbackBody, includeChatState: includeChatState,
            additionalElements: [retract, FallbackIndication(for: XMPPNamespaces.messageRetract).element, store]
        )
    }
}
