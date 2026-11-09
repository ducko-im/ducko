import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.mam")

/// Implements XEP-0313 Message Archive Management — queries the server
/// for archived messages with pagination support.
public final class MAMModule: XMPPModule, Sendable {
    // MARK: - Types

    /// Three-state RSM `<before>` semantics.
    public enum RSMBefore: Sendable {
        /// No `<before>` element — page forward from the start (default).
        case omitted
        /// Empty `<before/>` — requests the last page of results.
        case lastPage
        /// `<before>ID</before>` — page backward from the given item ID.
        case id(String)
    }

    /// Query parameters for `queryMessages`.
    public struct Query: Sendable {
        public let to: BareJID?
        public let with: BareJID?
        public let start: String?
        public let end: String?
        public let before: RSMBefore
        public let after: String?
        public let max: Int?

        public init(
            to: BareJID? = nil,
            with: BareJID? = nil,
            start: String? = nil,
            end: String? = nil,
            before: RSMBefore = .omitted,
            after: String? = nil,
            max: Int? = nil
        ) {
            self.to = to
            self.with = with
            self.start = start
            self.end = end
            self.before = before
            self.after = after
            self.max = max
        }
    }

    // MARK: - State

    private struct OpenQuery {
        /// The archive that was asked: a room's, or the account's own. Nil when the account's address is not known,
        /// which leaves only a result without a sender to count as the account's own.
        let archive: BareJID?
        let isOwnArchive: Bool
        /// How many results were asked for at most, when the query named a number.
        let limit: Int?
        /// Whether the query pages backward, towards older entries, from where it starts.
        let pagesBackward: Bool
        var messages: [ArchivedMessage] = []

        /// An archive returns no more than it was asked for. Of what one sends beyond that, the results nearest to
        /// where the query pages from are kept, so that none is missing next to what is already held: the first
        /// ones paging forward, the last ones paging backward.
        mutating func take(_ message: ArchivedMessage) {
            guard let limit, messages.count >= limit else {
                messages.append(message)
                return
            }
            guard pagesBackward, !messages.isEmpty else { return }
            messages.removeFirst()
            messages.append(message)
        }

        /// An archive answers from its own address (XEP-0313). The account's own may also leave the sender out.
        func isAnswered(by rawSender: String?) -> Bool {
            isSender(rawSender, exactly: archive, orAbsent: isOwnArchive)
        }
    }

    private struct State {
        var context: ModuleContext?
        var activeQueries: [String: OpenQuery] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleDisconnect() async {
        state.withLock { $0.activeQueries.removeAll() }
    }

    // MARK: - Message Handling

    public func handleMessage(_ message: XMPPMessage) throws {
        guard let result = message.element.child(named: "result", namespace: XMPPNamespaces.mam),
              let queryID = result.attribute("queryid") else {
            return
        }

        guard let archived = ArchivedMessage.parse(result) else {
            log.warning("Failed to parse MAM result")
            return
        }

        // Query IDs are random, yet another entity can still answer an open query (XEP-0313, Sender Impersonation).
        // Only the archive that was asked is believed.
        let sender = message.element.attribute("from")
        let appended = state.withLock { state -> Bool in
            guard state.activeQueries[queryID]?.isAnswered(by: sender) == true else { return false }
            state.activeQueries[queryID]?.take(archived)
            return true
        }
        if !appended {
            log.debug("Ignoring MAM result for an unregistered query or from another sender: \(queryID)")
        }
    }

    // MARK: - Public API

    /// Queries the message archive with optional filters and pagination.
    /// For MUC room archives, set `to` to the room's bare JID.
    public func queryMessages(_ query: Query = Query()) async throws -> (messages: [ArchivedMessage], fin: MAMFin) {
        guard let context = state.withLock({ $0.context }) else {
            return ([], MAMFin(complete: true, isStable: true, first: nil, last: nil, count: nil))
        }

        let queryID = context.generateID()

        // Register the query before sending; defer ensures cleanup on failure
        let pagesBackward = if case .omitted = query.before { false } else { true }
        let openQuery = OpenQuery(
            archive: query.to ?? context.connectedJID()?.bareJID, isOwnArchive: query.to == nil, limit: query.max, pagesBackward: pagesBackward
        )
        state.withLock { $0.activeQueries[queryID] = openQuery }
        defer { state.withLock { _ = $0.activeQueries.removeValue(forKey: queryID) } }

        var iq = XMPPIQ(type: .set, id: context.generateID())
        if let to = query.to { iq.to = .bare(to) }
        var queryElement = XMLElement(name: "query", namespace: XMPPNamespaces.mam, attributes: ["queryid": queryID])

        if let form = Self.buildFilterForm(jid: query.with, start: query.start, end: query.end) {
            queryElement.addChild(form)
        }
        if let rsm = Self.buildRSM(max: query.max, before: query.before, after: query.after) {
            queryElement.addChild(rsm)
        }

        iq.element.addChild(queryElement)

        let finElement = try await context.sendIQ(iq)

        let messages = state.withLock { state -> [ArchivedMessage] in
            return state.activeQueries.removeValue(forKey: queryID)?.messages ?? []
        }

        let fin: MAMFin = if let finElement, let parsed = MAMFin.parse(finElement) {
            parsed
        } else {
            MAMFin(complete: true, isStable: true, first: nil, last: nil, count: nil)
        }

        context.emitEvent(.archivedMessagesLoaded(messages, fin: fin))

        return (messages, fin)
    }

    /// Backward-compatible overload with individual parameters.
    /// Does not support `.lastPage`; use the `Query`-based overload for that.
    public func queryMessages(
        to: BareJID? = nil,
        with jid: BareJID? = nil,
        start: String? = nil,
        end: String? = nil,
        before: String? = nil,
        after: String? = nil,
        max: Int? = nil
    ) async throws -> (messages: [ArchivedMessage], fin: MAMFin) {
        let rsmBefore: RSMBefore = if let before { .id(before) } else { .omitted }
        return try await queryMessages(Query(
            to: to, with: jid, start: start, end: end,
            before: rsmBefore, after: after, max: max
        ))
    }

    private static func buildFilterForm(jid: BareJID?, start: String?, end: String?) -> XMLElement? {
        guard jid != nil || start != nil || end != nil else { return nil }

        var fields: [DataFormField] = [
            DataFormField(variable: "FORM_TYPE", type: "hidden", values: [XMPPNamespaces.mam])
        ]
        if let jid { fields.append(DataFormField(variable: "with", values: [jid.description])) }
        if let start { fields.append(DataFormField(variable: "start", values: [start])) }
        if let end { fields.append(DataFormField(variable: "end", values: [end])) }

        return buildSubmitForm(fields)
    }

    private static func buildRSM(max: Int?, before: RSMBefore, after: String?) -> XMLElement? {
        let hasBefore = switch before {
        case .omitted: false
        case .lastPage, .id: true
        }
        guard max != nil || hasBefore || after != nil else { return nil }

        var rsm = XMLElement(name: "set", namespace: XMPPNamespaces.rsm)

        if let max {
            var maxElement = XMLElement(name: "max")
            maxElement.addText(String(max))
            rsm.addChild(maxElement)
        }
        switch before {
        case .omitted:
            break
        case .lastPage:
            rsm.addChild(XMLElement(name: "before"))
        case let .id(id):
            var beforeElement = XMLElement(name: "before")
            beforeElement.addText(id)
            rsm.addChild(beforeElement)
        }
        if let after {
            var afterElement = XMLElement(name: "after")
            afterElement.addText(after)
            rsm.addChild(afterElement)
        }

        return rsm
    }
}

public extension ServiceDiscoveryModule.InfoResult {
    /// Whether the entity whose disco#info this is keeps an archive that can be read (XEP-0313 §6).
    var supportsMessageArchive: Bool {
        features.contains(XMPPNamespaces.mam)
    }
}
