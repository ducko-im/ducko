import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.disco")

/// Implements XEP-0030 Service Discovery — responds to incoming disco#info queries
/// and provides API for querying other entities.
public final class ServiceDiscoveryModule: XMPPModule, Sendable {
    // MARK: - Types

    public struct Identity: Hashable, Sendable {
        public let category: String
        public let type: String
        public let lang: String
        public let name: String?

        public init(category: String, type: String, lang: String = "", name: String? = nil) {
            self.category = category
            self.type = type
            self.lang = lang
            self.name = name
        }

        /// This client's identity. It names the language of the client's stream itself, so the caps hashes cover that
        /// language whichever one a server stamps on the disco#info reply.
        public static let ducko = Identity(category: "client", type: "pc", lang: XMPPStreamWriter.lang, name: "Ducko")
    }

    /// Result of a disco#info query.
    public struct InfoResult: Sendable {
        public let identities: [Identity]
        public let features: Set<String>
        public let forms: [[DataFormField]]

        public init(identities: [Identity], features: Set<String>, forms: [[DataFormField]] = []) {
            self.identities = identities
            self.features = features
            self.forms = forms
        }
    }

    /// A single disco#items item.
    public struct Item: Sendable {
        public let jid: JID
        public let name: String?
        public let node: String?

        public init(jid: JID, name: String? = nil, node: String? = nil) {
            self.jid = jid
            self.name = name
            self.node = node
        }
    }

    // MARK: - State

    private struct State {
        var context: ModuleContext?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let identity: Identity

    public var features: [String] {
        [XMPPNamespaces.discoInfo, XMPPNamespaces.discoItems]
    }

    public init(identity: Identity = .ducko) {
        self.identity = identity
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - IQ Handling

    public func handleIQ(_ iq: XMPPIQ) throws -> Bool {
        guard iq.isGet, let query = iq.childElement else { return false }

        if query.namespace == XMPPNamespaces.discoInfo {
            handleDiscoInfoGet(iq)
            return true
        } else if query.namespace == XMPPNamespaces.discoItems {
            handleDiscoItemsGet(iq)
            return true
        }
        return false
    }

    private func handleDiscoInfoGet(_ iq: XMPPIQ) {
        guard let context = state.withLock({ $0.context }),
              let result = XMPPIQ.resultReply(for: iq) else { return }

        // XEP-0115 §6.2 / XEP-0390 §4.2: echo the queried `node` so caps
        // verifiers (Prosody mod_caps etc.) that strict-match on it accept
        // the response and register +notify subscriptions.
        let requestedNode = iq.childElement?.attribute("node")

        Task {
            var result = result
            var query = XMLElement(name: "query", namespace: XMPPNamespaces.discoInfo)
            if let requestedNode { query.setAttribute("node", value: requestedNode) }

            var identityElement = XMLElement(name: "identity")
            identityElement.setAttribute("category", value: identity.category)
            identityElement.setAttribute("type", value: identity.type)
            if !identity.lang.isEmpty {
                identityElement.setAttribute("xml:lang", value: identity.lang)
            }
            if let name = identity.name {
                identityElement.setAttribute("name", value: name)
            }
            query.addChild(identityElement)

            let allFeatures = context.availableFeatures()
            for feature in allFeatures.sorted() {
                let featureElement = XMLElement(name: "feature", attributes: ["var": feature])
                query.addChild(featureElement)
            }

            result.element.addChild(query)
            do {
                try await context.sendStanza(result)
            } catch {
                log.warning("Failed to send disco#info response: \(error)")
            }
        }
    }

    private func handleDiscoItemsGet(_ iq: XMPPIQ) {
        guard let context = state.withLock({ $0.context }),
              let result = XMPPIQ.resultReply(for: iq) else { return }

        Task {
            var result = result
            let query = XMLElement(name: "query", namespace: XMPPNamespaces.discoItems)
            result.element.addChild(query)
            do {
                try await context.sendStanza(result)
            } catch {
                log.warning("Failed to send disco#items response: \(error)")
            }
        }
    }

    // MARK: - Public API

    /// Queries a remote entity for its disco#info.
    public func queryInfo(for jid: JID, node: String? = nil) async throws -> InfoResult {
        guard let context = state.withLock({ $0.context }) else {
            throw XMPPClientError.notConnected
        }

        var iq = XMPPIQ(type: .get, to: jid, id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.discoInfo)
        if let node { query.setAttribute("node", value: node) }
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else {
            return InfoResult(identities: [], features: [])
        }

        let identities = result.children(named: "identity").map { element in
            Identity(
                category: element.attribute("category") ?? "",
                type: element.attribute("type") ?? "",
                lang: element.attribute("xml:lang") ?? "",
                name: element.attribute("name")
            )
        }

        var features = Set<String>()
        for element in result.children(named: "feature") {
            if let featureVar = element.attribute("var") {
                features.insert(featureVar)
            }
        }

        let forms = result.children(named: "x")
            .filter { $0.namespace == XMPPNamespaces.dataForms }
            .map { parseDataForm($0).fields }

        return InfoResult(identities: identities, features: features, forms: forms)
    }

    /// Queries a remote entity for its disco#items.
    public func queryItems(for jid: JID, node: String? = nil) async throws -> [Item] {
        guard let context = state.withLock({ $0.context }) else {
            throw XMPPClientError.notConnected
        }

        var iq = XMPPIQ(type: .get, to: jid, id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.discoItems)
        if let node { query.setAttribute("node", value: node) }
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else {
            return []
        }

        return result.children(named: "item").compactMap { element in
            guard let jidString = element.attribute("jid"),
                  let jid = JID.parse(jidString) else {
                return nil
            }
            return Item(jid: jid, name: element.attribute("name"), node: element.attribute("node"))
        }
    }
}
