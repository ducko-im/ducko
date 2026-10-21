import CryptoKit
import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.caps")

/// Implements XEP-0115 Entity Capabilities and XEP-0390 Entity Capabilities 2.0 —
/// advertises capabilities via presence, and caches the capabilities a received hash stands for once a disco#info reply
/// verifies it.
public final class CapsModule: XMPPModule, Sendable {
    /// A capability hash a presence advertises, which stands for the same disco#info wherever it is seen.
    private enum CapsHash: Hashable {
        /// An XEP-0115 `ver` hashed with SHA-1.
        case caps(ver: String)
        /// One hash of an XEP-0390 hash set.
        case caps2(Caps2HashAlgorithm, value: String)
    }

    private enum CacheEntry {
        /// A disco#info for the hash is on its way.
        case querying
        case verified(Set<String>)
    }

    /// What an entity's most recent caps-bearing presence advertised.
    private enum Advertisement {
        /// The hashes this module can check, in the order the presence lists them.
        case hashes([CapsHash])
        /// A `ver` without a hash this module can check. The features the entity reports for it hold for that entity
        /// alone; `nil` while they are being asked.
        case unverified(ver: String, features: Set<String>?)
    }

    private struct State {
        var context: ModuleContext?
        /// Each hash's verified features, or `.querying` while its disco#info is pending.
        var capsCache: [CapsHash: CacheEntry] = [:]
        var advertisements: [JID: Advertisement] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>
    private let identity: ServiceDiscoveryModule.Identity
    private let node: String

    public var features: [String] {
        [XMPPNamespaces.caps, XMPPNamespaces.caps2]
    }

    public init(
        identity: ServiceDiscoveryModule.Identity = .ducko,
        node: String = "https://ducko.im"
    ) {
        self.identity = identity
        self.node = node
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Presence

    /// The XEP-0115 `<c>` and XEP-0390 `<c xmlns='urn:xmpp:caps'>` elements advertising the client's features,
    /// which every available presence carries.
    public func capsElements() -> [XMLElement] {
        guard let context = state.withLock({ $0.context }) else { return [] }

        let allFeatures = context.availableFeatures()
        let ver = Self.generateVerificationString(identities: [identity], features: allFeatures)
        let capsElement = XMLElement(
            name: "c",
            namespace: XMPPNamespaces.caps,
            attributes: [
                "hash": "sha-1",
                "node": node,
                "ver": ver
            ]
        )
        return [capsElement, buildCaps2Element(allFeatures)]
    }

    // MARK: - Dispatch

    public func handlePresence(_ presence: XMPPPresence) throws {
        guard let from = presence.from else { return }
        if presence.presenceType == .unavailable {
            _ = state.withLock { $0.advertisements.removeValue(forKey: from) }
            return
        }
        guard presence.presenceType == nil else { return }

        let caps2Hashes = Self.caps2Hashes(in: presence)
        if let first = caps2Hashes.first {
            let queryNode = "urn:xmpp:caps#\(first.algorithm.rawValue).\(first.value)"
            advertise(caps2Hashes.map { .caps2($0.algorithm, value: $0.value) }, from: from, queryNode: queryNode)
            return
        }

        guard let capsChild = presence.element.child(named: "c", namespace: XMPPNamespaces.caps),
              let ver = capsChild.attribute("ver") else {
            return
        }
        let queryNode = capsChild.attribute("node").map { "\($0)#\(ver)" }
        if capsChild.attribute("hash") == "sha-1" {
            advertise([.caps(ver: ver)], from: from, queryNode: queryNode)
        } else {
            advertiseUnverified(ver, from: from, queryNode: queryNode)
        }
    }

    /// The XEP-0390 hashes this module can check, in the order the presence lists them.
    private static func caps2Hashes(in presence: XMPPPresence) -> [(algorithm: Caps2HashAlgorithm, value: String)] {
        guard let caps2Child = presence.element.child(named: "c", namespace: XMPPNamespaces.caps2) else { return [] }
        return caps2Child.children(named: "hash").compactMap { hash in
            guard hash.namespace == XMPPNamespaces.hashes2,
                  let algorithm = hash.attribute("algo").flatMap(Caps2HashAlgorithm.init(rawValue:)),
                  let value = hash.textContent else { return nil }
            return (algorithm, value)
        }
    }

    /// Records `hashes` as what `jid` advertises and asks it for the disco#info they stand for, unless one of them is
    /// verified already or being asked about.
    private func advertise(_ hashes: [CapsHash], from jid: JID, queryNode: String?) {
        let context = state.withLock { state -> ModuleContext? in
            state.advertisements[jid] = .hashes(hashes)
            guard !hashes.contains(where: { state.capsCache[$0] != nil }) else { return nil }
            for hash in hashes {
                state.capsCache[hash] = .querying
            }
            return state.context
        }
        guard let context else { return }
        queryDiscoInfo(from: jid, node: queryNode, context: context) { [self] reply in
            settleQuery(for: hashes, reply: reply, streamLang: context.serverStreamLang())
        }
    }

    /// XEP-0115 §5.4: a `ver` without a supported hash is not checked or cached globally, so the features `jid`
    /// reports for it are kept for `jid` alone.
    private func advertiseUnverified(_ ver: String, from jid: JID, queryNode: String?) {
        let context = state.withLock { state -> ModuleContext? in
            if case .unverified(ver, _) = state.advertisements[jid] { return nil }
            state.advertisements[jid] = .unverified(ver: ver, features: nil)
            return state.context
        }
        guard let context else { return }
        queryDiscoInfo(from: jid, node: queryNode, context: context) { [self] reply in
            let features = reply.flatMap { CapsDiscoInfo($0) }.map { Set($0.features) }
            state.withLock { state in
                guard case .unverified(ver, nil) = state.advertisements[jid] else { return }
                state.advertisements[jid] = features.map { .unverified(ver: ver, features: $0) }
            }
        }
    }

    /// Asks `jid` for its disco#info. `settle` runs once with the reply, or with `nil` when the query ends without one.
    private func queryDiscoInfo(
        from jid: JID, node: String?, context: ModuleContext, settle: @escaping @Sendable (XMPPIQ?) -> Void
    ) {
        var iq = XMPPIQ(type: .get, to: jid, id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.discoInfo)
        if let node { query.setAttribute("node", value: node) }
        iq.element.addChild(query)
        Task {
            do {
                // Settled in the terminal handler, which every outcome passes through once.
                _ = try await context.sendIQ(iq) { settle(try? $0.get()) }
            } catch {
                log.warning("Disco#info query failed: \(error)")
                log.debug("The failed disco#info query was to \(jid)")
            }
        }
    }

    /// Caches the features `reply` shows for each of `hashes` it verifies, and forgets the others, so a later presence
    /// with one of them asks again. `streamLang` is the `xml:lang` of the stream `reply` came on.
    private func settleQuery(for hashes: [CapsHash], reply: XMPPIQ?, streamLang: String?) {
        let info = reply.flatMap { CapsDiscoInfo($0, streamLang: streamLang) }
        let verified = hashes.map { hash in info.flatMap { Self.features(in: $0, verifying: hash) } }
        if info != nil, verified.allSatisfy({ $0 == nil }) {
            log.warning("Caps hash mismatch or ill-formed disco#info reply")
        }
        state.withLock { state in
            for (hash, features) in zip(hashes, verified) {
                guard case .querying? = state.capsCache[hash] else { continue }
                state.capsCache[hash] = features.map(CacheEntry.verified)
            }
        }
    }

    // MARK: - Hash Verification

    /// The features `info` lists when it matches `hash`, else `nil`.
    private static func features(in info: CapsDiscoInfo, verifying hash: CapsHash) -> Set<String>? {
        switch hash {
        case let .caps(ver):
            guard let input = info.capsInput,
                  generateVerificationString(identities: input.identities, features: input.features, forms: input.forms) == ver else {
                return nil
            }
            return input.features
        case let .caps2(algorithm, value):
            guard let input = info.caps2Input else { return nil }
            let hashInput = Caps2Hash.generateHashInput(identities: input.identities, features: input.features, forms: input.forms)
            guard Base64.encode(algorithm.hash(hashInput)) == value else { return nil }
            return input.features
        }
    }

    // MARK: - Public API

    /// The features `jid`'s most recent caps advertise, once a disco#info reply has verified them, or as `jid` itself
    /// reported them for a `ver` that cannot be verified. `nil` while they are unknown.
    public func features(of jid: JID) -> Set<String>? {
        state.withLock { state in
            switch state.advertisements[jid] {
            case let .hashes(hashes):
                for hash in hashes {
                    if case let .verified(features)? = state.capsCache[hash] { return features }
                }
                return nil
            case let .unverified(_, features):
                return features
            case nil:
                return nil
            }
        }
    }

    // MARK: - Lifecycle: Disconnect

    public func handleDisconnect() async {
        state.withLock { $0.advertisements.removeAll() }
    }

    // MARK: - XEP-0115 Verification String

    /// Generates the XEP-0115 §5.1 verification string.
    ///
    /// Sorts identities by `category/type/lang` and features, both in i;octet order,
    /// encodes data forms per §5.1, concatenates with `<` separators,
    /// SHA-1 hashes, and base64 encodes.
    public static func generateVerificationString(
        identities: [ServiceDiscoveryModule.Identity],
        features: Set<String>,
        forms: [[DataFormField]] = []
    ) -> String {
        var parts: [String] = []

        // Sort identities by category/type/lang/name per XEP-0115 §5.1
        let sortedIdentities = identities.sorted { lhs, rhs in
            [lhs.category, lhs.type, lhs.lang, lhs.name ?? ""]
                .lexicographicallyPrecedes([rhs.category, rhs.type, rhs.lang, rhs.name ?? ""]) { $0.octetPrecedes($1) }
        }
        for identity in sortedIdentities {
            parts.append("\(identity.category)/\(identity.type)/\(identity.lang)/\(identity.name ?? "")<")
        }

        // Sort features
        for feature in features.octetSorted() {
            parts.append("\(feature)<")
        }

        // Data forms per XEP-0115 §5.1
        encodeFormsForVerification(forms, into: &parts)

        let input = parts.joined()
        let hash = Insecure.SHA1.hash(data: Array(input.utf8))
        return Base64.encode(Array(hash))
    }

    /// Encodes data forms into the verification string per XEP-0115 §5.1.
    private static func encodeFormsForVerification(_ forms: [[DataFormField]], into parts: inout [String]) {
        let formsWithType = forms.compactMap { fields -> (formType: String, fields: [DataFormField])? in
            guard let formTypeField = fields.first(where: { $0.variable == "FORM_TYPE" }),
                  let formTypeValue = formTypeField.values.first else { return nil }
            return (formType: formTypeValue, fields: fields)
        }

        let sorted = formsWithType.sorted { $0.formType.octetPrecedes($1.formType) }

        for form in sorted {
            parts.append("\(form.formType)<")

            let fields = form.fields
                .compactMap { field in field.variable.map { (variable: $0, values: field.values) } }
                .filter { $0.variable != "FORM_TYPE" }
                .sorted { $0.variable.octetPrecedes($1.variable) }

            for field in fields {
                parts.append("\(field.variable)<")
                for value in field.values.octetSorted() {
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
