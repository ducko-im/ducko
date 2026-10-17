import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.roster")

/// Manages the XMPP roster (RFC 6121) — contact list, subscription management, and roster pushes.
public final class RosterModule: XMPPModule, Sendable {
    private struct State {
        var context: ModuleContext?
        var receipt: UInt64 = 0
        var isActive = true
        var rosterVersionProvider: (@Sendable () -> String?)?
        var supportsPreApproval: Bool = false
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        [XMPPNamespaces.roster]
    }

    /// Sets a closure the service layer provides to return the persisted roster version on connect.
    public func setRosterVersionProvider(_ provider: (@Sendable () -> String?)?) {
        state.withLock { $0.rosterVersionProvider = provider }
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context; $0.isActive = true }
    }

    // MARK: - Lifecycle

    public func handleConnect() async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        let serverFeatures = context.serverStreamFeatures()
        let supportsVersioning = serverFeatures?.child(named: "ver", namespace: XMPPNamespaces.rosterVersioning) != nil
        let supportsPreApproval = serverFeatures?.child(named: "sub", namespace: XMPPNamespaces.preApproval) != nil
        state.withLock { $0.supportsPreApproval = supportsPreApproval }
        if supportsPreApproval {
            log.info("Server supports subscription pre-approval")
        }

        var iq = XMPPIQ(type: .get, id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.roster)
        if supportsVersioning {
            let provider = state.withLock { $0.rosterVersionProvider }
            let ver = provider?() ?? ""
            query.setAttribute("ver", value: ver)
        }
        iq.element.addChild(query)

        do {
            _ = try await context.sendIQ(iq) { [self] result in
                do {
                    let reply = try result.get()
                    let contents = try Self.queryContents(reply, permitsCachedBaseline: supportsVersioning)
                    _ = try emit(contents: contents.0, version: contents.1, origin: .initial, context: context)
                } catch {
                    _ = try? emit(contents: .initialQueryFailed, version: nil, origin: .initial, context: context)
                }
            }
        } catch is XMPPStanzaError {
            log.warning("Roster GET returned stanza error")
        }
    }

    public func handleDisconnect() async {
        state.withLock {
            $0.isActive = false
            $0.supportsPreApproval = false
        }
    }

    public func requestFullRoster(id: String) async throws -> UInt64 {
        guard let context = state.withLock({ $0.context }) else { throw XMPPClientError.notConnected }
        var iq = XMPPIQ(type: .get, id: id)
        iq.element.addChild(XMLElement(name: "query", namespace: XMPPNamespaces.roster))
        let outcome = OSAllocatedUnfairLock<Result<UInt64, any Error>?>(initialState: nil)
        _ = try await context.sendIQ(iq) { [self] result in
            let receipt = Result {
                let reply = try result.get()
                let contents = try Self.queryContents(reply, permitsCachedBaseline: false)
                return try emit(contents: contents.0, version: contents.1, origin: .readback(id), context: context)
            }
            outcome.withLock { $0 = receipt }
        }
        guard let result = outcome.withLock({ $0 }) else {
            throw XMPPClientError.unexpectedStreamState("The roster response was not received")
        }
        return try result.get()
    }

    private func emit(contents: RosterUpdate.Contents, version: String?, origin: RosterUpdate.Origin, context: ModuleContext) throws -> UInt64 {
        try state.withLock { state in
            guard state.isActive else { throw XMPPClientError.notConnected }
            state.receipt &+= 1
            context.emitEvent(.rosterUpdated(RosterUpdate(receipt: state.receipt, origin: origin, contents: contents, version: version)))
            return state.receipt
        }
    }

    private static func queryContents(_ reply: XMPPIQ, permitsCachedBaseline: Bool) throws -> (RosterUpdate.Contents, String?) {
        let children = reply.element.children.compactMap { node -> XMLElement? in
            guard case let .element(child) = node else { return nil }
            return child
        }
        if children.isEmpty, permitsCachedBaseline { return (.cachedBaseline, nil) }
        guard children.count == 1, let query = children.first,
              query.name == "query", query.namespace == XMPPNamespaces.roster else {
            throw XMPPClientError.unexpectedStreamState("The server returned an invalid roster")
        }
        var items: [RosterItem] = []
        var jids: Set<BareJID> = []
        for case let .element(child) in query.children {
            guard let item = validatedItem(child), item.subscription != .remove,
                  jids.insert(item.jid).inserted else {
                throw XMPPClientError.unexpectedStreamState("The server returned an invalid roster item")
            }
            items.append(item)
        }
        return (.snapshot(items), query.attribute("ver"))
    }

    private static func validatedItem(_ element: XMLElement) -> RosterItem? {
        guard element.name == "item", element.namespace == nil || element.namespace == XMPPNamespaces.roster,
              let rawJID = element.attribute("jid"), let jid = JID.parse(rawJID), case .bare = jid,
              element.attribute("subscription").map({ RosterItem.Subscription(rawValue: $0) != nil }) ?? true,
              element.attribute("ask").map({ $0 == "subscribe" }) ?? true,
              element.attribute("approved").map({ ["true", "false", "1", "0"].contains($0) }) ?? true else { return nil }
        for case let .element(child) in element.children {
            guard child.name == "group", child.namespace == nil || child.namespace == XMPPNamespaces.roster else { return nil }
        }
        return RosterItem.parse(element)
    }

    // MARK: - IQ Handling

    public func handleIQ(_ iq: XMPPIQ) throws -> Bool {
        guard iq.isSet, let query = iq.childElement, query.namespace == XMPPNamespaces.roster else { return false }
        guard let context = state.withLock({ $0.context }) else { return true }
        guard iq.isFromOwnAccount(context.connectedJID()?.bareJID) else { return true }
        let children = query.children.compactMap { node -> XMLElement? in
            guard case let .element(child) = node else { return nil }
            return child
        }
        let payloadCount = iq.element.children.reduce(0) { count, node in
            if case .element = node { return count + 1 }
            return count
        }
        guard iq.id != nil, payloadCount == 1, query.name == "query", children.count == 1,
              let child = children.first, let item = Self.validatedItem(child) else {
            replyToRosterPush(iq, context: context, malformed: true)
            return true
        }
        _ = try emit(contents: .delta(item), version: query.attribute("ver"), origin: .push, context: context)
        replyToRosterPush(iq, context: context, malformed: false)
        return true
    }

    private func replyToRosterPush(_ iq: XMPPIQ, context: ModuleContext, malformed: Bool) {
        let reply: XMPPIQ? = if malformed {
            .errorReply(for: iq, type: .modify, condition: .badRequest)
        } else {
            .resultReply(for: iq)
        }
        guard let reply else { return }
        Task {
            try? await context.sendStanza(reply)
        }
    }

    // MARK: - Public API

    @discardableResult
    public func addContact(jid: BareJID, name: String? = nil, groups: [String] = []) async throws -> ContinuousClock.Instant {
        guard let context = state.withLock({ $0.isActive ? $0.context : nil }) else { throw XMPPClientError.notConnected }

        var iq = XMPPIQ(type: .set, id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.roster)
        var item = XMLElement(name: "item", attributes: ["jid": jid.description])
        if let name { item.setAttribute("name", value: name) }
        for group in groups {
            var groupElement = XMLElement(name: "group")
            groupElement.addText(group)
            item.addChild(groupElement)
        }
        query.addChild(item)
        iq.element.addChild(query)

        return try await sendMutation(iq, context: context)
    }

    @discardableResult
    public func removeContact(jid: BareJID) async throws -> ContinuousClock.Instant {
        guard let context = state.withLock({ $0.isActive ? $0.context : nil }) else { throw XMPPClientError.notConnected }

        var iq = XMPPIQ(type: .set, id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.roster)
        let item = XMLElement(name: "item", attributes: ["jid": jid.description, "subscription": "remove"])
        query.addChild(item)
        iq.element.addChild(query)

        return try await sendMutation(iq, context: context)
    }

    private func sendMutation(_ iq: XMPPIQ, context: ModuleContext) async throws -> ContinuousClock.Instant {
        let acknowledgement = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
        _ = try await context.sendIQ(iq) { result in
            if case .success = result { acknowledgement.withLock { $0 = .now } }
        }
        guard let instant = acknowledgement.withLock({ $0 }) else {
            throw XMPPClientError.unexpectedStreamState("The contact change was not confirmed")
        }
        return instant
    }

    // MARK: - Subscription Management

    /// Sends a subscription request to the given JID.
    public func subscribe(to jid: BareJID) async throws {
        guard let context = state.withLock({ $0.isActive ? $0.context : nil }) else { throw XMPPClientError.notConnected }
        let presence = XMPPPresence(type: .subscribe, to: .bare(jid))
        try await context.sendStanza(presence)
    }

    /// Approves a subscription request from the given JID.
    public func approveSubscription(from jid: BareJID) async throws {
        guard let context = state.withLock({ $0.isActive ? $0.context : nil }) else { throw XMPPClientError.notConnected }
        let presence = XMPPPresence(type: .subscribed, to: .bare(jid))
        try await context.sendStanza(presence)
    }

    /// Denies a subscription request from the given JID.
    public func denySubscription(from jid: BareJID) async throws {
        guard let context = state.withLock({ $0.isActive ? $0.context : nil }) else { throw XMPPClientError.notConnected }
        let presence = XMPPPresence(type: .unsubscribed, to: .bare(jid))
        try await context.sendStanza(presence)
    }

    /// Unsubscribes from the given JID's presence.
    public func unsubscribe(from jid: BareJID) async throws {
        guard let context = state.withLock({ $0.isActive ? $0.context : nil }) else { throw XMPPClientError.notConnected }
        let presence = XMPPPresence(type: .unsubscribe, to: .bare(jid))
        try await context.sendStanza(presence)
    }

    /// Pre-approves a future subscription request (RFC 6121 §3.4).
    public func preApprove(jid: BareJID) async throws {
        let (context, supported) = state.withLock { ($0.context, $0.supportsPreApproval) }
        guard let context else { return }
        guard supported else {
            log.info("Server does not support pre-approval, skipping")
            log.debug("The skipped pre-approval is for \(jid)")
            return
        }
        let presence = XMPPPresence(type: .subscribed, to: .bare(jid))
        try await context.sendStanza(presence)
    }

    /// Whether the server advertises subscription pre-approval support (RFC 6121 §3.4).
    public var supportsPreApproval: Bool {
        state.withLock { $0.supportsPreApproval }
    }
}
