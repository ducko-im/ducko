import DuckoCore
import DuckoTestSupport
import Foundation
import Testing

/// Plays the server's side of a connection over a `MockTransport`: it answers the handshake, and hands a test each
/// stanza the client sends once.
@MainActor
final class MockServerSession {
    let transport: MockTransport
    private var seen: Set<String> = []

    init(transport: MockTransport) {
        self.transport = transport
    }

    /// Connects the account and answers its handshake. `afterBind` answers what the account's modules ask for before
    /// the connection counts as up.
    func connect(
        _ environment: AppEnvironment, accountID: UUID,
        afterBind: (MockServerSession) async throws -> Void = { _ in }
    ) async throws {
        let connection = Task { try await environment.accountService.connect(accountID: accountID, password: "local-fixture") }
        try await exchange("<stream:stream", testServerStreamOpen + testFeaturesNoTLS)
        try await exchange("<auth", "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
        try await exchange("<stream:stream", testServerStreamOpen + testFeaturesBind)
        let bind = try await next("urn:ietf:params:xml:ns:xmpp-bind")
        await reply(to: bind, contents: "<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><jid>alice@example.com/fixture</jid></bind>")
        try await afterBind(self)
        try await connection.value
    }

    /// The next stanza containing `fragment` that was not handed out before.
    func next(_ fragment: String) async throws -> String {
        let seen = seen
        let task = Task { [transport] in await transport.waitForSent(matching: { $0.contains(fragment) && !seen.contains(extractIQID(from: $0) ?? "") }) }
        let result = try await boundedOutcome { _ = await task.value }
        guard result != nil else { task.cancel(); throw CancellationError() }
        let stanza = try #require(await task.value)
        if let id = extractIQID(from: stanza) { self.seen.insert(id) }
        return stanza
    }

    func exchange(_ fragment: String, _ reply: String) async throws {
        _ = try await next(fragment)
        await transport.clearSentBytes()
        await transport.simulateReceive(reply)
    }

    func reply(to stanza: String, contents: String = "") async {
        guard let id = extractIQID(from: stanza) else { Issue.record("Missing id"); return }
        await transport.simulateReceive("<iq type='result' id='\(id)'>\(contents)</iq>")
    }
}
