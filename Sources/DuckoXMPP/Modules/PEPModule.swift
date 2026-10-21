import struct os.OSAllocatedUnfairLock

/// Implements XEP-0163 Personal Eventing Protocol — publish, retrieve,
/// retract PEP items and dispatch incoming PEP notifications.
public final class PEPModule: XMPPModule, Sendable {
    // MARK: - State

    private struct State {
        var context: ModuleContext?
        var notifyNodes: Set<String> = []
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        let nodes = state.withLock { $0.notifyNodes }
        return [XMPPNamespaces.pubsub] + nodes.map { $0 + "+notify" }.sorted()
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Notify Interest

    /// Registers interest in PEP notifications for a node namespace.
    /// Call before registering the module with the client so the `+notify`
    /// feature is included in the entity capabilities hash.
    public func registerNotifyInterest(_ namespace: String) {
        state.withLock { $0.notifyNodes.insert(namespace) }
    }

    /// Removes interest in PEP notifications for a node namespace.
    public func unregisterNotifyInterest(_ namespace: String) {
        state.withLock { $0.notifyNodes.remove(namespace) }
    }

    // MARK: - Public API

    /// Publishes an item to a PEP node.
    public func publishItem(
        node: String,
        itemID: String,
        payload: XMLElement,
        options: [DataFormField]? = nil
    ) async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        var iq = XMPPIQ(type: .set, id: context.generateID())
        var pubsub = XMLElement(name: "pubsub", namespace: XMPPNamespaces.pubsub)

        var publish = XMLElement(name: "publish", attributes: ["node": node])
        var item = XMLElement(name: "item", attributes: ["id": itemID])
        item.addChild(payload)
        publish.addChild(item)
        pubsub.addChild(publish)

        if let options {
            var publishOptions = XMLElement(name: "publish-options")
            publishOptions.addChild(buildSubmitForm(options))
            pubsub.addChild(publishOptions)
        }

        iq.element.addChild(pubsub)
        _ = try await context.sendIQ(iq)
    }

    /// Retrieves items from a PEP node.
    public func retrieveItems(
        node: String,
        from jid: BareJID? = nil,
        itemID: String? = nil,
        maxItems: Int? = nil
    ) async throws -> [PEPItem] {
        guard let context = state.withLock({ $0.context }) else { return [] }

        let to: JID? = jid.map { .bare($0) }
        var iq = XMPPIQ(type: .get, to: to, id: context.generateID())
        var pubsub = XMLElement(name: "pubsub", namespace: XMPPNamespaces.pubsub)

        var attrs: [String: String] = ["node": node]
        if let maxItems {
            attrs["max_items"] = "\(maxItems)"
        }
        var items = XMLElement(name: "items", attributes: attrs)
        if let itemID {
            items.addChild(XMLElement(name: "item", attributes: ["id": itemID]))
        }
        pubsub.addChild(items)
        iq.element.addChild(pubsub)

        guard let result = try await context.sendIQ(iq), let itemsElement = result.child(named: "items") else { return [] }
        return parsePublishedItems(itemsElement)
    }

    /// Retracts an item from a PEP node. With `notify`, the server tells the node's subscribers about the retraction.
    public func retractItem(node: String, itemID: String, notify: Bool = false) async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        var iq = XMPPIQ(type: .set, id: context.generateID())
        var pubsub = XMLElement(name: "pubsub", namespace: XMPPNamespaces.pubsub)

        var attrs = ["node": node]
        if notify {
            attrs["notify"] = "true"
        }
        var retract = XMLElement(name: "retract", attributes: attrs)
        let item = XMLElement(name: "item", attributes: ["id": itemID])
        retract.addChild(item)
        pubsub.addChild(retract)
        iq.element.addChild(pubsub)

        _ = try await context.sendIQ(iq)
    }

    /// Deletes a whole PEP node via XEP-0060 §8.4 (`pubsub#owner`).
    public func deleteNode(node: String) async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        var iq = XMPPIQ(type: .set, id: context.generateID())
        var pubsub = XMLElement(name: "pubsub", namespace: XMPPNamespaces.pubsubOwner)

        let delete = XMLElement(name: "delete", attributes: ["node": node])
        pubsub.addChild(delete)
        iq.element.addChild(pubsub)

        _ = try await context.sendIQ(iq)
    }

    // MARK: - Message Handling

    public func handleMessage(_ message: XMPPMessage) throws {
        guard let event = message.element.child(named: "event", namespace: XMPPNamespaces.pubsubEvent),
              let itemsElement = event.child(named: "items"),
              let node = itemsElement.attribute("node") else {
            return
        }

        let (registeredNodes, context) = state.withLock { ($0.notifyNodes, $0.context) }
        // A notification comes from the publisher's bare JID (XEP-0163), so any other sender publishes nothing.
        guard registeredNodes.contains(node), let context,
              let from = message.bareSender(orOwn: context.connectedJID()?.bareJID) else { return }

        let (published, retracted) = parseItems(itemsElement)

        if !published.isEmpty {
            context.emitEvent(.pepItemsPublished(from: from, node: node, items: published))
        }
        if !retracted.isEmpty {
            context.emitEvent(.pepItemsRetracted(from: from, node: node, itemIDs: retracted))
        }
    }

    // MARK: - Parsing

    private func parseItems(_ itemsElement: XMLElement) -> (published: [PEPItem], retracted: [String]) {
        let published = parsePublishedItems(itemsElement)

        let retracted = itemsElement.children(named: "retract").compactMap { retractElement in
            retractElement.attribute("id")
        }

        return (published, retracted)
    }

    private func parsePublishedItems(_ itemsElement: XMLElement) -> [PEPItem] {
        itemsElement.children(named: "item").compactMap { itemElement in
            guard let id = itemElement.attribute("id") else { return nil }
            for case let .element(payload) in itemElement.children {
                return PEPItem(id: id, payload: payload)
            }
            return nil
        }
    }
}

public extension ServiceDiscoveryModule.InfoResult {
    /// Whether the account whose disco#info this is can publish to its PEP service (XEP-0163 §6.1).
    var supportsPEPPublishing: Bool {
        identities.contains { $0.category == "pubsub" && $0.type == "pep" }
            && features.contains(XMPPNamespaces.pubsubPublish)
    }

    /// Whether the account whose disco#info this is may keep private data in PEP: XEP-0223 §5 requires the server
    /// to offer PEP and publish-options, which is what keeps the data private.
    var supportsPrivatePEPStorage: Bool {
        identities.contains { $0.category == "pubsub" && $0.type == "pep" }
            && features.contains(XMPPNamespaces.pubsubPublishOptions)
    }
}
