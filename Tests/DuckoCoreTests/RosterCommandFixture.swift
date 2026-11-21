import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

@MainActor
final class RosterCommandFixture {
    let store = MockPersistenceStore()
    let transport = MockTransport()
    let module = RosterModule()
    let accounts: AccountService
    let roster: RosterService
    private(set) var accountID = UUID()
    private var applicationsByVersion: [String: Task<Void, Never>] = [:]
    private let applicationArrived = AsyncSemaphore()
    private let initialApplied = AsyncSemaphore()
    private var seenIQIDs: Set<String> = []
    private var applications: [Task<Void, Never>] = []

    init(clock: RosterTestClock? = nil) {
        self.accounts = AccountService(store: store, credentialStore: MockCredentialStore(), clientFactory: MockXMPPClientFactory(transport: transport, modules: [module]))
        if let clock {
            self.roster = RosterService(store: store, synchronizationSleep: { try await clock.sleep(for: $0) }, synchronizationNow: { clock.now })
        } else {
            self.roster = RosterService(store: store)
        }
        roster.setAccountService(accounts)
        accounts.onRosterSessionStarted = { [roster] in roster.beginSession(accountID: $0, sessionID: $1, client: $2) }
        accounts.onRosterSessionEnded = { [roster] in roster.endSession(accountID: $0, sessionID: $1) }
        accounts.onRequestedDisconnect = { [roster] in roster.purgeAccount($0) }
        accounts.onEvent = { [weak self] event, id in
            guard let self else { return }
            let application = roster.receiveRosterEvent(event, accountID: id)
            if let application {
                applications.append(application)
                if case let .rosterUpdated(update) = event, let version = update.version {
                    applicationsByVersion[version] = application
                    applications.append(Task { [applicationArrived] in await applicationArrived.signal() })
                }
            }
            if case let .rosterUpdated(update) = event, update.isInitialResponse {
                applications.append(Task { [initialApplied] in
                    await application?.value
                    await initialApplied.signal()
                })
            }
        }
    }

    func connect(items: String = "<item jid='bob@example.com' subscription='both'/>", cachedBaseline: Bool = false) async throws {
        accountID = try await accounts.createAccount(jidString: "alice@example.com")
        let features = "<stream:features><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/><ver xmlns='urn:xmpp:features:rosterver'/></stream:features>"
        let (_, connection) = try await driveMockConnect(accounts, accountID: accountID, transport: transport, postAuthFeatures: cachedBaseline ? features : testFeaturesBind)
        let initial = try await nextIQ(type: "get")
        if cachedBaseline { #expect(initial.contains("ver=")) }
        await reply(to: initial, contents: cachedBaseline ? "" : "<query xmlns='jabber:iq:roster' ver='initial'>\(items)</query>")
        try await connection.value
        let applied = try await boundedOutcome { await self.initialApplied.wait() }
        try #require(applied != nil)
        await transport.clearSentBytes()
    }

    func nextIQ(type: String) async throws -> String {
        let seen = seenIQIDs
        let stanza = try await awaitSent(on: transport) {
            $0.contains("jabber:iq:roster") && $0.contains("type=\"\(type)\"") && !seen.contains(extractIQID(from: $0) ?? "")
        }
        try seenIQIDs.insert(#require(extractIQID(from: stanza)))
        return stanza
    }

    func reply(to stanza: String, contents: String = "", type: String = "result") async {
        guard let id = extractIQID(from: stanza) else { Issue.record("Missing IQ id"); return }
        await transport.simulateReceive("<iq type='\(type)' id='\(id)'>\(contents)</iq>")
    }

    func waitForApplication(version: String) async throws {
        let result = try await boundedOutcome { @MainActor in
            while self.applicationsByVersion[version] == nil {
                await self.applicationArrived.wait()
            }
            await self.applicationsByVersion[version]?.value
        }
        try #require(result != nil)
        try result?.get()
    }

    func close() async {
        await accounts.disconnect(accountID: accountID)
        for task in roster.takePendingTasks() {
            await task.value
        }
        for task in applications {
            await task.value
        }
    }
}
