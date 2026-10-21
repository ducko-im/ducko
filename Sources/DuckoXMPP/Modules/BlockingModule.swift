import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.blocking")

/// Manages the XMPP blocking command (XEP-0191) — block list retrieval, block/unblock contacts, and push notifications.
public final class BlockingModule: XMPPModule, Sendable {
    public enum BlockingError: Error {
        case notConnected
        case blockingNotSupported
    }

    private struct State {
        var context: ModuleContext?
        var blockedJIDs: Set<JID> = []
        /// Whether the server advertises blocking, once its disco#info has answered.
        var isSupported: Bool?
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        [XMPPNamespaces.blocking]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleConnect() async throws {
        do {
            try await loadBlockList()
        } catch BlockingError.blockingNotSupported {
            log.info("The server does not support blocking")
        } catch is XMPPStanzaError {
            log.warning("Block list request returned a stanza error")
        }
    }

    public func handleDisconnect() async {
        state.withLock { $0.blockedJIDs.removeAll() }
    }

    // MARK: - IQ Handling

    public func handleIQ(_ iq: XMPPIQ) throws -> Bool {
        guard iq.isSet, let child = iq.childElement else { return false }

        let isBlock = child.name == "block" && child.namespace == XMPPNamespaces.blocking
        let isUnblock = child.name == "unblock" && child.namespace == XMPPNamespaces.blocking
        guard isBlock || isUnblock else { return false }

        let context = state.withLock { $0.context }
        guard let context else { return true }

        guard iq.isFromOwnAccount(context.connectedJID()?.bareJID) else {
            log.warning("Rejected blocking push from an unexpected sender")
            return true
        }

        processBlockingPush(child: child, isBlock: isBlock, context: context)
        acknowledgePush(iq: iq, context: context)
        return true
    }

    private func processBlockingPush(child: XMLElement, isBlock: Bool, context: ModuleContext) {
        let items = child.children(named: "item")
        let jids = Self.itemJIDs(in: child)

        // XEP-0191 §3.5: An <unblock/> with no items clears the entire block list. Announced as an empty list rather than
        // per contact, since a module built for a resumed stream never loaded the list it would name them from.
        if !isBlock, items.isEmpty {
            state.withLock { $0.blockedJIDs.removeAll() }
            log.info("Block list cleared")
            context.emitEvent(.blockListLoaded([]))
            return
        }

        state.withLock { state in
            for jid in jids {
                if isBlock {
                    state.blockedJIDs.insert(jid)
                } else {
                    state.blockedJIDs.remove(jid)
                }
            }
        }

        for jid in jids {
            if isBlock {
                log.info("Contact blocked")
                log.debug("The blocked contact is \(jid)")
                context.emitEvent(.contactBlocked(jid))
            } else {
                log.info("Contact unblocked")
                log.debug("The unblocked contact is \(jid)")
                context.emitEvent(.contactUnblocked(jid))
            }
        }
    }

    private func acknowledgePush(iq: XMPPIQ, context: ModuleContext) {
        guard let result = XMPPIQ.resultReply(for: iq) else { return }
        Task {
            do {
                try await context.sendStanza(result)
            } catch {
                log.warning("Failed to acknowledge blocking push: \(error)")
            }
        }
    }

    private static func itemJIDs(in element: XMLElement) -> [JID] {
        element.children(named: "item").compactMap { item in
            item.attribute("jid").flatMap(JID.parse)
        }
    }

    // MARK: - Public API

    public var blockedJIDs: Set<JID> {
        state.withLock { $0.blockedJIDs }
    }

    /// Requests the block list from the server, announcing it as `.blockListLoaded`.
    @discardableResult
    public func loadBlockList() async throws -> [JID] {
        let context = try await supportedContext()

        var iq = XMPPIQ(type: .get, id: context.generateID())
        iq.element.addChild(XMLElement(name: "blocklist", namespace: XMPPNamespaces.blocking))
        let jids = try await context.sendIQ(iq).map(Self.itemJIDs) ?? []

        state.withLock { $0.blockedJIDs = Set(jids) }
        log.info("Block list loaded: \(jids.count) items")
        context.emitEvent(.blockListLoaded(jids))
        return jids
    }

    public func blockContact(jid: JID) async throws {
        try await sendBlockingIQ(elementName: "block", jid: jid)
    }

    public func unblockContact(jid: JID) async throws {
        try await sendBlockingIQ(elementName: "unblock", jid: jid)
    }

    private func sendBlockingIQ(elementName: String, jid: JID) async throws {
        let context = try await supportedContext()

        var iq = XMPPIQ(type: .set, id: context.generateID())
        var element = XMLElement(name: elementName, namespace: XMPPNamespaces.blocking)
        let item = XMLElement(name: "item", attributes: ["jid": jid.description])
        element.addChild(item)
        iq.element.addChild(element)

        _ = try await context.sendIQ(iq)
    }

    // MARK: - Support (XEP-0191 §3.1)

    /// The module's context once the server's disco#info lists blocking, asking the server on first use.
    private func supportedContext() async throws -> ModuleContext {
        let (context, known) = state.withLock { ($0.context, $0.isSupported) }
        guard let context else { throw BlockingError.notConnected }

        let isSupported: Bool
        if let known {
            isSupported = known
        } else {
            isSupported = try await serverAdvertisesBlocking(context: context)
            state.withLock { $0.isSupported = isSupported }
        }
        guard isSupported else { throw BlockingError.blockingNotSupported }
        return context
    }

    private func serverAdvertisesBlocking(context: ModuleContext) async throws -> Bool {
        guard let domainJID = JID.parse(context.domain) else { return false }

        var iq = XMPPIQ(type: .get, to: domainJID, id: context.generateID())
        iq.element.addChild(XMLElement(name: "query", namespace: XMPPNamespaces.discoInfo))

        let result = try await context.sendIQ(iq)
        return result?.children(named: "feature").contains { $0.attribute("var") == XMPPNamespaces.blocking } ?? false
    }
}
