import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.receipts")

/// Implements XEP-0184 Message Delivery Receipts and XEP-0333 Chat Markers —
/// auto-replies to receipt requests and emits events for incoming receipts/markers.
public final class ReceiptsModule: XMPPModule, Sendable {
    private let state: OSAllocatedUnfairLock<ModuleContext?>

    public var features: [String] {
        [XMPPNamespaces.receipts, XMPPNamespaces.chatMarkers]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: nil)
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0 = context }
    }

    // MARK: - Message Handling

    /// A receipt or marker next to an OMEMO payload is outside the encryption, so only the decrypted copy's counts.
    public func handleMessage(_ message: XMPPMessage) throws {
        guard !message.isOMEMOEncrypted else { return }
        handleReceiptsAndMarkers(in: message)
    }

    public func handleDecryptedMessage(_ message: XMPPMessage) {
        handleReceiptsAndMarkers(in: message)
    }

    private func handleReceiptsAndMarkers(in message: XMPPMessage) {
        guard let from = message.from else { return }
        let context = state.withLock { $0 }

        // XEP-0184: Incoming receipt request — auto-reply for chat messages with body
        if message.element.child(named: "request", namespace: XMPPNamespaces.receipts) != nil,
           message.messageType == .chat,
           message.body != nil,
           let stanzaID = message.id {
            sendReceiptReply(to: from, messageID: stanzaID)
        }

        // XEP-0184: Incoming delivery receipt
        if let received = message.element.child(named: "received", namespace: XMPPNamespaces.receipts),
           let messageID = received.attribute("id") {
            context?.emitEvent(.deliveryReceiptReceived(messageID: messageID, from: from))
        }

        // XEP-0333: Incoming chat markers
        for markerType in ChatMarkerType.allCases {
            if let marker = message.element.child(named: markerType.rawValue, namespace: XMPPNamespaces.chatMarkers),
               let messageID = marker.attribute("id") {
                context?.emitEvent(.chatMarkerReceived(messageID: messageID, type: markerType, from: from))
                break
            }
        }
    }

    // MARK: - Sending

    /// Sends a `displayed` chat marker to indicate the message was read.
    public func sendDisplayedMarker(to recipient: JID, messageID: String, messageType: XMPPMessage.MessageType = .chat) async throws {
        guard let context = state.withLock({ $0 }) else { return }
        var message = XMPPMessage(type: messageType, to: recipient, id: context.generateID())
        let marker = XMLElement(
            name: "displayed",
            namespace: XMPPNamespaces.chatMarkers,
            attributes: ["id": messageID]
        )
        message.element.addChild(marker)
        // Carbons suppression only applies to 1:1 chat messages
        if messageType == .chat {
            message.element.addChild(XMLElement(name: "private", namespace: XMPPNamespaces.carbons))
        }
        try await context.sendStanza(message)
    }

    private func sendReceiptReply(to recipient: JID, messageID: String) {
        let context = state.withLock { $0 }
        guard let context else { return }
        Task {
            var reply = XMPPMessage(type: .chat, to: recipient, id: context.generateID())
            let received = XMLElement(
                name: "received",
                namespace: XMPPNamespaces.receipts,
                attributes: ["id": messageID]
            )
            reply.element.addChild(received)
            reply.element.addChild(XMLElement(name: "private", namespace: XMPPNamespaces.carbons))
            do {
                try await context.sendStanza(reply)
            } catch {
                log.warning("Failed to send delivery receipt: \(error)")
            }
        }
    }
}
