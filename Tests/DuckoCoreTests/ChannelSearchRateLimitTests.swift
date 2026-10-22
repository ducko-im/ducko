import DuckoTestSupport
import Foundation
import Synchronization
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

@MainActor
struct ChannelSearchRateLimitTests {
    private nonisolated static let found = "<result xmlns='urn:xmpp:channel-search:0:search'><item address='ducks@muc.example.com'/></result>"

    @Test
    func `A search inside the service's retry-after sends nothing, also after a reconnect or a relaunch, and one after it does`() async throws {
        let now = Mutex(Date())
        let transport1 = MockTransport(), transport2 = MockTransport()
        await Self.answerChannelSearch(on: transport1, type: "error", with: Self.rateLimited(retryAfter: "30"))
        await Self.answerChannelSearch(on: transport2, type: "result", with: Self.found)
        let vendor = TransportVendor([transport1, transport2])
        let factory = MockXMPPClientFactory(transportForAccount: { _ in vendor.next() }, modulesForAccount: { _ in [ChannelSearchModule()] })
        let store = MockPersistenceStore()
        let accounts = AccountService(store: store, credentialStore: MockCredentialStore(), clientFactory: factory)
        let clock: @Sendable () -> Date = { now.withLock { $0 } }
        let rooms = Self.makeRoomService(store: store, accounts: accounts, now: clock)
        let accountID = try await accounts.createAccount(jidString: "alice@example.com")
        let (_, firstConnect) = try await driveMockConnect(accounts, accountID: accountID, transport: transport1)

        let limited = await #expect(throws: ChannelSearchRateLimit.self) { try await rooms.searchChannels(keyword: "ducks", accountID: accountID) }
        now.withLock { $0 += 10 }
        let held = await #expect(throws: ChannelSearchRateLimit.self) { try await rooms.searchChannels(keyword: "ducks", accountID: accountID) }

        #expect(limited?.retryAfterSeconds == 30)
        #expect(held?.retryAfterSeconds == 20)
        #expect(await Self.searchCount(on: transport1) == 1)

        firstConnect.cancel()
        await accounts.disconnect(accountID: accountID)
        let (_, secondConnect) = try await driveMockConnect(accounts, accountID: accountID, transport: transport2)

        let heldAfterReconnect = await #expect(throws: ChannelSearchRateLimit.self) { try await rooms.searchChannels(keyword: "ducks", accountID: accountID) }
        let relaunched = Self.makeRoomService(store: store, accounts: accounts, now: clock)
        let heldAfterRelaunch = await #expect(throws: ChannelSearchRateLimit.self) { try await relaunched.searchChannels(keyword: "ducks", accountID: accountID) }
        #expect(heldAfterReconnect?.retryAfterSeconds == 20)
        #expect(heldAfterRelaunch?.retryAfterSeconds == 20)
        #expect(await Self.searchCount(on: transport2) == 0)

        now.withLock { $0 += 20 }
        let result = try await relaunched.searchChannels(keyword: "ducks", accountID: accountID)

        #expect(result.channels.map(\.jidString) == ["ducks@muc.example.com"])
        #expect(await Self.searchCount(on: transport2) == 1)
        #expect(await store.channelSearchLimits[accountID] == nil)
        secondConnect.cancel()
        await accounts.disconnect(accountID: accountID)
    }

    @Test
    func `A retry-after too long for a Duration holds later searches back for the longest wait`() async throws {
        let transport = MockTransport()
        await Self.answerChannelSearch(on: transport, type: "error", with: Self.rateLimited(retryAfter: String(Int.max)))
        let factory = MockXMPPClientFactory(transport: transport, modules: [ChannelSearchModule()])
        let store = MockPersistenceStore()
        let accounts = AccountService(store: store, credentialStore: MockCredentialStore(), clientFactory: factory)
        let now = Date()
        let rooms = Self.makeRoomService(store: store, accounts: accounts, now: { now })
        let accountID = try await accounts.createAccount(jidString: "alice@example.com")
        let (_, connect) = try await driveMockConnect(accounts, accountID: accountID, transport: transport)

        let limited = await #expect(throws: ChannelSearchRateLimit.self) { try await rooms.searchChannels(keyword: "ducks", accountID: accountID) }
        let held = await #expect(throws: ChannelSearchRateLimit.self) { try await rooms.searchChannels(keyword: "ducks", accountID: accountID) }

        #expect(limited?.retryAfterSeconds == Int.max)
        // The stored wait is read back through dates, whose doubles are 2048 s apart this far out.
        #expect(Int.max - (held?.retryAfterSeconds ?? 0) < 4096)
        #expect(await Self.searchCount(on: transport) == 1)
        connect.cancel()
        await accounts.disconnect(accountID: accountID)
    }

    /// A search that started before another one was rate-limited, then ended either way.
    @Test(arguments: [
        "<iq type=\"result\" id=\"ID\" from=\"search.example.com\">\(ChannelSearchRateLimitTests.found)</iq>",
        "<iq type=\"error\" id=\"ID\" from=\"search.example.com\">\(ChannelSearchRateLimitTests.rateLimited(retryAfter: "10"))</iq>"
    ])
    func `A search that started before another one was rate-limited keeps the other one's longer wait`(answer: String) async throws {
        let now = Date()
        let store = MockPersistenceStore()
        // Two sessions of one account, such as the app's and the CLI's, share the stored limits.
        let answeredLater = MockTransport(), limited = MockTransport()
        await Self.answerChannelSearch(on: answeredLater, type: "result", with: nil)
        await Self.answerChannelSearch(on: limited, type: "error", with: Self.rateLimited(retryAfter: "30"))
        let firstAccounts = AccountService(
            store: store, credentialStore: MockCredentialStore(), clientFactory: MockXMPPClientFactory(transport: answeredLater, modules: [ChannelSearchModule()])
        )
        let secondAccounts = AccountService(
            store: store, credentialStore: MockCredentialStore(), clientFactory: MockXMPPClientFactory(transport: limited, modules: [ChannelSearchModule()])
        )
        let accountID = try await firstAccounts.createAccount(jidString: "alice@example.com")
        try await secondAccounts.loadAccounts()
        // An expired limit is what a successful search lifts, so the first search finds one to lift.
        try await store.updateChannelSearchLimits(accountID: accountID) {
            $0["search.example.com"] = ChannelSearchLimit(notBefore: now - 5, consecutiveCount: 1)
        }
        let (_, firstConnect) = try await driveMockConnect(firstAccounts, accountID: accountID, transport: answeredLater)
        let (_, secondConnect) = try await driveMockConnect(secondAccounts, accountID: accountID, transport: limited)
        let firstRooms = Self.makeRoomService(store: store, accounts: firstAccounts, now: { now })
        let secondRooms = Self.makeRoomService(store: store, accounts: secondAccounts, now: { now })

        let firstSearch = Task { try await firstRooms.searchChannels(keyword: "ducks", accountID: accountID) }
        let search = try await sentStanza(on: answeredLater, containing: "<search")
        let searchID = try #require(extractIQID(from: search))
        await #expect(throws: ChannelSearchRateLimit.self) { try await secondRooms.searchChannels(keyword: "ducks", accountID: accountID) }
        await answeredLater.simulateReceive(answer.replacingOccurrences(of: "ID", with: searchID))
        _ = await firstSearch.result

        #expect(await store.channelSearchLimits[accountID]?["search.example.com"]?.notBefore == now + 30)
        firstConnect.cancel()
        secondConnect.cancel()
        await firstAccounts.disconnect(accountID: accountID)
        await secondAccounts.disconnect(accountID: accountID)
    }

    @Test
    func `A limit recorded in this session holds when the stored limits cannot be read`() async throws {
        let transport = MockTransport()
        await Self.answerChannelSearch(on: transport, type: "error", with: Self.rateLimited(retryAfter: "30"))
        let store = MockPersistenceStore()
        let accounts = AccountService(
            store: store, credentialStore: MockCredentialStore(), clientFactory: MockXMPPClientFactory(transport: transport, modules: [ChannelSearchModule()])
        )
        let now = Date()
        let rooms = Self.makeRoomService(store: store, accounts: accounts, now: { now })
        let accountID = try await accounts.createAccount(jidString: "alice@example.com")
        let (_, connect) = try await driveMockConnect(accounts, accountID: accountID, transport: transport)
        await #expect(throws: ChannelSearchRateLimit.self) { try await rooms.searchChannels(keyword: "ducks", accountID: accountID) }

        await store.setFetchChannelSearchLimitsError(CocoaError(.fileReadUnknown))
        let held = await #expect(throws: ChannelSearchRateLimit.self) { try await rooms.searchChannels(keyword: "ducks", accountID: accountID) }

        #expect(held?.retryAfterSeconds == 30)
        #expect(await Self.searchCount(on: transport) == 1)
        connect.cancel()
        await accounts.disconnect(accountID: accountID)
    }

    @Test
    func `A stored wait too long for a Duration saturates`() {
        let now = Date()
        let gate = ChannelSearchGate(limits: [
            "search.example.com": ChannelSearchLimit(notBefore: now.addingTimeInterval(1e30), consecutiveCount: 1)
        ])

        #expect(gate.remainingWait(service: "search.example.com", at: now)?.secondsRoundedUp == Int.max)
    }

    @Test
    func `Rate limits in a row without retry-after double the wait up to 640 s`() {
        var gate = ChannelSearchGate(limits: [:])
        var now = Date()
        var waits: [Duration] = []

        for _ in 0 ..< 8 {
            let wait = gate.recordRateLimit(retryAfter: nil, service: "search.example.com", at: now)
            waits.append(wait)
            now += TimeInterval(wait.components.seconds)
        }

        #expect(waits == [10, 20, 40, 80, 160, 320, 640, 640].map { .seconds($0) })
    }

    private nonisolated static func rateLimited(retryAfter: String) -> String {
        """
        <error type="wait"><resource-constraint xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>\
        <rate-limit xmlns="urn:xmpp:channel-search:0:error" retry-after="\(retryAfter)"/></error>
        """
    }

    private static func makeRoomService(store: MockPersistenceStore, accounts: AccountService, now: @Sendable @escaping () -> Date) -> RoomService {
        let rooms = RoomService(
            store: store, ensureConversation: { _, _, _ in }, didUpdateConversation: { _ in }, channelSearchNow: now
        )
        rooms.setAccountService(accounts)
        return rooms
    }

    /// Lists `search.example.com` as the server's channel search service on `transport` and answers each search with
    /// an IQ of `type` holding `payload`, or leaves it unanswered when `payload` is nil.
    private static func answerChannelSearch(on transport: MockTransport, type: String, with payload: String?) async {
        await transport.autoReply { stanza in
            guard let id = extractIQID(from: stanza) else { return nil }
            if stanza.contains(XMPPNamespaces.discoItems) {
                return """
                <iq type="result" id="\(id)" from="example.com"><query xmlns="\(XMPPNamespaces.discoItems)">\
                <item jid="search.example.com"/></query></iq>
                """
            }
            if stanza.contains(XMPPNamespaces.discoInfo) {
                return """
                <iq type="result" id="\(id)" from="search.example.com"><query xmlns="\(XMPPNamespaces.discoInfo)">\
                <feature var="\(XMPPNamespaces.channelSearch)"/></query></iq>
                """
            }
            guard stanza.contains("<search"), let payload else { return nil }
            return "<iq type=\"\(type)\" id=\"\(id)\" from=\"search.example.com\">\(payload)</iq>"
        }
    }

    private static func searchCount(on transport: MockTransport) async -> Int {
        await transport.sentBytes.count { String(decoding: $0, as: UTF8.self).contains("<search") }
    }
}
