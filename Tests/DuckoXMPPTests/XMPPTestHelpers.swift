import Darwin
import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

// MARK: - XML Constants

// The stream-open and features constants shared with DuckoCoreTests live in
// `DuckoTestSupport/HandshakeFixtures.swift`. The SASL2 constants below are XMPP-only, so they stay here.

/// Features offering STARTTLS and PLAIN auth.
let testFeaturesWithTLS = """
<features xmlns='http://etherx.jabber.org/streams'>\
<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>\
<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\
<mechanism>PLAIN</mechanism>\
</mechanisms>\
</features>
"""

/// A TLS-namespace `<proceed/>`, the server's agreement to start TLS.
let testProceed = "<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"

/// A stanza a server or on-path attacker injects into the plaintext after `<proceed/>`.
let testInjectedMessage = "<message from='attacker@example.com'><body>Injected</body></message>"

/// Bind result with a full JID.
let testBindResult = """
<iq type='result' id='ducko-1'>\
<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'>\
<jid>user@example.com/ducko</jid>\
</bind>\
</iq>
"""

// MARK: - Connect Flow Simulation

/// Simulates a connect handshake without TLS, on streams the server opens with `serverStreamOpen`.
func simulateNoTLSConnect(_ mock: MockTransport, postAuthFeatures: String = testFeaturesBind, serverStreamOpen: String = testServerStreamOpen) async {
    await mock.waitForSent(count: 1) // stream opening sent
    await mock.simulateReceive(serverStreamOpen)
    await mock.simulateReceive(testFeaturesNoTLS)
    await mock.waitForSent(count: 2) // auth element sent
    await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
    await mock.waitForSent(count: 3) // post-auth stream opening sent
    await mock.simulateReceive(serverStreamOpen)
    await mock.simulateReceive(postAuthFeatures)
    await mock.waitForSent(count: 4) // bind IQ sent
    await mock.simulateReceive(testBindResult)
}

/// Simulates a connect handshake without TLS, then answers the roster GET with `rosterQuery`.
func simulateNoTLSConnect(_ mock: MockTransport, rosterQuery: String) async throws {
    await simulateNoTLSConnect(mock)
    try await answerRosterGet(on: mock, with: rosterQuery)
}

/// Answers the client's roster GET with a result carrying `rosterQuery`, under the request's own ID.
func answerRosterGet(on mock: MockTransport, with rosterQuery: String) async throws {
    let request = try await awaitOutgoingIQ(on: mock, type: .get, namespace: XMPPNamespaces.roster) { _ in true }
    await mock.simulateReceive("<iq type='result' id='\(request.id)'>\(rosterQuery)</iq>")
}

/// Simulates a direct TLS connect handshake (TLS already active, no STARTTLS negotiation).
func simulateDirectTLSConnect(_ mock: MockTransport, postAuthFeatures: String = testFeaturesBind) async {
    await simulateNoTLSConnect(mock, postAuthFeatures: postAuthFeatures)
}

/// Simulates the connect flow up to post-auth features, then expects a `<resume>` element
/// instead of `<bind>`. Responds with the given `resumeResponse` XML.
func simulateResumeConnect(_ mock: MockTransport, resumeResponse: String) async {
    await mock.waitForSent(count: 1) // stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesNoTLS)
    await mock.waitForSent(count: 2) // auth element sent
    await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
    await mock.waitForSent(count: 3) // post-auth stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesBindWithSM)
    await mock.waitForSent(count: 4) // <resume> sent (instead of bind)
    await mock.simulateReceive(resumeResponse)
}

/// Simulates the connect flow where resume fails, then falls through to normal bind.
func simulateResumeFailConnect(_ mock: MockTransport) async {
    await mock.waitForSent(count: 1) // stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesNoTLS)
    await mock.waitForSent(count: 2) // auth element sent
    await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
    await mock.waitForSent(count: 3) // post-auth stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesBindWithSM)
    await mock.waitForSent(count: 4) // <resume> sent
    await mock.simulateReceive("<failed xmlns='urn:xmpp:sm:3'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></failed>")
    await mock.waitForSent(count: 5) // bind IQ sent (fallback)
    await mock.simulateReceive(testBindResult)
    await mock.waitForSent(count: 6) // SM <enable> sent after bind
    await mock.simulateReceive("<enabled xmlns='urn:xmpp:sm:3' id='sm-resume-2' max='300'/>")
}

// MARK: - Disconnect

/// Disconnects with short sync-ack and stream-close timeouts so teardown doesn't pay the production fallbacks: no
/// test answers the `<r/>` a stream-management client sends on disconnect, and a mock whose receive stream has
/// already ended cannot deliver the `</stream:stream>` reply. Use wherever `disconnect()` is just cleanup; tests
/// that exercise the happy-path replies or pin disconnect ordering drive the timeouts themselves.
func disconnectFast(_ client: XMPPClient) async {
    await client.disconnect(streamCloseTimeout: .milliseconds(20), syncAckTimeout: .milliseconds(20))
}

// MARK: - Stanza Parsing

/// Parses one stanza as a client's stream would deliver it.
func stanza(_ xml: String) throws -> XMLElement {
    let events = XMPPStreamParser().parse(Array((testServerStreamOpen + xml).utf8))
    for case let .stanzaReceived(element) in events {
        return element
    }
    throw XMPPClientError.unexpectedStreamState("No stanza in \(xml)")
}

/// The top-level elements the client sent, parsed, so a check matches by name and namespace rather than by how the
/// serializer happens to quote them. The stream header parses to none.
func sentElements(on mock: MockTransport) async -> [XMLElement] {
    await mock.sentBytes.compactMap { try? stanza(String(decoding: $0, as: UTF8.self)) }
}

// MARK: - Stub Module Context

/// A `ModuleContext` with inert dependencies for driving a module without a client; pass only the ones a test observes.
func makeStubModuleContext(
    sendStanza: @escaping ModuleContext.StanzaSender = { _, onAccepted in onAccepted?() },
    sendIQ: @escaping ModuleContext.IQSender = { _, _ in nil },
    emitEvent: @Sendable @escaping (XMPPEvent) -> Void = { _ in },
    generateID: @Sendable @escaping () -> String = { "test-1" },
    sendElement: @Sendable @escaping (XMLElement) async throws -> Void = { _ in },
    serverStreamFeatures: @Sendable @escaping () -> XMLElement? = { nil },
    connectedJID: FullJID? = FullJID.parse("user@example.com/res"),
    dispatchDecryptedMessage: @Sendable @escaping (XMPPMessage) -> Void = { _ in },
    reportConnectionLost: @Sendable @escaping (String) -> Void = { _ in }
) -> ModuleContext {
    ModuleContext(
        sendStanza: sendStanza,
        sendIQ: sendIQ,
        emitEvent: emitEvent,
        generateID: generateID,
        connectedJID: { connectedJID },
        domain: "example.com",
        sendElement: sendElement,
        serverStreamFeatures: serverStreamFeatures,
        dispatchDecryptedMessage: dispatchDecryptedMessage,
        reportConnectionLost: reportConnectionLost
    )
}

// MARK: - Stubbed Room Module

/// A room module driven without a client, whose rooms answer disco#info with what `answerRoomInfo` returns or throws.
/// Its other IQs get an empty result.
func makeStubbedRoomModule(
    resuming: MUCResumeState? = nil,
    emitEvent: @Sendable @escaping (XMPPEvent) -> Void = { _ in },
    generateID: @Sendable @escaping () -> String = { "test-1" },
    answerRoomInfo: @escaping @Sendable () throws -> XMLElement?
) -> MUCModule {
    let module = MUCModule(resuming: resuming)
    module.setUp(makeStubModuleContext(
        sendIQ: { iq, _ in
            guard iq.childElement?.namespace == XMPPNamespaces.discoInfo else { return nil }
            return try answerRoomInfo()
        },
        emitEvent: emitEvent,
        generateID: generateID
    ))
    return module
}

// MARK: - STARTTLS Failure

/// Expects `operation` to fail STARTTLS with `reason` before `mock` upgrades to TLS.
func expectTLSNegotiationFailure(
    reason: String,
    mock: MockTransport,
    sourceLocation: SourceLocation = #_sourceLocation,
    performing operation: () async throws -> Void
) async {
    let error = await #expect(throws: XMPPClientError.self, sourceLocation: sourceLocation) {
        try await operation()
    }
    guard case let .tlsNegotiationFailed(actual) = error else {
        Issue.record("Expected tlsNegotiationFailed, got \(String(describing: error))", sourceLocation: sourceLocation)
        return
    }
    #expect(actual == reason, sourceLocation: sourceLocation)
    let isTLS = await mock.isTLSUpgraded
    #expect(!isTLS, sourceLocation: sourceLocation)
}

// MARK: - Event Collection

/// Collects events until `predicate` returns `true`, with a timeout.
func collectEvents(
    from client: XMPPClient,
    timeout: Duration = .seconds(5),
    until predicate: @Sendable @escaping (XMPPEvent) -> Bool
) async throws -> [XMPPEvent] {
    try await withThrowingTaskGroup(of: [XMPPEvent].self) { group in
        group.addTask {
            var collected: [XMPPEvent] = []
            for await event in client.events {
                collected.append(event)
                if predicate(event) { break }
            }
            return collected
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw XMPPClientError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

// MARK: - SASL2 Constants

/// Features offering SASL2 with PLAIN, inline resume, and Bind 2 that can enable carbons and SM inline.
/// Uses PLAIN only for simpler test handshakes (no challenge/response needed).
let testFeaturesSASL2 = testSASL2Features(bind2Inline: [XMPPNamespaces.carbons, XMPPNamespaces.sm])

/// SASL2 features with PLAIN whose Bind 2 can enable the `bind2Inline` features, and which take an inline
/// `<resume/>` when `inlineSM` is set.
func testSASL2Features(bind2Inline: [String], inlineSM: Bool = true) -> String {
    let inlineFeatures = bind2Inline.map { "<feature var='\($0)'/>" }.joined()
    return """
    <features xmlns='http://etherx.jabber.org/streams'>\
    <authentication xmlns='urn:xmpp:sasl:2'>\
    <mechanism>PLAIN</mechanism>\
    <inline>\
    <bind xmlns='urn:xmpp:bind:0'><inline>\(inlineFeatures)</inline></bind>\
    \(inlineSM ? "<sm xmlns='urn:xmpp:sm:3'/>" : "")\
    </inline>\
    </authentication>\
    </features>
    """
}

/// SASL2 success with Bind 2 and inline SM enabled.
let testSASL2SuccessWithBind = """
<success xmlns='urn:xmpp:sasl:2'>\
<authorization-identifier>user@example.com/ducko</authorization-identifier>\
<bound xmlns='urn:xmpp:bind:0'>\
<enabled xmlns='urn:xmpp:sm:3' id='sm-resume-1' max='300'/>\
</bound>\
</success>
"""

/// SASL2 success resuming the stream `sm-resume-1`, acknowledging `h` client stanzas, under the account's
/// `authorizationIdentifier`.
func testSASL2SuccessResumed(authorizationIdentifier: String = "user@example.com", h: UInt32 = 0) -> String {
    """
    <success xmlns='urn:xmpp:sasl:2'>\
    <authorization-identifier>\(authorizationIdentifier)</authorization-identifier>\
    <resumed xmlns='urn:xmpp:sm:3' h='\(h)' previd='sm-resume-1'/>\
    </success>
    """
}

/// SASL2 success that refuses the inline resume and starts a fresh Bind 2 session with inline SM.
let testSASL2SuccessResumeFailed = """
<success xmlns='urn:xmpp:sasl:2'>\
<authorization-identifier>user@example.com/ducko</authorization-identifier>\
<failed xmlns='urn:xmpp:sm:3'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></failed>\
<bound xmlns='urn:xmpp:bind:0'>\
<enabled xmlns='urn:xmpp:sm:3' id='sm-resume-2' max='300'/>\
</bound>\
</success>
"""

/// Post-auth features after SASL2 (bind already done, only informational).
let testPostSASL2Features = """
<features xmlns='http://etherx.jabber.org/streams'>\
<sm xmlns='urn:xmpp:sm:3'/>\
</features>
"""

/// Drives a SASL2 handshake over a client connected with TLS, answering each client `<authenticate>` with the next
/// reply. XEP-0388 has no stream restart, so the final `<success>` is followed only by the authenticated stream's
/// `postAuthFeatures`. Pass `nil` for a resumed stream, which gets none.
func simulateSASL2Handshake(
    _ mock: MockTransport, features: String, replies: [String], postAuthFeatures: String? = testPostSASL2Features
) async {
    await mock.waitForSent(count: 1) // stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(features)
    for (index, reply) in replies.enumerated() {
        await mock.waitForSent(count: 2 + index) // <authenticate> sent
        await mock.simulateReceive(reply)
    }
    if let postAuthFeatures {
        await mock.simulateReceive(postAuthFeatures)
    }
}

/// Simulates a SASL2 + Bind 2 connect handshake using PLAIN mechanism.
func simulateSASL2Connect(_ mock: MockTransport) async {
    await simulateSASL2Handshake(mock, features: testFeaturesSASL2, replies: [testSASL2SuccessWithBind])
}

// MARK: - Sign-In

/// The message a sign-in that failed with `error` reports.
func failureMessage(_ error: (any Error)?) -> String? {
    guard case let .authenticationFailed(failure) = error as? XMPPClientError else { return nil }
    return failure.message
}

/// Stream features offering `mechanisms` over SASL1 and, with Bind 2, `sasl2Mechanisms` (by default the same) over
/// SASL2. The SASL2 offer lists the upgrade tasks `upgrades`, and `types` go in `<sasl-channel-binding>` when given.
func offer(_ mechanisms: [String], sasl2Mechanisms: [String]? = nil, types: [String]? = nil, upgrades: [String] = []) -> String {
    let names = { (mechanisms: [String]) in mechanisms.map { "<mechanism>\($0)</mechanism>" }.joined() }
    let binding = types.map { types in
        "<sasl-channel-binding xmlns='urn:xmpp:sasl-cb:0'>"
            + types.map { "<channel-binding type='\($0)'/>" }.joined() + "</sasl-channel-binding>"
    } ?? ""
    let upgradeTasks = upgrades.map { "<upgrade xmlns='urn:xmpp:sasl:upgrade:0'>\($0)</upgrade>" }.joined()
    return """
    <features xmlns='http://etherx.jabber.org/streams'>\
    <mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(names(mechanisms))</mechanisms>\
    <authentication xmlns='urn:xmpp:sasl:2'>\(upgradeTasks)\(names(sasl2Mechanisms ?? mechanisms))<inline><bind xmlns='urn:xmpp:bind:0'/></inline></authentication>\
    \(binding)</features>
    """
}

/// The salt ejabberd sent in a captured XEP-0480 upgrade.
let capturedUpgradeSalt = "7wdCPeyqtCe6el/JshPQuw=="

/// Python's `hashlib.pbkdf2_hmac` SHA-256 SaltedPassword for the password `pencil`, `capturedUpgradeSalt` and 4096
/// iterations.
let capturedUpgradeSHA256Hash = "McvlDgcSSz3ZXdcRHP9SCzjvEGtf56O5FjRSpnVhosw="

/// The next stanza `mock` sends that matches `predicate`, or `nil` once `connect` ends without one.
func nextSent(
    _ mock: MockTransport, before connect: Task<Void, any Error>, matching predicate: @escaping @Sendable (String) -> Bool
) async -> String? {
    let (stream, continuation) = AsyncStream.makeStream(of: String?.self)
    let watcher = Task { await continuation.yield(mock.waitForSent(matching: predicate)) }
    let finisher = Task {
        _ = await connect.result
        continuation.yield(nil)
    }
    defer {
        watcher.cancel()
        finisher.cancel()
    }
    for await stanza in stream {
        return stanza
    }
    return nil
}

// MARK: - Sent-Response Waiting

/// Owns a client operation while the test plays its peer, including failure cleanup.
func withIQOperation<Result: Sendable>(
    client: XMPPClient,
    operation: @escaping @Sendable () async throws -> Result,
    respond: () async throws -> Void
) async throws -> Result {
    let task = Task { try await operation() }
    do {
        try await respond()
        return try await task.value
    } catch {
        task.cancel()
        await disconnectFast(client)
        _ = await task.result
        throw error
    }
}

/// Waits for the intended client request without clearing history or sending a response.
func awaitOutgoingIQ(
    on mock: MockTransport,
    type: XMPPIQ.IQType,
    namespace: String,
    timeout: Duration = .seconds(2),
    matching predicate: @escaping @Sendable (String) -> Bool
) async throws -> (xml: String, id: String) {
    let xml = try await awaitSent(on: mock, timeout: timeout) { stanza in
        guard stanza.hasPrefix("<iq "), let end = stanza.firstIndex(of: ">") else { return false }
        let opening = stanza[..<end]
        let matchesType = opening.contains("type=\"\(type.rawValue)\"") || opening.contains("type='\(type.rawValue)'")
        let matchesNamespace = stanza.contains("xmlns=\"\(namespace)\"") || stanza.contains("xmlns='\(namespace)'")
        return matchesType && matchesNamespace && predicate(stanza)
    }
    let opening = String(xml.prefix { $0 != ">" })
    guard let id = extractIQID(from: opening), !id.isEmpty else {
        throw XMPPClientError.unexpectedStreamState("Outgoing IQ has no request ID")
    }
    return (xml, id)
}

/// Clears the mock's sent buffer, injects `stanza`, then suspends until an outgoing stanza satisfies
/// `predicate` or `timeout` elapses. Returns the matching string, or `nil` on timeout / no match.
///
/// The wait is event-driven: `MockTransport.waitForSent(matching:)` fires the instant a matching stanza is
/// sent (or finds one already buffered), raced against a timeout task. Actor isolation makes a match
/// deterministic regardless of scheduler load — only the `nil`/timeout path depends on the clock.
///
/// Call sites must not chain a second `simulateReceive` into the same `awaitSentResponse` invocation without
/// first awaiting the previous response to completion — a pending fire-and-forget reply from an earlier
/// stimulus could otherwise satisfy the new predicate and mask a missing response.
func awaitSentResponse(
    on mock: MockTransport,
    afterReceiving stanza: String,
    matching predicate: @escaping @Sendable (String) -> Bool,
    timeout: Duration = .seconds(2)
) async -> String? {
    await mock.clearSentBytes()
    // Receiving before waiting is safe: `awaitSent` also matches a reply sent before it starts.
    await mock.simulateReceive(stanza)
    return try? await awaitSent(on: mock, timeout: timeout, matching: predicate)
}

// MARK: - SOCKS5 Greeting Probe

/// A raw TCP client that starts a SOCKS5 handshake with a listener and holds it open. The listener answers the greeting
/// only from inside `accept`, so a reply proves that accept is running.
final class SOCKS5GreetingProbe: Sendable {
    private let fd: Int32

    /// Connects to `host:port` and sends a no-auth greeting; `nil` when that fails.
    init?(host: String, port: UInt16) {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        disableSIGPIPE(fd)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        let greeting: [UInt8] = [0x05, 0x01, 0x00]
        guard connected == 0, greeting.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == greeting.count else {
            Darwin.close(fd)
            return nil
        }
        self.fd = fd
    }

    /// Connects to the host and port a SOCKS5 `<candidate>` element advertises.
    convenience init?(candidate: XMLElement) {
        guard let host = candidate.attribute("host"), let port = candidate.attribute("port").flatMap(UInt16.init) else { return nil }
        self.init(host: host, port: port)
    }

    /// Waits up to two seconds for the listener's no-auth reply.
    func awaitReply() -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 2000) > 0 else { return false }
        var reply = [UInt8](repeating: 0, count: 2)
        let received = reply.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, MSG_WAITALL) }
        return received == 2 && reply == [0x05, 0x00]
    }

    /// Waits up to two seconds for the listener to close the probe's connection.
    func awaitClosed() -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 2000) > 0 else { return false }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, 0) <= 0
    }

    deinit {
        Darwin.close(fd)
    }
}

// MARK: - Jingle File Sources

/// A file source over bytes already in memory.
actor InMemoryJingleFileSource: JingleFileSource {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    func read(upTo count: Int) -> [UInt8] {
        let end = min(offset + count, bytes.count)
        defer { offset = end }
        return Array(bytes[offset ..< end])
    }
}

extension JingleModule {
    /// Sends file data held in memory. See `sendFileData(sid:offerID:source:totalBytes:)`.
    func sendFileData(sid: String, data: [UInt8]) async throws {
        try await sendFileData(sid: sid, source: InMemoryJingleFileSource(data), totalBytes: Int64(data.count))
    }
}

// MARK: - Jingle Initiator Harness

extension JingleTiming {
    /// Wait limits short enough for a test to observe each one elapse.
    static let short = JingleTiming(
        endOfStreamWait: .milliseconds(300),
        checksumWait: .milliseconds(300),
        unclaimedReceiveExpiry: .milliseconds(300),
        senderConfirmationWait: .milliseconds(300),
        proxyConnectWait: .milliseconds(300),
        transportReadyWait: .milliseconds(300),
        sendStallWait: .milliseconds(300),
        receiveStallWait: .milliseconds(300)
    )
}

/// Drives a `JingleModule` through a recording `ModuleContext` without a client, so a test can play the peer of a
/// session, answer or fail its IQs, and fail chosen outbound Jingle actions.
final class JingleInitiatorHarness: Sendable {
    private struct Recorded {
        var stanzas: [XMLElement] = []
        var iqs: [XMLElement] = []
        var events: [XMPPEvent] = []
        var nextID = 0
    }

    static let peer = FullJID.parse("peer@example.com/res")!

    let module: JingleModule
    private let recorded = OSAllocatedUnfairLock(initialState: Recorded())

    /// - Parameters:
    ///   - offersDirectCandidates: Whether the module offers this host's addresses.
    ///   - failingActions: Jingle actions whose outbound send fails.
    ///   - answerIQ: Returns the payload answering an outbound IQ, or throws its error.
    ///   - sending: Runs on each outbound stanza once it is recorded, and can hold its send or fail it.
    init(
        timing: JingleTiming = .init(),
        offersDirectCandidates: Bool = true,
        failingActions: Set<String> = [],
        answerIQ: @escaping @Sendable (XMLElement) async throws -> XMLElement? = { _ in nil },
        sending: @escaping @Sendable (XMLElement) async throws -> Void = { _ in }
    ) {
        module = JingleModule(timing: timing, offersDirectCandidates: offersDirectCandidates)
        let recorded = recorded
        module.setUp(ModuleContext(
            sendStanza: { stanza, onAccepted in
                onAccepted?()
                recorded.withLock { $0.stanzas.append(stanza.element) }
                if let action = stanza.element.child(named: "jingle")?.attribute("action"), failingActions.contains(action) {
                    throw XMPPClientError.sendFailed("The connection was closed")
                }
                try await sending(stanza.element)
            },
            sendIQ: { iq, _ in
                recorded.withLock { $0.iqs.append(iq.element) }
                return try await answerIQ(iq.element)
            },
            emitEvent: { event in recorded.withLock { $0.events.append(event) } },
            generateID: {
                recorded.withLock { state in
                    state.nextID += 1
                    return "id-\(state.nextID)"
                }
            },
            connectedJID: { FullJID.parse("user@example.com/res") },
            domain: "example.com"
        ))
    }

    func initiate(file: JingleFileDescription = JingleFileDescription(name: "test.txt", size: 3)) async throws -> String {
        try await module.initiateFileTransfer(to: Self.peer, file: file)
    }

    /// Delivers a Jingle IQ from `from` (the peer by default) with `action` and `payload` for the session.
    func receive(
        action: String, sid: String, payload: [XMLElement] = [], id: String? = nil, from: FullJID = JingleInitiatorHarness.peer
    ) throws {
        var jingle = XMLElement(name: "jingle", namespace: XMPPNamespaces.jingle, attributes: ["action": action, "sid": sid])
        for child in payload {
            jingle.addChild(child)
        }
        try deliver(jingle, id: id ?? "peer-\(action)", from: from)
    }

    func deliver(_ child: XMLElement, id: String, from: FullJID = JingleInitiatorHarness.peer) throws {
        var iq = XMPPIQ(type: .set, id: id)
        iq.from = .full(from)
        iq.element.addChild(child)
        _ = try module.handleIQ(iq)
    }

    /// Delivers the peer's session-initiate for `file`, whose content names `senders` when given.
    func receiveOffer(
        sid: String, file: JingleFileDescription = JingleFileDescription(name: "test.txt", size: 3), senders: JingleContentSenders? = nil
    ) throws {
        try receive(action: JingleAction.sessionInitiate.rawValue, sid: sid, payload: [Self.fileContent(file, senders: senders)], id: "initiate-\(sid)")
    }

    /// Delivers the peer's offer of a 3-byte file under `sid` over SOCKS5, whose one direct candidate `cid` is a listener
    /// the test runs, and returns that listener for `acceptSOCKS5Offer(sid:listener:)`.
    func receiveSOCKS5Offer(sid: String = "sid-1", cid: String = "peer-direct") async throws -> SOCKS5Listener {
        let listener = SOCKS5Listener()
        let port = try await listener.start()
        let candidate = SOCKS5Transport.Candidate(cid: cid, host: "127.0.0.1", port: port, jid: Self.peer.description, priority: 100, type: .direct)
        let content = JingleContent(
            name: "a-file-offer", creator: "initiator", description: JingleFileDescription(name: "test.txt", size: 3),
            transport: .socks5(SOCKS5Transport(sid: "transport-sid", candidates: [candidate]))
        )
        try receive(action: JingleAction.sessionInitiate.rawValue, sid: sid, payload: [content.toXML()])
        return listener
    }

    /// Accepts the peer's SOCKS5 offer under `sid` and takes this side's dial to the peer's `listener`, returning the
    /// peer's end once the transport is ready.
    func acceptSOCKS5Offer(sid: String = "sid-1", listener: SOCKS5Listener) async throws -> SOCKS5Connection {
        try await module.acceptFileTransfer(sid: sid)
        let destination = SOCKS5Connection.destinationAddress(
            sid: "transport-sid", initiatorJID: Self.peer.description, targetJID: "user@example.com/res"
        )
        let peer = try await listener.accept(expectedDstAddr: destination)
        await listener.close()
        try await module.awaitTransportReady(sid: sid)
        return peer
    }

    /// Matches this side's IQ reply of `type` (`result` or `error`) to the peer's IQ `id`.
    static func isReply(to id: String, type: String) -> @Sendable (XMLElement) -> Bool {
        { $0.name == "iq" && $0.attribute("id") == id && $0.attribute("type") == type }
    }

    /// A content offering `file`, sent with `senders`, over a SOCKS5 transport without candidates.
    static func fileContent(_ file: JingleFileDescription, senders: JingleContentSenders? = nil) -> XMLElement {
        JingleContent(
            name: "a-file-offer", creator: "initiator", senders: senders, description: file,
            transport: .socks5(SOCKS5Transport(sid: "transport-sid"))
        ).toXML()
    }

    /// The content of the responder's session-accept for this side's offer in session `sid`, offering `candidates`.
    func acceptedContent(sid: String, candidates: [SOCKS5Transport.Candidate]) throws -> XMLElement {
        let transportSID = try #require(offeredContent(sid: sid)?.child(named: "transport")?.attribute("sid"))
        return JingleContent(
            name: "a-file-offer", creator: "initiator", description: JingleFileDescription(name: "test.txt", size: 3),
            transport: .socks5(SOCKS5Transport(sid: transportSID, candidates: candidates))
        ).toXML()
    }

    /// A content switching the transfer to IBB stream `ibbSID`.
    static func ibbContent(ibbSID: String = "ibb-sid") -> XMLElement {
        var content = XMLElement(name: "content", attributes: ["creator": "initiator", "name": "a-file-offer"])
        content.addChild(IBBTransport(sid: ibbSID, blockSize: 4096).toXML())
        return content
    }

    /// The peer's IBB `<open/>` of stream `ibbSID` in blocks of `blockSize` bytes.
    static func ibbOpen(ibbSID: String = "ibb-sid", blockSize: Int = 4096) -> XMLElement {
        ibbOpen(attributes: ["sid": ibbSID, "block-size": String(blockSize)])
    }

    /// An IBB `<open/>` with exactly `attributes`, for one that is malformed or asks for more.
    static func ibbOpen(attributes: [String: String]) -> XMLElement {
        XMLElement(name: "open", namespace: XMPPNamespaces.ibb, attributes: attributes)
    }

    /// An IBB data chunk carrying `bytes`.
    static func ibbData(_ bytes: [UInt8], seq: UInt16, ibbSID: String = "ibb-sid") -> XMLElement {
        var data = XMLElement(name: "data", namespace: XMPPNamespaces.ibb, attributes: ["sid": ibbSID, "seq": String(seq)])
        data.addText(Base64.encode(bytes))
        return data
    }

    static func ibbClose(ibbSID: String = "ibb-sid") -> XMLElement {
        XMLElement(name: "close", namespace: XMPPNamespaces.ibb, attributes: ["sid": ibbSID])
    }

    /// A session-info carrying a checksum of `hash` in `algo`.
    static func checksum(_ hash: String, algo: String = "sha-256") -> XMLElement {
        var hashElement = XMLElement(name: "hash", namespace: XMPPNamespaces.hashes2, attributes: ["algo": algo])
        hashElement.addText(hash)
        var file = XMLElement(name: "file")
        file.addChild(hashElement)
        var checksum = XMLElement(name: "checksum", namespace: XMPPNamespaces.jingleFileTransfer, attributes: ["name": "a-file-offer"])
        checksum.addChild(file)
        return checksum
    }

    /// A `<reason>` naming `name`, as a session-terminate carries.
    static func reason(_ name: String) -> XMLElement {
        var reason = XMLElement(name: "reason")
        reason.addChild(XMLElement(name: name))
        return reason
    }

    static func isCompletion(_ event: XMPPEvent) -> Bool {
        if case .jingleFileTransferCompleted = event { return true }
        return false
    }

    static func isFailure(_ event: XMPPEvent) -> Bool {
        if case .jingleFileTransferFailed = event { return true }
        return false
    }

    /// Connects to this side's direct candidate as the peer would, completing the SOCKS5 handshake for session `sid`.
    func connectToDirectCandidate(sid: String) async throws -> SOCKS5Connection {
        let candidate = try offeredCandidate(type: "direct", sid: sid)
        let host = try #require(candidate.attribute("host"))
        let port = try #require(candidate.attribute("port").flatMap(UInt16.init))
        let offer = try #require(offeredContent(sid: sid))
        let transportSID = try #require(offer.child(named: "transport")?.attribute("sid"))
        let destination = SOCKS5Connection.destinationAddress(
            sid: transportSID, initiatorJID: "user@example.com/res", targetJID: Self.peer.description
        )
        let connection = SOCKS5Connection()
        try await connection.connect(host: host, port: port, destinationAddress: destination)
        return connection
    }

    /// Delivers the peer's candidate-used nominating this side's direct candidate for session `sid`.
    func nominateDirectCandidate(sid: String) throws {
        try receive(action: JingleAction.transportInfo.rawValue, sid: sid, payload: [Self.candidateUsed(offeredCandidate(type: "direct", sid: sid))])
    }

    /// A transport-info content carrying the peer's candidate-used for one of this side's offered `candidate`s.
    static func candidateUsed(_ candidate: XMLElement) throws -> XMLElement {
        let cid = try #require(candidate.attribute("cid"))
        return socks5Info(XMLElement(name: "candidate-used", attributes: ["cid": cid]))
    }

    /// A transport-info content carrying one SOCKS5 child, like `<candidate-error/>` or `<candidate-used cid='…'/>`.
    static func socks5Info(_ child: XMLElement) -> XMLElement {
        var transport = XMLElement(name: "transport", namespace: XMPPNamespaces.jingleS5B)
        transport.addChild(child)
        var content = XMLElement(name: "content", attributes: ["creator": "initiator", "name": "a-file-offer"])
        content.addChild(transport)
        return content
    }

    /// The SOCKS5 candidates this side offered in its first stanza with `action`, for session `sid` when one is given.
    func offeredCandidates(action: String = JingleAction.sessionInitiate.rawValue, sid: String? = nil) -> [XMLElement] {
        offeredContent(action: action, sid: sid)?.child(named: "transport")?.children(named: "candidate") ?? []
    }

    /// The content this side offered in its first stanza with `action`, for session `sid` when one is given.
    func offeredContent(action: String = JingleAction.sessionInitiate.rawValue, sid: String? = nil) -> XMLElement? {
        let offer = recorded.withLock { recorded in
            (recorded.iqs + recorded.stanzas).first { stanza in
                guard let jingle = stanza.child(named: "jingle"), jingle.attribute("action") == action else { return false }
                return sid == nil || jingle.attribute("sid") == sid
            }
        }
        return offer?.child(named: "jingle")?.child(named: "content")
    }

    /// Waits up to `timeout` for a sent Jingle stanza with `action`.
    func sentJingle(action: String, timeout: Duration = .seconds(2)) async throws -> XMLElement? {
        try await poll(timeout) { recorded in
            recorded.stanzas.first { $0.child(named: "jingle")?.attribute("action") == action }
        }
    }

    func sentJingleCount(action: String) -> Int {
        recorded.withLock { recorded in
            recorded.stanzas.count { $0.child(named: "jingle")?.attribute("action") == action }
        }
    }

    /// The first offered candidate of `type` (`direct` or `proxy`).
    func offeredCandidate(type: String, action: String = JingleAction.sessionInitiate.rawValue, sid: String? = nil) throws -> XMLElement {
        try #require(offeredCandidates(action: action, sid: sid).first { $0.attribute("type") == type })
    }

    /// Waits up to `timeout` for a sent stanza matching `predicate`.
    func sentStanza(timeout: Duration = .seconds(2), matching predicate: @escaping @Sendable (XMLElement) -> Bool) async throws -> XMLElement? {
        try await poll(timeout) { recorded in recorded.stanzas.first(where: predicate) }
    }

    func sentStanzaCount(matching predicate: @escaping @Sendable (XMLElement) -> Bool) -> Int {
        recorded.withLock { $0.stanzas.count(where: predicate) }
    }

    /// Expects the IQ `id` to get a reply of `type` and no other. A later IQ for session `sid` marks the point by which
    /// a second reply would have been sent.
    @discardableResult
    func expectSingleReply(to id: String, type: String, sid: String) async throws -> XMLElement? {
        let reply = try await sentStanza(matching: Self.isReply(to: id, type: type))
        #expect(reply != nil)
        try receive(action: JingleAction.sessionInfo.rawValue, sid: sid, id: "sentinel")
        #expect(try await sentStanza { $0.name == "iq" && $0.attribute("id") == "sentinel" } != nil)
        #expect(sentStanzaCount { $0.attribute("id") == id } == 1)
        return reply
    }

    /// Expects the IQ `id` to get one out-of-order error and nothing else.
    func expectSingleOutOfOrderError(to id: String, sid: String) async throws {
        let error = try #require(try await expectSingleReply(to: id, type: "error", sid: sid))
        #expect(error.child(named: "error")?.child(named: "unexpected-request", namespace: XMPPNamespaces.stanzas) != nil)
        #expect(error.child(named: "error")?.child(named: "out-of-order", namespace: XMPPNamespaces.jingleErrors) != nil)
    }

    func eventCount(matching predicate: @escaping @Sendable (XMPPEvent) -> Bool) -> Int {
        recorded.withLock { $0.events.count(where: predicate) }
    }

    /// The file offers the module announced, oldest first.
    func receivedOffers() -> [JingleFileOffer] {
        recorded.withLock { state in
            state.events.compactMap { event in
                if case let .jingleFileTransferReceived(offer) = event { offer } else { nil }
            }
        }
    }

    /// Waits up to `timeout` for a sent IQ matching `predicate`.
    func sentIQ(timeout: Duration = .seconds(2), matching predicate: @escaping @Sendable (XMLElement) -> Bool) async throws -> XMLElement? {
        try await poll(timeout) { recorded in recorded.iqs.first(where: predicate) }
    }

    func sentIQCount(matching predicate: @escaping @Sendable (XMLElement) -> Bool) -> Int {
        recorded.withLock { $0.iqs.count(where: predicate) }
    }

    /// Waits up to `timeout` for an emitted event matching `predicate`.
    func event(timeout: Duration = .seconds(2), matching predicate: @escaping @Sendable (XMPPEvent) -> Bool) async throws -> XMPPEvent? {
        try await poll(timeout) { recorded in recorded.events.first(where: predicate) }
    }

    private func poll<T: Sendable>(_ timeout: Duration, _ find: @escaping @Sendable (Recorded) -> T?) async throws -> T? {
        let deadline = ContinuousClock.now + timeout
        repeat {
            if let found = recorded.withLock({ find($0) }) { return found }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        return nil
    }
}

// MARK: - Test Vectors

/// The bytes a hex test vector spells.
func bytes(_ hex: String) -> [UInt8] {
    var result: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        result.append(UInt8(hex[index ..< next], radix: 16)!)
        index = next
    }
    return result
}

// MARK: - Channel Bindings

/// Stand-in channel-binding values, distinct per type so a test can tell which one went out.
let endPointBinding: [UInt8] = Array(repeating: 0xCD, count: 32)
let exporterBinding: [UInt8] = Array(repeating: 0xEF, count: 32)
/// What TLS 1.3 computes: both binding types.
let tls13Bindings: [ChannelBindingType: [UInt8]] = [.tlsServerEndPoint: endPointBinding, .tlsExporter: exporterBinding]

/// Fetches a server's registration form on a session of its own, closed on every exit, over `transport` or, without
/// one, the default transport.
func fetchRegistrationForm(
    domain: String, host: String? = nil, port: UInt16 = 5222, transport: (any XMPPTransport)? = nil
) async throws -> RegistrationModule.RegistrationForm {
    let session = if let transport {
        try await RegistrationSession.open(domain: domain, host: host, port: port, transport: transport)
    } else {
        try await RegistrationSession.open(domain: domain, host: host, port: port)
    }
    do {
        let form = try await session.fetchForm()
        await session.close()
        return form
    } catch {
        await session.close()
        throw error
    }
}

/// A loopback TCP socket bound to an ephemeral port, listening when `listens` is set; `nil` when setup fails.
func loopbackSocket(listens: Bool) -> (fd: Int32, port: UInt16)? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, !listens || listen(fd, 1) == 0 else {
        Darwin.close(fd)
        return nil
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return (fd, UInt16(bigEndian: address.sin_port))
}
