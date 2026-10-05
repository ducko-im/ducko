import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

@MainActor
struct RosterResumptionTests {
    @Test(arguments: [false, true], ["success", "query-error", "save-recovery", "save-recovery-error"])
    func `SM and ISR repair a transport acknowledged but unsaved push`(isr: Bool, resolution: String) async throws {
        let fixture = RosterResumptionFixture()
        try await fixture.disconnectWithUnsavedPush()
        let queryID = try await fixture.resumeWithReplay(isr: isr)
        try await fixture.resolveReadback(queryID: queryID, resolution: resolution)
        await fixture.close()
    }
}

@MainActor
private final class RosterResumptionFixture {
    let first = MockTransport(), second = MockTransport()
    let resumeGate = ResumeGate()
    let factory: RosterResumeFactory
    let store = MockPersistenceStore()
    let accounts: AccountService
    let roster: RosterService
    var applications: [String: Task<Void, Never>] = [:]
    var disconnected = false
    var resumed = false
    var id = UUID()
    let features = testFeaturesBindWithSM

    init() {
        self.factory = RosterResumeFactory(transports: [first, second], gate: resumeGate)
        self.accounts = AccountService(store: store, credentialStore: MockCredentialStore(), clientFactory: factory)
        self.roster = RosterService(store: store)
        roster.setAccountService(accounts)
        accounts.onRosterSessionStarted = { [roster] in roster.beginSession(accountID: $0, sessionID: $1, client: $2) }
        accounts.onRosterSessionEnded = { [roster] in roster.endSession(accountID: $0, sessionID: $1) }
        accounts.onRequestedDisconnect = { [roster] in roster.purgeAccount($0) }
        accounts.onEvent = { [weak self] event, account in
            guard let self else { return }
            let task = roster.receiveRosterEvent(event, accountID: account)
            if case let .rosterUpdated(update) = event, let version = update.version { applications[version] = task }
            if case .disconnected = event { self.disconnected = true }
            if case .streamResumed = event { self.resumed = true }
        }
    }

    func disconnectWithUnsavedPush() async throws {
        id = try await accounts.createAccount(jidString: "alice@example.com", requireTLS: false)
        let connection = Task { try await self.accounts.connect(accountID: self.id, password: "secret") }
        try await enableSM(first, features: features)
        let initial = try await sentStanza(on: first, containing: "jabber:iq:roster")
        await reply(first, to: initial, version: "initial", item: "<item jid='bob@example.com'/>")
        try await connection.value
        try await eventually { self.applications["initial"] != nil }
        await applications["initial"]?.value
        await first.clearSentBytes()
        let entered = AsyncSemaphore(), release = AsyncSemaphore()
        await store.installRosterApplyGate(entered: entered, release: release)
        await first.simulateReceive("<iq type='set' id='lost'><query xmlns='jabber:iq:roster' ver='lost'><item jid='bob@example.com' subscription='remove'/></query></iq><r xmlns='urn:xmpp:sm:3'/>")
        try #require(try await boundedOutcome { await entered.wait() } != nil)
        let ack = try await sentStanza(on: first, containing: "<a ")
        #expect(ack.contains("h=\"2\""))
        #expect(try await store.fetchAccounts().first?.rosterVersion == "initial")
        await first.simulateDisconnect()
        try await eventually { self.disconnected }
        await release.signal()
        for task in roster.takePendingTasks() {
            await task.value
        }
        #expect(try await store.fetchContacts(for: id).count == 1)
    }

    func resumeWithReplay(isr: Bool) async throws -> String {
        let reconnect = Task { try await self.accounts.connect(accountID: self.id, password: "secret") }
        let resumedState = try await factory.resumeForSecondClient()
        #expect(resumedState.incomingCounter == 2)
        try await resume(second, isr: isr, state: resumedState, features: features)
        try #require(try await boundedOutcome { await self.resumeGate.entered.wait() } != nil)
        // Replay reaches the session owner before streamResumed and must stay fenced.
        await second.simulateReceive("<iq type='set' id='replay'><query xmlns='jabber:iq:roster' ver='replay'><item jid='carol@example.com'/></query></iq>")
        _ = try await sentStanza(on: second, containing: "id=\"replay\"")
        #expect(!resumed)
        #expect(try await store.fetchAccounts().first?.rosterVersion == "initial")
        await resumeGate.release.signal()
        try await reconnect.value
        let readback = try await sentStanza(on: second, containing: "jabber:iq:roster")
        #expect(!readback.contains("ver="))
        let queryID = try #require(extractIQID(from: readback))
        await second.clearSentBytes()
        return queryID
    }

    func resolveReadback(queryID: String, resolution: String) async throws {
        if resolution == "query-error" {
            let synchronization = Task { try await self.roster.synchronizeRoster(accountID: self.id) }
            await second.simulateReceive("<iq type='error' id='\(queryID)'><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
            await #expect(throws: RosterSynchronization.Failure.degraded) { _ = try await synchronization.value }
            #expect(try await store.fetchAccounts().first?.rosterVersion == "initial")
        } else {
            if resolution != "success" { await store.failNextRosterApplications() }
            await second.simulateReceive("<iq type='set' id='before'><query xmlns='jabber:iq:roster' ver='before'><item jid='dave@example.com'/></query></iq>")
            await second.simulateReceive("<iq type='result' id='\(queryID)'><query xmlns='jabber:iq:roster' ver='reconciled'/></iq><iq type='set' id='after'><query xmlns='jabber:iq:roster' ver='after'><item jid='eve@example.com'/></query></iq>")
            if resolution != "success" {
                let recovery = try await sentStanza(on: second, containing: "jabber:iq:roster")
                #expect(!recovery.contains("ver="))
                if resolution == "save-recovery-error" {
                    let synchronization = Task { try await self.roster.synchronizeRoster(accountID: self.id) }
                    let recoveryID = try #require(extractIQID(from: recovery))
                    await second.simulateReceive("<iq type='result' id='\(recoveryID)'/>")
                    await #expect(throws: RosterSynchronization.Failure.degraded) { _ = try await synchronization.value }
                } else {
                    await reply(second, to: recovery, version: "repaired", item: "<item jid='eve@example.com'/>")
                    try await eventually { self.applications["repaired"] != nil }
                    await applications["repaired"]?.value
                }
                let gets = await second.sentBytes.map { String(decoding: $0, as: UTF8.self) }.filter { $0.contains("jabber:iq:roster") && $0.contains("type=\"get\"") }
                #expect(gets.count == 1)
            } else {
                try await eventually { self.applications["after"] != nil }
                await applications["after"]?.value
            }
            if resolution == "save-recovery-error" {
                #expect(try await store.fetchAccounts().first?.rosterVersion == "initial")
            } else {
                #expect(try await store.fetchContacts(for: id).map(\.jid.description) == ["eve@example.com"])
                #expect(try await store.fetchAccounts().first?.rosterVersion == (resolution == "success" ? "after" : "repaired"))
            }
            #expect(await !(store.rosterMutations.map(\.version)).contains("replay"))
            #expect(await !(store.rosterMutations.map(\.version)).contains("before"))
        }
    }

    func close() async {
        if let sm = await factory.current {
            await second.ackSyncRequests(from: sm)
        }
        await accounts.disconnect(accountID: id)
        for task in roster.takePendingTasks() {
            await task.value
        }
    }

    private func enableSM(_ first: MockTransport, features: String) async throws {
        try await exchange(first, "<stream:stream", testServerStreamOpen + testFeaturesNoTLS)
        try await exchange(first, "<auth", "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
        try await exchange(first, "<stream:stream", testServerStreamOpen + features)
        try await exchange(first, "<iq", testBindResult)
        try await exchange(first, "<enable", "<enabled xmlns='urn:xmpp:sm:3' id='roster-session' max='300'><isr-enabled xmlns='https://xmpp.org/extensions/isr/0' token='test-token' mechanism='HT-SHA-256-ENDP'/></enabled>")
    }

    private func resume(_ second: MockTransport, isr: Bool, state: SMResumeState, features: String) async throws {
        if isr {
            let sasl2 = "<features xmlns='http://etherx.jabber.org/streams'><authentication xmlns='urn:xmpp:sasl:2'><mechanism>PLAIN</mechanism><inline><bind xmlns='urn:xmpp:bind:0'/><sm xmlns='urn:xmpp:sm:3'/><isr xmlns='https://xmpp.org/extensions/isr/0'/></inline></authentication></features>"
            try await exchange(second, "<stream:stream", testServerStreamOpen + sasl2)
            let auth = try await sentStanza(on: second, containing: "<authenticate")
            #expect(auth.contains("HT-SHA-256-ENDP"))
            #expect(auth.contains("h=\"2\""))
            await second.clearSentBytes()
            await second.simulateReceive("<success xmlns='urn:xmpp:sasl:2'><authorization-identifier>alice@example.com/ducko</authorization-identifier><resumed xmlns='urn:xmpp:sm:3' previd='roster-session' h='\(state.outgoingCounter)'/></success><features xmlns='http://etherx.jabber.org/streams'/>")
        } else {
            try await exchange(second, "<stream:stream", testServerStreamOpen + testFeaturesNoTLS)
            try await exchange(second, "<auth", "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
            try await exchange(second, "<stream:stream", testServerStreamOpen + features)
            let resume = try await sentStanza(on: second, containing: "<resume")
            #expect(resume.contains("h=\"2\""))
            await second.clearSentBytes()
            await second.simulateReceive("<resumed xmlns='urn:xmpp:sm:3' previd='roster-session' h='\(state.outgoingCounter)'/>")
        }
    }

    private func exchange(_ transport: MockTransport, _ fragment: String, _ response: String) async throws {
        _ = try await sentStanza(on: transport, containing: fragment)
        await transport.clearSentBytes()
        await transport.simulateReceive(response)
    }

    private func reply(_ transport: MockTransport, to stanza: String, version: String, item: String) async {
        guard let id = extractIQID(from: stanza) else { Issue.record("Missing id"); return }
        await transport.simulateReceive("<iq type='result' id='\(id)'><query xmlns='jabber:iq:roster' ver='\(version)'>\(item)</query></iq>")
    }
}

private actor RosterResumeFactory: XMPPClientFactory {
    let transports: [MockTransport]
    let gate: ResumeGate
    var index = 0
    var current: StreamManagementModule?
    let resumeStates = AsyncStream.makeStream(of: SMResumeState.self)

    init(transports: [MockTransport], gate: ResumeGate) {
        self.transports = transports; self.gate = gate
    }

    func makeClient(account: Account, password: String, resuming: StreamResumeContext?, requireTLSOverride: Bool?, omemoService: OMEMOService?) async -> (XMPPClient, StreamManagementModule) {
        let transport = transports[index]
        index += 1
        let client = XMPPClient(domain: account.jid.domainPart, credentials: .init(username: account.jid.localPart ?? "", password: password), transport: transport, requireTLS: false)
        let sm = StreamManagementModule(previousState: resuming?.streamManagement)
        current = sm
        await client.register(sm)
        await client.addInterceptor(sm)
        await client.register(RosterModule())
        await client.register(gate)
        if let resuming { resumeStates.continuation.yield(resuming.streamManagement) }
        return (client, sm)
    }

    func resumeForSecondClient() async throws -> SMResumeState {
        let stream = resumeStates.stream
        return try await withThrowingTaskGroup(of: SMResumeState.self) { group in
            group.addTask { for await state in stream {
                return state
            }; throw CancellationError() }
            group.addTask { try await Task.sleep(for: .seconds(2)); throw RosterSynchronization.Failure.timedOut }
            defer { group.cancelAll() }
            return try #require(await group.next())
        }
    }
}
