import CryptoKit
import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.caps")

/// Implements XEP-0115 Entity Capabilities and XEP-0390 Entity Capabilities 2.0 —
/// advertises capabilities via presence and caches capabilities by verification hash.
public final class CapsModule: XMPPModule, Sendable {
    private struct State {
        var context: ModuleContext?
        /// `nil` value means the hash was seen but features haven't been fetched yet.
        var capsCache: [String: Set<String>?] = [:]
        /// Maps bare JIDs to their advertised verification hash.
        var jidToVer: [BareJID: String] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>
    private let identity: ServiceDiscoveryModule.Identity
    private let node: String

    public var features: [String] {
        [XMPPNamespaces.caps, XMPPNamespaces.caps2]
    }

    public init(
        identity: ServiceDiscoveryModule.Identity = ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "Ducko"),
        node: String = "https://ducko.app"
    ) {
        self.identity = identity
        self.node = node
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleConnect() async throws {
        guard let context = state.withLock({ $0.context }) else { return }

        let allFeatures = context.availableFeatures()
        let ver = Self.generateVerificationString(identities: [identity], features: allFeatures)

        var presence = XMPPPresence()

        // XEP-0115 classic caps
        let capsElement = XMLElement(
            name: "c",
            namespace: XMPPNamespaces.caps,
            attributes: [
                "hash": "sha-1",
                "node": node,
                "ver": ver
            ]
        )
        presence.element.addChild(capsElement)

        // XEP-0390 caps 2.0
        presence.element.addChild(buildCaps2Element(allFeatures))

        try await context.sendStanza(presence)
        log.info("Sent presence with caps ver=\(ver)")
    }

    // MARK: - Dispatch

    public func handlePresence(_ presence: XMPPPresence) throws {
        guard let from = presence.from else { return }

        // Prefer XEP-0390 caps 2.0 over XEP-0115
        if let caps2Child = presence.element.child(named: "c", namespace: XMPPNamespaces.caps2) {
            handleCaps2Presence(caps2Child, from: from)
            return
        }

        // Fall back to XEP-0115
        guard let capsChild = presence.element.child(named: "c", namespace: XMPPNamespaces.caps),
              let ver = capsChild.attribute("ver") else {
            return
        }

        let bareJID = from.bareJID
        let capNode = capsChild.attribute("node")

        let (needsQuery, context) = registerVerAndCheckQuery(ver, for: bareJID)

        if needsQuery, let context {
            let queryNode = capNode.map { "\($0)#\(ver)" }
            queryDiscoInfo(from: from, ver: ver, node: queryNode, context: context)
        }
    }

    private func handleCaps2Presence(_ caps2Child: XMLElement, from: JID) {
        // Extract the first <hash> child to build the cache key
        guard let hashChild = caps2Child.child(named: "hash", namespace: XMPPNamespaces.hashes2),
              let algo = hashChild.attribute("algo"),
              let hashValue = hashChild.textContent else {
            return
        }

        let ver = "\(algo).\(hashValue)"
        let bareJID = from.bareJID

        let (needsQuery, context) = registerVerAndCheckQuery(ver, for: bareJID)

        if needsQuery, let context {
            let queryNode = "urn:xmpp:caps#\(ver)"
            queryDiscoInfo(from: from, ver: ver, node: queryNode, context: context)
        }
    }

    private func registerVerAndCheckQuery(_ ver: String, for bareJID: BareJID) -> (needsQuery: Bool, context: ModuleContext?) {
        state.withLock { state -> (Bool, ModuleContext?) in
            state.jidToVer[bareJID] = ver
            if state.capsCache.keys.contains(ver) {
                return (false, nil)
            }
            state.capsCache[ver] = nil
            return (true, state.context)
        }
    }

    private func queryDiscoInfo(from jid: JID, ver: String, node: String?, context: ModuleContext) {
        Task {
            do {
                let queryNode = node ?? ver
                var iq = XMPPIQ(type: .get, to: jid, id: context.generateID())
                var query = XMLElement(name: "query", namespace: XMPPNamespaces.discoInfo)
                query.setAttribute("node", value: queryNode)
                iq.element.addChild(query)

                guard let result = try await context.sendIQ(iq) else { return }

                let identities = result.children(named: "identity").map { identity in
                    ServiceDiscoveryModule.Identity(
                        category: identity.attribute("category") ?? "",
                        type: identity.attribute("type") ?? "",
                        lang: identity.attribute("xml:lang") ?? "",
                        name: identity.attribute("name")
                    )
                }
                let features: Set<String> = Set(
                    result.children(named: "feature").compactMap({ $0.attribute("var") })
                )
                let forms = result.children(named: "x")
                    .filter { $0.namespace == XMPPNamespaces.dataForms }
                    .map { parseDataForm($0) }

                guard verifyCapsHash(ver: ver, identities: identities, features: features, forms: forms) else {
                    log.warning("Caps hash mismatch for ver=\(ver)")
                    state.withLock { _ = $0.capsCache.removeValue(forKey: ver) }
                    return
                }

                state.withLock { $0.capsCache[ver] = features }
                let count = features.count
                log.info("Cached \(count) features for ver=\(ver)")
            } catch {
                log.warning("Disco#info query failed: \(error)")
                log.debug("The failed disco#info query was to \(jid)")
            }
        }
    }

    // MARK: - Hash Verification

    /// Verifies the caps hash against received disco#info data.
    /// Handles both XEP-0115 (bare base64 hash) and XEP-0390 (`algo.base64hash`) formats.
    private func verifyCapsHash(
        ver: String,
        identities: [ServiceDiscoveryModule.Identity],
        features: Set<String>,
        forms: [[DataFormField]] = []
    ) -> Bool {
        // XEP-0390 format: "algo.base64hash"
        if let dotIndex = ver.firstIndex(of: ".") {
            let algoStr = String(ver[ver.startIndex ..< dotIndex])
            let hashStr = String(ver[ver.index(after: dotIndex)...])
            return verifyCaps2Hash(algo: algoStr, hash: hashStr, identities: identities, features: features, forms: forms)
        }

        // XEP-0115 format: bare base64 hash
        let computed = Self.generateVerificationString(identities: identities, features: features, forms: forms)
        return computed == ver
    }

    private func verifyCaps2Hash(
        algo: String,
        hash expectedHash: String,
        identities: [ServiceDiscoveryModule.Identity],
        features: Set<String>,
        forms: [[DataFormField]] = []
    ) -> Bool {
        guard let algorithm = Caps2HashAlgorithm(rawValue: algo) else {
            log.warning("Unknown caps2 hash algorithm: \(algo)")
            return false
        }

        let input = Caps2Hash.generateHashInput(identities: identities, features: features, forms: forms)
        let digest = algorithm.hash(input)
        let computed = Base64.encode(digest)
        return computed == expectedHash
    }

    // MARK: - Public API

    /// Stores features for a verification hash in the cache.
    func cacheFeatures(_ features: Set<String>, for ver: String) {
        state.withLock { $0.capsCache[ver] = features }
    }

    /// Returns whether a bare JID supports a given feature, based on cached caps.
    public func isFeatureSupported(_ feature: String, by bareJID: BareJID) -> Bool {
        state.withLock { state in
            guard let ver = state.jidToVer[bareJID],
                  let features = state.capsCache[ver] ?? nil else {
                return false
            }
            return features.contains(feature)
        }
    }

    // MARK: - Lifecycle: Disconnect

    public func handleDisconnect() async {
        state.withLock { $0.jidToVer.removeAll() }
    }

    // MARK: - XEP-0115 Verification String

    /// Generates the XEP-0115 §5.1 verification string.
    ///
    /// Sorts identities by `category/type`, sorts features alphabetically,
    /// encodes data forms per §5.4, concatenates with `<` separators,
    /// SHA-1 hashes, and base64 encodes.
    public static func generateVerificationString(
        identities: [ServiceDiscoveryModule.Identity],
        features: Set<String>,
        forms: [[DataFormField]] = []
    ) -> String {
        var parts: [String] = []

        // Sort identities by category/type/lang/name per XEP-0115 §5.4
        let sortedIdentities = identities.sorted { lhs, rhs in
            if lhs.category != rhs.category { return lhs.category < rhs.category }
            if lhs.type != rhs.type { return lhs.type < rhs.type }
            if lhs.lang != rhs.lang { return lhs.lang < rhs.lang }
            return (lhs.name ?? "") < (rhs.name ?? "")
        }
        for identity in sortedIdentities {
            parts.append("\(identity.category)/\(identity.type)/\(identity.lang)/\(identity.name ?? "")<")
        }

        // Sort features
        for feature in features.sorted() {
            parts.append("\(feature)<")
        }

        // Data forms per XEP-0115 §5.4
        encodeFormsForVerification(forms, into: &parts)

        let input = parts.joined()
        let hash = Insecure.SHA1.hash(data: Array(input.utf8))
        return Base64.encode(Array(hash))
    }

    /// Encodes data forms into the verification string per XEP-0115 §5.4.
    private static func encodeFormsForVerification(_ forms: [[DataFormField]], into parts: inout [String]) {
        let formsWithType = forms.compactMap { fields -> (formType: String, fields: [DataFormField])? in
            guard let formTypeField = fields.first(where: { $0.variable == "FORM_TYPE" }),
                  let formTypeValue = formTypeField.values.first else { return nil }
            return (formType: formTypeValue, fields: fields)
        }

        let sorted = formsWithType.sorted { $0.formType < $1.formType }

        for form in sorted {
            parts.append("\(form.formType)<")

            let fields = form.fields
                .filter { $0.variable != "FORM_TYPE" }
                .sorted { $0.variable < $1.variable }

            for field in fields {
                parts.append("\(field.variable)<")
                for value in field.values.sorted() {
                    parts.append("\(value)<")
                }
            }
        }
    }

    // MARK: - XEP-0390 Caps 2.0

    /// Builds a `<c xmlns='urn:xmpp:caps'>` element with hash children.
    private func buildCaps2Element(_ allFeatures: Set<String>) -> XMLElement {
        var caps2Element = XMLElement(name: "c", namespace: XMPPNamespaces.caps2)
        let hashInput = Caps2Hash.generateHashInput(identities: [identity], features: allFeatures)

        for algo in Caps2HashAlgorithm.allCases {
            let digest = algo.hash(hashInput)
            var hashChild = XMLElement(
                name: "hash",
                namespace: XMPPNamespaces.hashes2,
                attributes: ["algo": algo.rawValue]
            )
            hashChild.addText(Base64.encode(digest))
            caps2Element.addChild(hashChild)
        }

        return caps2Element
    }
}
