import Darwin
import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

// MARK: - XML Constants

// The stream-open and features constants shared with DuckoCoreTests live in
// `DuckoTestSupport/HandshakeFixtures.swift`. The SASL2/ISR constants below are XMPP-only, so they stay here.

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

/// Simulates a connect handshake without TLS.
func simulateNoTLSConnect(_ mock: MockTransport, postAuthFeatures: String = testFeaturesBind) async {
    await mock.waitForSent(count: 1) // stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(testFeaturesNoTLS)
    await mock.waitForSent(count: 2) // auth element sent
    await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
    await mock.waitForSent(count: 3) // post-auth stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(postAuthFeatures)
    await mock.waitForSent(count: 4) // bind IQ sent
    await mock.simulateReceive(testBindResult)
}

/// Simulates a connect handshake without TLS, followed by a roster response.
func simulateNoTLSConnect(_ mock: MockTransport, rosterResponse: String) async {
    await simulateNoTLSConnect(mock)
    await mock.waitForSent(count: 5) // roster GET IQ sent
    await mock.simulateReceive(rosterResponse)
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

// MARK: - Stub Module Context

/// A `ModuleContext` with inert dependencies for driving a module without a client; pass only the ones a test observes.
func makeStubModuleContext(
    sendStanza: @escaping ModuleContext.StanzaSender = { _, onAccepted in onAccepted?() },
    sendIQ: @escaping ModuleContext.IQSender = { _, _ in nil },
    emitEvent: @Sendable @escaping (XMPPEvent) -> Void = { _ in },
    sendElement: @Sendable @escaping (XMLElement) async throws -> Void = { _ in },
    serverStreamFeatures: @Sendable @escaping () -> XMLElement? = { nil }
) -> ModuleContext {
    ModuleContext(
        sendStanza: sendStanza,
        sendIQ: sendIQ,
        emitEvent: emitEvent,
        generateID: { "test-1" },
        connectedJID: { FullJID.parse("user@example.com/res") },
        domain: "example.com",
        sendElement: sendElement,
        serverStreamFeatures: serverStreamFeatures
    )
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

/// Features offering SASL2 with PLAIN and inline Bind 2 + SM.
/// Uses PLAIN only for simpler test handshakes (no challenge/response needed).
let testFeaturesSASL2 = """
<features xmlns='http://etherx.jabber.org/streams'>\
<authentication xmlns='urn:xmpp:sasl:2'>\
<mechanism>PLAIN</mechanism>\
<inline>\
<bind xmlns='urn:xmpp:bind:0'/>\
<sm xmlns='urn:xmpp:sm:3'/>\
</inline>\
</authentication>\
</features>
"""

/// SASL2 success with Bind 2 and inline SM enabled.
let testSASL2SuccessWithBind = """
<success xmlns='urn:xmpp:sasl:2'>\
<authorization-identifier>user@example.com/ducko</authorization-identifier>\
<bound xmlns='urn:xmpp:bind:0'>\
<enabled xmlns='urn:xmpp:sm:3' id='sm-resume-1' max='300'/>\
</bound>\
</success>
"""

/// Post-auth features after SASL2 (bind already done, only informational).
let testPostSASL2Features = """
<features xmlns='http://etherx.jabber.org/streams'>\
<sm xmlns='urn:xmpp:sm:3'/>\
</features>
"""

/// Drives a SASL2 handshake, answering each client `<authenticate>` with the next reply. XEP-0388 has no
/// stream restart, so the final `<success>` is followed only by the authenticated stream's `<features>`.
func simulateSASL2Handshake(_ mock: MockTransport, features: String, replies: [String]) async {
    await mock.waitForSent(count: 1) // stream opening sent
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(features)
    for (index, reply) in replies.enumerated() {
        await mock.waitForSent(count: 2 + index) // <authenticate> sent
        await mock.simulateReceive(reply)
    }
    await mock.simulateReceive(testPostSASL2Features)
}

/// Simulates a SASL2 + Bind 2 connect handshake using PLAIN mechanism.
func simulateSASL2Connect(_ mock: MockTransport) async {
    await simulateSASL2Handshake(mock, features: testFeaturesSASL2, replies: [testSASL2SuccessWithBind])
}

// MARK: - ISR Constants

/// SASL2 features with ISR support in inline.
let testFeaturesSASL2WithISR = """
<features xmlns='http://etherx.jabber.org/streams'>\
<authentication xmlns='urn:xmpp:sasl:2'>\
<mechanism>PLAIN</mechanism>\
<inline>\
<bind xmlns='urn:xmpp:bind:0'/>\
<sm xmlns='urn:xmpp:sm:3'/>\
<isr xmlns='https://xmpp.org/extensions/isr/0'/>\
</inline>\
</authentication>\
</features>
"""

/// SASL2 success with Bind 2, inline SM enabled, and ISR token.
let testSASL2SuccessWithBindAndISR = """
<success xmlns='urn:xmpp:sasl:2'>\
<authorization-identifier>user@example.com/ducko</authorization-identifier>\
<bound xmlns='urn:xmpp:bind:0'>\
<enabled xmlns='urn:xmpp:sm:3' id='sm-resume-1' max='300'>\
<isr-enabled xmlns='https://xmpp.org/extensions/isr/0' token='initial-isr-token' mechanism='HT-SHA-256-ENDP'/>\
</enabled>\
</bound>\
</success>
"""

/// ISR success: contains `<resumed>` instead of `<bound>`, plus refreshed token.
let testISRSuccess = """
<success xmlns='urn:xmpp:sasl:2'>\
<authorization-identifier>user@example.com/ducko</authorization-identifier>\
<resumed xmlns='urn:xmpp:sm:3' h='0' previd='sm-resume-1'/>\
<isr-enabled xmlns='https://xmpp.org/extensions/isr/0' token='refreshed-token' mechanism='HT-SHA-256-ENDP'/>\
</success>
"""

/// ISR failure (token expired).
let testISRFailure = """
<failure xmlns='urn:xmpp:sasl:2'>\
<credentials-expired/>\
</failure>
"""

/// Simulates a SASL2 + Bind 2 connect that acquires an ISR token.
func simulateSASL2ConnectWithISR(_ mock: MockTransport) async {
    await simulateSASL2Handshake(mock, features: testFeaturesSASL2WithISR, replies: [testSASL2SuccessWithBindAndISR])
}

/// Simulates an ISR resume connect (server responds with ISR success).
func simulateISRResumeConnect(_ mock: MockTransport) async {
    await simulateSASL2Handshake(mock, features: testFeaturesSASL2WithISR, replies: [testISRSuccess])
}

/// Simulates ISR failure followed by normal SASL2 fallback.
func simulateISRFailAndFallback(_ mock: MockTransport) async {
    await simulateSASL2Handshake(mock, features: testFeaturesSASL2WithISR, replies: [testISRFailure, testSASL2SuccessWithBind])
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
    let xml = try await withThrowingTaskGroup(of: String?.self) { group in
        defer { group.cancelAll() }
        group.addTask {
            await mock.waitForSent { stanza in
                guard stanza.hasPrefix("<iq "), let end = stanza.firstIndex(of: ">") else { return false }
                let opening = stanza[..<end]
                let matchesType = opening.contains("type=\"\(type.rawValue)\"") || opening.contains("type='\(type.rawValue)'")
                let matchesNamespace = stanza.contains("xmlns=\"\(namespace)\"") || stanza.contains("xmlns='\(namespace)'")
                return matchesType && matchesNamespace && predicate(stanza)
            }
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw XMPPClientError.timeout
        }
        let result = try await group.next()!
        try Task.checkCancellation()
        guard let result else { throw XMPPClientError.timeout }
        return result
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

    return await withTaskGroup(of: String?.self) { group in
        group.addTask { await mock.waitForSent(matching: predicate) }
        // simulateReceive runs after the waiter task is scheduled; waitForSent scans the
        // already-sent buffer when it registers, so a reply that lands before the task
        // starts is still caught (no lost wakeup).
        await mock.simulateReceive(stanza)
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        for await result in group {
            group.cancelAll()
            return result
        }
        return nil
    }
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
    ///   - failingActions: Jingle actions whose outbound send fails.
    ///   - answerIQ: Returns the payload answering an outbound IQ, or throws its error.
    init(
        timing: JingleTiming = .init(),
        failingActions: Set<String> = [],
        answerIQ: @escaping @Sendable (XMLElement) async throws -> XMLElement? = { _ in nil }
    ) {
        module = JingleModule(timing: timing)
        let recorded = recorded
        module.setUp(ModuleContext(
            sendStanza: { stanza, onAccepted in
                onAccepted?()
                recorded.withLock { $0.stanzas.append(stanza.element) }
                if let action = stanza.element.child(named: "jingle")?.attribute("action"), failingActions.contains(action) {
                    throw XMPPClientError.sendFailed("The connection was closed")
                }
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

    /// A content switching the transfer to IBB stream `ibbSID`.
    static func ibbContent(ibbSID: String = "ibb-sid") -> XMLElement {
        var content = XMLElement(name: "content", attributes: ["creator": "initiator", "name": "a-file-offer"])
        content.addChild(IBBTransport(sid: ibbSID, blockSize: 4096).toXML())
        return content
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
