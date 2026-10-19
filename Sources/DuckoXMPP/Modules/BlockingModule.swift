import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.blocking")

/// Manages the XMPP blocking command (XEP-0191) — block list retrieval, block/unblock contacts, and push notifications.
public final class BlockingModule: XMPPModule, Sendable {
    private struct State {
        var context: ModuleContext?
        var blockedJIDs: Set<BareJID> = []
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
        guard let context = state.withLock({ $0.context }) else { return }

        // Request block list
        var iq = XMPPIQ(type: .get, id: context.generateID())
        let blocklist = XMLElement(name: "blocklist", namespace: XMPPNamespaces.blocking)
        iq.element.addChild(blocklist)

        let result: XMLElement?
        do {
            result = try await context.sendIQ(iq)
        } catch is XMPPStanzaError {
            log.warning("Block list GET returned stanza error")
            return
        }

        guard let result else { return }

        let jids = result.children(named: "item").compactMap { element -> BareJID? in
            guard let jidStr = element.attribute("jid") else { return nil }
            return BareJID.parse(jidStr)
        }

        state.withLock { state in
            state.blockedJIDs = Set(jids)
        }

        log.info("Block list loaded: \(jids.count) items")
        context.emitEvent(.blockListLoaded(jids))
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
        let jids = child.children(named: "item").compactMap { item -> BareJID? in
            guard let jidStr = item.attribute("jid") else { return nil }
            return BareJID.parse(jidStr)
        }

        // XEP-0191 §3.6: Empty <unblock/> clears the entire block list. Announced as an empty list rather than per contact,
        // since a module built for a resumed stream never loaded the list it would name them from.
        if !isBlock, jids.isEmpty {
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

    // MARK: - Public API

    public var blockedJIDs: Set<BareJID> {
        state.withLock { $0.blockedJIDs }
    }

    public func blockContact(jid: BareJID) async throws {
        try await sendBlockingIQ(elementName: "block", jid: jid)
    }

    public func unblockContact(jid: BareJID) async throws {
        try await sendBlockingIQ(elementName: "unblock", jid: jid)
    }

    private func sendBlockingIQ(elementName: String, jid: BareJID) async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        var iq = XMPPIQ(type: .set, id: context.generateID())
        var element = XMLElement(name: elementName, namespace: XMPPNamespaces.blocking)
        let item = XMLElement(name: "item", attributes: ["jid": jid.description])
        element.addChild(item)
        iq.element.addChild(element)

        _ = try await context.sendIQ(iq)
    }
}
