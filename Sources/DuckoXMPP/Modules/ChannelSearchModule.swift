import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.channelsearch")

/// Implements XEP-0433 Extended Channel Search — discovers a search service
/// and performs keyword-based channel searches with RSM pagination.
public final class ChannelSearchModule: XMPPModule, Sendable {
    // MARK: - Types

    public struct SearchQuery: Sendable {
        public let keyword: String
        public let searchInName: Bool
        public let searchInDescription: Bool
        public let sortKey: String?
        public let maxResults: Int?
        public let after: String?

        public init(
            keyword: String,
            searchInName: Bool = true,
            searchInDescription: Bool = true,
            sortKey: String? = nil,
            maxResults: Int? = nil,
            after: String? = nil
        ) {
            self.keyword = keyword
            self.searchInName = searchInName
            self.searchInDescription = searchInDescription
            self.sortKey = sortKey
            self.maxResults = maxResults
            self.after = after
        }
    }

    public struct ChannelInfo: Sendable {
        public let address: BareJID
        public let name: String?
        public let userCount: Int?
        public let isOpen: Bool?
        public let description: String?

        public init(address: BareJID, name: String?, userCount: Int?, isOpen: Bool?, description: String?) {
            self.address = address
            self.name = name
            self.userCount = userCount
            self.isOpen = isOpen
            self.description = description
        }
    }

    public struct SearchResult: Sendable {
        public let items: [ChannelInfo]
        public let totalCount: Int?
        public let lastID: String?

        public init(items: [ChannelInfo], totalCount: Int?, lastID: String?) {
            self.items = items
            self.totalCount = totalCount
            self.lastID = lastID
        }
    }

    public enum ChannelSearchError: Error {
        case notConnected
        case noSearchServiceFound
    }

    // MARK: - State

    private struct State {
        var context: ModuleContext?
        var cachedSearchService: String?
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        [XMPPNamespaces.channelSearch]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleDisconnect() async {
        state.withLock { $0.cachedSearchService = nil }
    }

    // MARK: - Public API

    /// Discovers a channel search service on the server via disco#items + disco#info.
    @discardableResult
    public func discoverSearchService() async throws -> String? {
        if let cached = state.withLock({ $0.cachedSearchService }) {
            return cached
        }

        guard let context = state.withLock({ $0.context }) else {
            throw ChannelSearchError.notConnected
        }

        guard let domainJID = JID.parse(context.domain) else { return nil }

        var itemsIQ = XMPPIQ(type: .get, to: domainJID, id: context.generateID())
        let itemsQuery = XMLElement(name: "query", namespace: XMPPNamespaces.discoItems)
        itemsIQ.element.addChild(itemsQuery)

        guard let itemsResult = try await context.sendIQ(itemsIQ) else { return nil }
        let items = itemsResult.children(named: "item").compactMap { $0.attribute("jid") }

        let match = await findSearchService(items: items, context: context)
        if let match {
            state.withLock { $0.cachedSearchService = match }
            log.info("Discovered a channel search service")
            log.debug("The channel search service is \(match)")
        }
        return match
    }

    /// Searches for channels matching the given query.
    public func search(_ query: SearchQuery) async throws -> SearchResult {
        guard let service = try await discoverSearchService() else {
            throw ChannelSearchError.noSearchServiceFound
        }

        guard let context = state.withLock({ $0.context }),
              let serviceJID = JID.parse(service) else {
            throw ChannelSearchError.notConnected
        }

        var iq = XMPPIQ(type: .get, to: serviceJID, id: context.generateID())
        var searchElement = XMLElement(name: "search", namespace: XMPPNamespaces.channelSearch)

        var fields: [DataFormField] = [
            DataFormField(variable: "FORM_TYPE", type: "hidden", values: [XMPPNamespaces.channelSearchQuery])
        ]
        if !query.keyword.isEmpty {
            fields.append(DataFormField(variable: "q", values: [query.keyword]))
        }
        if let sortKey = query.sortKey {
            fields.append(DataFormField(variable: "key", values: [sortKey]))
        }
        if query.searchInName {
            fields.append(DataFormField(variable: "sinname", values: ["true"]))
        }
        if query.searchInDescription {
            fields.append(DataFormField(variable: "sindescription", values: ["true"]))
        }
        let form = buildSubmitForm(fields)
        searchElement.addChild(form)

        if query.maxResults != nil || query.after != nil {
            var setElement = XMLElement(name: "set", namespace: XMPPNamespaces.rsm)
            if let maxResults = query.maxResults {
                var maxEl = XMLElement(name: "max")
                maxEl.addText("\(maxResults)")
                setElement.addChild(maxEl)
            }
            if let after = query.after {
                var afterEl = XMLElement(name: "after")
                afterEl.addText(after)
                setElement.addChild(afterEl)
            }
            searchElement.addChild(setElement)
        }

        iq.element.addChild(searchElement)

        guard let result = try await context.sendIQ(iq) else {
            return SearchResult(items: [], totalCount: nil, lastID: nil)
        }

        return parseSearchResult(result)
    }

    private func findSearchService(items: [String], context: ModuleContext) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            for item in items {
                group.addTask {
                    guard let itemJID = JID.parse(item) else { return nil }
                    var infoIQ = XMPPIQ(type: .get, to: itemJID, id: context.generateID())
                    let infoQuery = XMLElement(name: "query", namespace: XMPPNamespaces.discoInfo)
                    infoIQ.element.addChild(infoQuery)

                    guard let infoResult = try? await context.sendIQ(infoIQ) else { return nil }
                    let featureVars = Set(infoResult.children(named: "feature").compactMap({ $0.attribute("var") }))
                    return featureVars.contains(XMPPNamespaces.channelSearch) ? item : nil
                }
            }
            for await result in group {
                if let service = result {
                    group.cancelAll()
                    return service
                }
            }
            return nil
        }
    }

    private func parseSearchResult(_ element: XMLElement) -> SearchResult {
        let items = element.children(named: "item").compactMap { item -> ChannelInfo? in
            guard let jidString = item.attribute("address") ?? item.attribute("jid"),
                  let jid = BareJID.parse(jidString) else { return nil }

            let name = item.childText(named: "name")
            let userCount = item.childText(named: "nusers").flatMap(Int.init)
            let isOpen = item.childText(named: "is-open").map { $0 == "true" || $0 == "1" }
            let description = item.childText(named: "description")

            return ChannelInfo(
                address: jid,
                name: name,
                userCount: userCount,
                isOpen: isOpen,
                description: description
            )
        }

        var totalCount: Int?
        var lastID: String?
        if let setElement = element.child(named: "set", namespace: XMPPNamespaces.rsm) {
            totalCount = setElement.childText(named: "count").flatMap(Int.init)
            lastID = setElement.childText(named: "last")
        }

        return SearchResult(items: items, totalCount: totalCount, lastID: lastID)
    }
}
