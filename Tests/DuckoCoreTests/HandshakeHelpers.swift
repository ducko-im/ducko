import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing

// MARK: - Handshake Simulation

// The stream-open and features constants used below live in `DuckoTestSupport/HandshakeFixtures.swift`
// (shared with DuckoXMPPTests). `testBindResult` stays per-target because its bound JID differs.

/// Bind result with a full JID.
let testBindResult = """
<iq type='result' id='ducko-1'>\
<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>\
<jid>alice@example.com/ducko</jid>\
</bind>\
</iq>
"""

/// Simulates a connect handshake without TLS.
func simulateNoTLSConnect(_ transport: MockTransport, postAuthFeatures: String = testFeaturesBind) async {
    await transport.waitForSent(count: 1) // stream opening sent
    await transport.simulateReceive(testServerStreamOpen)
    await transport.simulateReceive(testFeaturesNoTLS)
    await transport.waitForSent(count: 2) // auth element sent
    await transport.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
    await transport.waitForSent(count: 3) // post-auth stream opening sent
    await transport.simulateReceive(testServerStreamOpen)
    await transport.simulateReceive(postAuthFeatures)
    await transport.waitForSent(count: 4) // bind IQ sent
    await transport.simulateReceive(testBindResult)
}

/// Drives a full mock handshake for an already-loaded account until its client reaches `.connected`, returning
/// the connected client and the still-running connect task (cancel it and `disconnect` during teardown). Set
/// `awaitInitialPresence` when the test inspects sent presence — it waits for the initial available presence and
/// entity caps to flush so a later `clearSentBytes()` can't race those still-in-flight stanzas (requires the
/// factory to register `PresenceModule` + `CapsModule`). Consolidates the connect-and-poll setup the presence
/// suites repeat.
@MainActor
func driveMockConnect(
    _ service: AccountService,
    accountID: UUID,
    password: String = "secret",
    transport: MockTransport,
    awaitInitialPresence: Bool = false,
    postAuthFeatures: String = testFeaturesBind
) async throws -> (client: XMPPClient, task: Task<Void, any Error>) {
    let task = Task { @MainActor in
        try await service.connect(accountID: accountID, password: password)
    }
    await simulateNoTLSConnect(transport, postAuthFeatures: postAuthFeatures)
    if awaitInitialPresence {
        // The handshake sends 4 stanzas through bind; the client then sends the initial available presence
        // (stanza 5) and entity caps (stanza 6), so a cumulative count of 6 means both have flushed.
        await transport.waitForSent(count: 6)
    }
    for _ in 0 ..< 100 {
        if service.connectedClient(for: accountID) != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let client = try #require(service.connectedClient(for: accountID))
    return (client, task)
}

/// Waits until `predicate` holds, failing the test when it doesn't within `boundedOutcome`'s deadline.
func eventually(_ predicate: @escaping @MainActor () async throws -> Bool) async throws {
    let result = try await boundedOutcome { @MainActor in
        while try await !predicate() {
            try Task.checkCancellation(); await Task.yield()
        }
    }
    try #require(result != nil)
    try result?.get()
}

/// Waits, within `boundedOutcome`'s deadline, for a stanza containing `fragment` to go out on `transport`.
func sentStanza(on transport: MockTransport, containing fragment: String) async throws -> String {
    let task = Task { await transport.waitForSent(matching: { $0.contains(fragment) }) }
    if try await boundedOutcome(of: { _ = await task.value }) == nil {
        task.cancel()
    }
    return try #require(await task.value, "Nothing sent containing \(fragment)")
}

/// Answers the sign-in pass's bookmarks fetch on `transport` with an auto-join bookmark for each of `rooms`.
func answerBookmarksFetch(on transport: MockTransport, autoJoin rooms: [BareJID]) async throws {
    let fetch = try await sentStanza(on: transport, containing: XMPPNamespaces.bookmarks2)
    let id = try #require(extractIQID(from: fetch))
    let items = rooms.map { "<item id='\($0)'><conference xmlns='urn:xmpp:bookmarks:1' autojoin='true'/></item>" }.joined()
    await transport.simulateReceive("""
    <iq type='result' id='\(id)'>\
    <pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:bookmarks:1'>\(items)</items></pubsub>\
    </iq>
    """)
}

/// Parks every resume ahead of `.streamResumed`, so a test can deliver what the server replays first.
final class ResumeGate: XMPPModule {
    let entered = AsyncSemaphore()
    let release = AsyncSemaphore()
    func setUp(_ context: ModuleContext) {}
    func handleResume() async throws {
        await entered.signal(); await release.wait()
    }
}
