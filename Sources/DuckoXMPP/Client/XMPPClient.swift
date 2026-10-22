import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.client")

/// Orchestrates the full XMPP connection flow and dispatches stanzas to feature modules.
///
/// Drives: TCP → STARTTLS → SASL → resource binding → session establishment.
/// Incoming stanzas are routed to registered ``XMPPModule``s. Domain-level events
/// are exposed via ``events``.
public actor XMPPClient { // swiftlint:disable:this type_body_length
    let connection: XMPPConnection
    /// U-label canonical form, used for stream headers and JID construction.
    private let domain: String
    /// A-label form of `domain` for DNS/SRV resolution and TLS SNI; equals `domain` for ASCII
    /// domains. `nil` when `domain` cannot be converted to an A-label, in which case connecting
    /// fails closed rather than putting a non-lookup name on the wire.
    private let serverName: String?
    private let credentials: Credentials
    private var modules: [ObjectIdentifier: any XMPPModule] = [:]
    private var interceptors: [any StanzaInterceptor] = []
    private var state: ConnectionState = .disconnected
    private var disconnectInFlight: Bool = false
    private var disconnectTask: Task<Void, Never>?
    private var cleanUpTask: Task<Void, Never>?
    /// Set while module `handleDisconnect` hooks run, so a hook calling back into `disconnect()` doesn't wait for
    /// the teardown it is part of.
    @TaskLocal private static var isTearingDown = false
    private var readerTask: Task<Void, Never>?
    private var pendingIQs: [String: PendingIQ] = [:]
    private var pendingIQToken: UInt64 = 0
    private var pendingStreamClose: PendingStreamClose?
    private let tlsInfoLock = OSAllocatedUnfairLock<TLSInfo?>(initialState: nil)
    let verifiedSCRAMMechanismLock = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let connectedJIDLock = OSAllocatedUnfairLock<FullJID?>(initialState: nil)
    private let registeredModulesLock = OSAllocatedUnfairLock<[any XMPPModule]>(initialState: [])
    /// The server's post-auth stream features and its stream header's `xml:lang`.
    private let serverStreamLock = OSAllocatedUnfairLock<(features: XMLElement?, lang: String?)>(initialState: (nil, nil))
    /// Gate the PEP-reacting DuckoCore services (OMEMO, Avatar, Bookmarks) await before issuing PEP
    /// retrieves/publishes, so the server has seen this resource's entity caps via initial presence first
    /// (XEP-0163 §3.3.2). Lock-guarded for `nonisolated` reads, mirroring `connectedJIDLock`.
    let presenceReadinessLock = OSAllocatedUnfairLock<PresenceReadiness>(initialState: PresenceReadiness())
    /// Gate a `<message>` send awaits until the session's setup has completed.
    let sessionReadinessLock = OSAllocatedUnfairLock<SessionReadiness>(initialState: .closed)
    /// How long sign-in and session setup may take before the connection is closed.
    let signInTimeout: Duration
    /// Set when `signInTimeout` closed the connection, so the sign-in reports a timeout.
    var signInDeadlineFired = false

    private struct PendingIQ {
        let continuation: CheckedContinuation<XMLElement?, any Error>
        let requestTo: JID?
        let token: UInt64
        let onTerminal: ModuleContext.IQTerminalHandler?
        let timeoutTask: Task<Void, Never>
        var sendTask: Task<Void, Never>?
    }

    private struct PendingStreamClose {
        let continuation: CheckedContinuation<Bool, Never>
        let timeoutTask: Task<Void, Never>
    }

    private let eventContinuation: AsyncStream<XMPPEvent>.Continuation

    /// Domain events from the client (connected, disconnected, messages, etc.).
    public nonisolated let events: AsyncStream<XMPPEvent>

    public struct Credentials: Sendable {
        public let username: String
        public let password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    // MARK: - Connection State

    public enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case negotiatingTLS
        case authenticating
        case bindingResource
        case connected(FullJID)
    }

    private let requireTLS: Bool
    /// Refuses a sign-in whose only usable mechanism is PLAIN, before the password goes out.
    private let requiresSCRAM: Bool
    private let preferredResource: String?
    private let userAgent: SASL2UserAgent

    public init(
        domain: String,
        credentials: Credentials,
        transport: (any XMPPTransport)? = nil,
        requireTLS: Bool = true,
        requiresSCRAM: Bool = false,
        preferredResource: String? = nil,
        userAgent: SASL2UserAgent = SASL2UserAgent(),
        signInTimeout: Duration = .seconds(60)
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: XMPPEvent.self)
        self.events = stream
        self.eventContinuation = continuation
        // Canonicalize to the U-label form for stream headers/JIDs; derive the A-label for DNS/TLS.
        let canonicalDomain = IDNA.toUnicode(domain) ?? domain
        self.domain = canonicalDomain
        self.serverName = IDNA.toASCII(canonicalDomain)
        self.credentials = credentials
        self.connection = XMPPConnection(transport: transport ?? makeDefaultXMPPTransport())
        self.requireTLS = requireTLS
        self.requiresSCRAM = requiresSCRAM
        self.preferredResource = preferredResource
        self.userAgent = userAgent
        self.signInTimeout = signInTimeout
    }

    // MARK: - Module Registration

    public func register(_ module: some XMPPModule) {
        let key = ObjectIdentifier(type(of: module))
        modules[key] = module
        module.setUp(makeModuleContext())
        registeredModulesLock.withLock { [modules] in $0 = Array(modules.values) }
    }

    public func module<M: XMPPModule>(ofType type: M.Type) -> M? {
        modules[ObjectIdentifier(type)] as? M
    }

    // MARK: - Interceptor Registration

    public func addInterceptor(_ interceptor: any StanzaInterceptor) {
        interceptors.append(interceptor)
    }

    // MARK: - TLS Info

    /// Returns TLS connection info, or `nil` if TLS is not active.
    public nonisolated var tlsInfo: TLSInfo? {
        tlsInfoLock.withLock { $0 }
    }

    // MARK: - Features

    /// Union of all feature namespaces declared by registered modules.
    public var availableFeatures: Set<String> {
        Set(modules.values.flatMap(\.features))
    }

    // MARK: - ID Generation

    public nonisolated func generateID() -> String {
        Self.makeStanzaID()
    }

    /// A random stanza ID, unique across launches and the account's other clients, since peers match corrections,
    /// retractions and replies by ID.
    static func makeStanzaID() -> String {
        hexString((0 ..< 16).map { _ in UInt8.random(in: .min ... .max) })
    }

    // MARK: - Connect

    /// SRV-aware connect: resolves SRV records then runs the full XMPP handshake.
    public func connect() async throws {
        guard let serverName else { throw XMPPClientError.invalidDomain(domain) }
        try await performConnect { [connection] in
            try await connection.connect(domain: serverName)
        }
    }

    /// Direct connect to a specific host and port, bypassing SRV resolution.
    public func connect(host: String, port: UInt16) async throws {
        guard serverName != nil else { throw XMPPClientError.invalidDomain(domain) }
        try await performConnect { [connection] in
            try await connection.connect(host: host, port: port)
        }
    }

    /// Direct TLS connect — TLS from the first byte, no STARTTLS upgrade.
    public func connectWithTLS(host: String, port: UInt16) async throws {
        guard let serverName else { throw XMPPClientError.invalidDomain(domain) }
        try await performConnect { [connection] in
            try await connection.connectWithTLS(host: host, port: port, serverName: serverName)
        }
    }

    private func performConnect(establish: () async throws -> Void) async throws {
        guard !disconnectInFlight else {
            throw XMPPClientError.notConnected
        }
        guard case .disconnected = state else {
            throw XMPPClientError.alreadyConnected
        }
        state = .connecting
        signInDeadlineFired = false
        // Re-gate the readiness signals for this attempt; resumes any stale waiter left over from a prior
        // attempt so a reconnect on the same instance can't strand it against the new gate.
        settleInitialPresenceReadiness(open: false)
        settleSessionReadiness(.pending([]))

        do {
            try await establish()
        } catch {
            log.error("Connection failed: \(error)")
            state = .disconnected
            settleInitialPresenceReadiness(open: true)
            settleSessionReadiness(.closed)
            throw error
        }

        let reader = EventReader(connection.events)
        let deadline = startSignInDeadline()
        var readerStarted = false

        do {
            let resumed = try await performHandshake(reader: reader)
            serverStreamLock.withLock { $0.lang = reader.streamLang }
            // Runs before the reader starts. Until then the reader holds back what the server sent after the
            // handshake, so no module sees a stanza of this session before it knows whether the session was resumed.
            for module in modules.values {
                module.handleSessionEstablished(resumed: resumed)
            }
            startReader(reader: reader)
            readerStarted = true
            try await runPostHandshakeModules(resumed: resumed)
            try checkActiveSession()
            deadline.cancel()
            if !resumed {
                (modules[ObjectIdentifier(StreamManagementModule.self)] as? StreamManagementModule)?.completeSessionSetup()
            }
            settleSessionReadiness(.ready)
            // Emit `.streamResumed` after resume handlers; resumption skips roster fetch.
            if resumed, let fullJID = connectedJIDLock.withLock({ $0 }) {
                eventContinuation.yield(.streamResumed(fullJID))
            }
        } catch {
            deadline.cancel()
            throw await endFailedSignIn(error, readerStarted: readerStarted)
        }
    }

    /// Ends a sign-in that failed with `error` and returns what the connect throws. Once the reader has started, the
    /// session's modules have too, so it ends the way any session does.
    private func endFailedSignIn(_ error: any Error, readerStarted: Bool) async -> any Error {
        log.error("Handshake failed: \(error)")
        if disconnectInFlight {
            await disconnect()
            return error
        }
        if readerStarted {
            if Task.isCancelled || error is CancellationError {
                await cleanUp(reason: .requested)
                return CancellationError()
            }
            await cleanUp(reason: .setupFailed(error))
            return XMPPClientError.sessionSetupFailed(error)
        }
        serverStreamLock.withLock { $0 = (nil, nil) }
        state = .disconnected
        // Release any waiter so it does not hang on a client whose sign-in failed.
        settleInitialPresenceReadiness(open: true)
        settleSessionReadiness(.closed)
        await connection.disconnect()
        return signInDeadlineFired ? XMPPClientError.timeout : error
    }

    /// Module lifecycle after handshake. Resume: `handleResume()` in dict order. Fresh: SM `<enable>` → `.connected`
    /// → roster → non-PEP modules → caps-bearing initial presence → PEP publisher, per RFC 6121 / XEP-0163 ordering
    /// invariants.
    private func runPostHandshakeModules(resumed: Bool) async throws {
        try checkActiveSession()
        if resumed {
            for module in modules.values {
                try await module.handleResume()
                try checkActiveSession()
            }
            // Resume does not re-send presence, so the gate is already satisfied for the resumed
            // session; resolve it so any PEP-reacting service awaiting it proceeds.
            settleInitialPresenceReadiness(open: true)
            return
        }

        // RFC 6121: Roster must be fetched before initial presence is sent.
        let rosterKey = ObjectIdentifier(RosterModule.self)
        let presenceKey = ObjectIdentifier(PresenceModule.self)
        let smKey = ObjectIdentifier(StreamManagementModule.self)
        // OMEMOModule is the only connect-time PEP *publisher* (device-list + bundle); it is sequenced after
        // presence below. Every other module runs before presence, so non-PEP startup work, such as CarbonsModule
        // enabling carbons on the SASL1 fallback path, completes before the resource is advertised as available.
        let omemoKey = ObjectIdentifier(OMEMOModule.self)

        // Drive SM `<enable>` before any other handleConnect so the race
        // where Dictionary iteration ran a stanza-sending module (carbons
        // enable, OMEMO publish, etc.) after the server's `<enabled>` but
        // before the client interceptor saw `enabled=true` is closed. The
        // Bind 2 inline path sets `enabled` synchronously and is unaffected;
        // SM no-ops if already inline-enabled or unsupported.
        if let smModule = modules[smKey] {
            try await smModule.handleConnect()
            try checkActiveSession()
        }
        // Yield `.connected` after SM `<enabled>` round-trip but BEFORE roster. `.connected` → initial roster response is
        // contractual: BookmarksService PEP fetch and TestHarness.setUp gate on it; reversing surfaces `.notConnected`
        // in `connectedClient(for:)` callers.
        if let fullJID = connectedJIDLock.withLock({ $0 }) {
            eventContinuation.yield(.connected(fullJID))
        }
        if let rosterModule = modules[rosterKey] {
            try await rosterModule.handleConnect()
            try checkActiveSession()
        }
        // Non-PEP modules run before presence.
        for (key, module) in modules
            where key != rosterKey && key != presenceKey && key != smKey && key != omemoKey {
            try await module.handleConnect()
            try checkActiveSession()
        }
        // XEP-0163 §3.3.2: the server gates PEP `+notify` delivery on having seen this resource's entity caps
        // via initial presence, so the initial presence, which carries the caps, must reach the server BEFORE
        // any PEP publisher (the `OMEMOModule` device-list/bundle publish below, and the PEP-reacting DuckoCore
        // services that await the readiness signal).
        if let presenceModule = modules[presenceKey] {
            try await presenceModule.handleConnect()
            try checkActiveSession()
        }
        // Caps is on the wire — release the gated PEP-reacting services, then run the PEP publisher module.
        settleInitialPresenceReadiness(open: true)
        if let omemoModule = modules[omemoKey] {
            try await omemoModule.handleConnect()
            try checkActiveSession()
        }
    }

    private func checkActiveSession() throws {
        try Task.checkCancellation()
        guard !disconnectInFlight, case .connected = state else {
            throw XMPPClientError.notConnected
        }
    }

    /// Drives the full XMPP handshake consuming events via the reader.
    /// Returns `true` if the session was resumed (skip `handleConnect` on modules).
    private func performHandshake(reader: EventReader) async throws -> Bool {
        // 1. Open initial stream
        try await openStream()
        let features1 = try await reader.awaitFeatures()

        // 2. TLS — skip STARTTLS if direct TLS is already active
        let (postTLSFeatures, isTLSActive) = try await negotiateTLSIfNeeded(features1, reader: reader)

        // 3. Prefer SASL2 + Bind 2 when both available, and only over TLS (XEP-0388 §3)
        if isTLSActive, let sasl2Features = SASL2Authenticator.parseFeatures(postTLSFeatures),
           sasl2Features.supportsBind2 {
            return try await performSASL2Flow(postTLSFeatures, sasl2Features: sasl2Features, reader: reader)
        }

        // 4. Fallback: SASL1 + sequential bind
        return try await performSASL1Flow(postTLSFeatures, reader: reader)
    }

    /// Handles TLS negotiation (STARTTLS or direct TLS). Returns post-TLS features and whether TLS is active.
    private func negotiateTLSIfNeeded(_ features: XMLElement, reader: EventReader) async throws -> (XMLElement, Bool) {
        if await connection.isDirectTLS {
            log.info("Direct TLS active")
            let info = await connection.tlsInfo
            tlsInfoLock.withLock { $0 = info }
            return (features, true)
        } else if features.child(named: "starttls", namespace: XMPPNamespaces.tls) != nil || requireTLS {
            let isForced = features.child(named: "starttls", namespace: XMPPNamespaces.tls) == nil
            if isForced {
                // RFC 7590 §3.1: STARTTLS not advertised — a MITM may have stripped it.
                // Attempt STARTTLS anyway; a refusal fails as `tlsRequired`.
                log.warning("STARTTLS not advertised — forcing attempt per RFC 7590 §3.1")
            }
            state = .negotiatingTLS
            do {
                try await requestTLS(reader: reader)
            } catch {
                if isForced {
                    log.error("Forced STARTTLS rejected: \(error)")
                    throw XMPPClientError.tlsRequired
                }
                throw error
            }
            // Outside the catch: a failed upgrade is not a refusal, so forced STARTTLS must not report it as `tlsRequired`.
            guard let serverName else { throw XMPPClientError.invalidDomain(domain) }
            try await connection.upgradeTLS(serverName: serverName)
            if isForced {
                log.info("TLS established via forced STARTTLS (anti-stripping)")
            } else {
                log.info("TLS established via STARTTLS")
            }
            let info = await connection.tlsInfo
            tlsInfoLock.withLock { $0 = info }
            try await openStream()
            return try await (reader.awaitFeatures(), true)
        } else {
            return (features, false)
        }
    }

    // MARK: - Private: SASL2 + Bind 2

    /// Performs the SASL2 + Bind 2 authentication and binding flow.
    private func performSASL2Flow(
        _ features: XMLElement,
        sasl2Features: SASL2Features,
        reader: EventReader
    ) async throws -> Bool {
        state = .authenticating

        let sm = modules[ObjectIdentifier(StreamManagementModule.self)] as? StreamManagementModule
        let resumeElement: XMLElement? = if let sm, sm.isResumable, sasl2Features.supportsSM {
            sm.buildResumeElement()
        } else {
            nil
        }
        let requestsSM = sm != nil && sasl2Features.bind2InlineFeatures.contains(XMPPNamespaces.sm)
        let requestsCarbons = modules[ObjectIdentifier(CarbonsModule.self)] != nil
            && sasl2Features.bind2InlineFeatures.contains(XMPPNamespaces.carbons)
        let authResult = try await authenticateSASL2(
            features: features, resumeElement: resumeElement, requestsSM: requestsSM, requestsCarbons: requestsCarbons,
            reader: reader
        )
        log.info("Authenticated via SASL2")

        let fullJID: FullJID
        let bound: XMLElement?
        switch authResult {
        case let .resumed(resumed):
            return try await completeInlineResume(resumed, sm: sm)
        case let .session(jid, boundElement):
            fullJID = jid
            bound = boundElement
        }
        // The resume failed or went unanswered, so the session `<bound/>` started takes over.
        if resumeElement != nil {
            log.info("Stream resumption failed, continuing with a new session")
            sm?.resetResumption()
        }
        try await awaitSASL2PostAuthFeatures(reader: reader)

        connectedJIDLock.withLock { $0 = fullJID }
        processBind2Results(bound: bound, requestsSM: requestsSM, requestsCarbons: requestsCarbons)

        log.notice("Connected via SASL2 + Bind 2")
        log.debug("The connected JID is \(fullJID)")
        state = .connected(fullJID)
        return false
    }

    /// Continues the session an inline `<resume/>` brought back. The server sends no stream features after it
    /// (XEP-0198 §9.2), so the features that session got after sign-in are restored. A server that sends them anyway
    /// (Prosody does, after the replayed stanzas) has them dropped by the dispatch loop, which ignores top-level
    /// elements it doesn't know.
    private func completeInlineResume(_ resumed: XMLElement, sm: StreamManagementModule?) async throws -> Bool {
        guard let sm, case let .resumed(jid, retransmitQueue) = sm.processResumeResponse(resumed) else {
            throw authenticationFailure(.invalidState("Resumed a session that was not requested"))
        }
        let sessionFeatures = sm.sessionFeatures
        serverStreamLock.withLock { $0.features = sessionFeatures }
        try await adoptResumedStream(jid: jid, retransmitQueue: retransmitQueue)
        return true
    }

    /// Resends what the server had not acknowledged before the drop and carries the stream on as `jid`.
    private func adoptResumedStream(jid: FullJID, retransmitQueue: [XMLElement]) async throws {
        for stanza in retransmitQueue {
            try await connection.send(XMPPStreamWriter.stanza(stanza))
        }
        log.notice("Stream resumed")
        log.debug("The resumed stream's JID is \(jid)")
        connectedJIDLock.withLock { $0 = jid }
        state = .connected(jid)
    }

    /// XEP-0388 §2.6.1: SASL2 has no stream restart. `<success>` is immediately followed by the
    /// authenticated stream's `<features>` on the same stream, with no new stream header.
    private func awaitSASL2PostAuthFeatures(reader: EventReader) async throws {
        let postAuthFeatures = try await reader.awaitFeaturesElement()
        serverStreamLock.withLock { $0.features = postAuthFeatures }
    }

    /// Performs the legacy SASL1 + sequential bind flow.
    private func performSASL1Flow(_ features: XMLElement, reader: EventReader) async throws -> Bool {
        state = .authenticating
        try await authenticate(features: features, reader: reader)
        log.info("Authenticated")

        // Post-auth stream (reset parser for new XML document)
        await connection.resetStream()
        try await openStream()
        let features3 = try await reader.awaitFeatures()
        serverStreamLock.withLock { $0.features = features3 }

        // Attempt SM resume (before bind)
        if try await attemptSMResume(features: features3, reader: reader) {
            return true
        }

        // Resource binding
        state = .bindingResource
        let fullJID = try await bindResource(reader: reader)

        // Session establishment (if required)
        if let session = features3.child(named: "session", namespace: XMPPNamespaces.session),
           session.child(named: "optional") == nil {
            try await establishSession(reader: reader)
        }

        log.notice("Connected")
        log.debug("The connected JID is \(fullJID)")
        connectedJIDLock.withLock { $0 = fullJID }
        state = .connected(fullJID)
        return false
    }

    // MARK: - Disconnect

    public func disconnect(streamCloseTimeout: Duration = .milliseconds(500), syncAckTimeout: Duration = .seconds(1.5)) async {
        // Reentrancy guard: module `handleDisconnect` can re-call `disconnect()`, and `cleanUp` also runs from
        // stream-error, redirect, and connection-lost paths. Check-and-set is actor-atomic before any await. A one-way
        // flag is fine because XMPPClient is terminal after a disconnect or cleanUp. A caller outside the teardown still
        // waits for a disconnect or teardown another path already started.
        guard !disconnectInFlight else {
            if !Self.isTearingDown {
                await disconnectTask?.value
                await cleanUpTask?.value
            }
            return
        }
        disconnectInFlight = true
        let shutdown = Task { await shutDown(streamCloseTimeout: streamCloseTimeout, syncAckTimeout: syncAckTimeout) }
        disconnectTask = shutdown
        await shutdown.value
    }

    private func shutDown(streamCloseTimeout: Duration, syncAckTimeout: Duration) async {
        // Send unavailable presence through `send` so the SM interceptor counts
        // it. Going through `connection.send` directly leaves SM's outgoing
        // counter one short of the server's, producing a phantom "Invalid ack"
        // warning on the next ack and corrupting any subsequent resume.
        if case .connected = state {
            try? await send(XMPPPresence(type: .unavailable))
            // XEP-0198 sync ack: confirm server processed all sent stanzas (incl. the unavailable presence) before
            // closing the stream. Without this, prosody mod_smacks holds the session in resumption-pending state for
            // hundreds of seconds. The 1.5s default fits under `AppDelegate.disconnectDeadline`.
            if let smModule = modules[ObjectIdentifier(StreamManagementModule.self)] as? StreamManagementModule,
               smModule.isEnabled {
                try? await smModule.requestSyncAck(timeout: syncAckTimeout)
            }
        }

        // Send `</stream:stream>` and wait for the server's matching close (RFC 6120 §4.4) instead of a fixed
        // sleep — usually faster, and bounded by `streamCloseTimeout`. Guard on `readerTask`, not `state`: a
        // concurrent `cleanUp` (e.g. server closed during the sync-ack window) nils `readerTask` *before* setting
        // `state = .disconnected`, so a `state` check could register a waiter with no reader left to deliver
        // `.streamClosed` and re-send the close into a torn-down stream.
        if readerTask != nil {
            let serverReplied = await awaitStreamClose(timeout: streamCloseTimeout)
            if !serverReplied {
                log.debug("Stream close timed out waiting for server reply; tearing down anyway")
            }
        }
        await cleanUp(reason: .requested)
        // cleanUp does nothing for a client that is already disconnected. Closing the connection anyway finishes its
        // event stream, so a later connect on this client fails instead of opening a session.
        await connection.disconnect()
    }

    /// Sends `</stream:stream>` and waits for the server's matching close, resolving the instant the
    /// `.streamClosed` event arrives (see `handleEvent`) or `timeout` elapses. Best-effort and non-throwing:
    /// returns `true` if the server replied, `false` on timeout. The waiter slot is registered *before* the close
    /// is sent so a reply can never arrive before the slot exists; the send is then awaited so a short timeout can
    /// never let the caller tear down the transport before the close write reaches it. A close the transport refuses
    /// has no reply to wait for, so a failed write ends the wait at once.
    private func awaitStreamClose(timeout: Duration) async -> Bool {
        var sendTask: Task<Void, Never>?
        let serverReplied = await withCheckedContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                await self?.expireStreamClose()
            }

            pendingStreamClose = PendingStreamClose(continuation: continuation, timeoutTask: timeoutTask)

            sendTask = Task { [weak self, connection] in
                let sent = await connection.sendStreamClose()
                if !sent {
                    await self?.expireStreamClose()
                }
            }
        }
        await sendTask?.value
        return serverReplied
    }

    private func expireStreamClose() {
        if let pending = pendingStreamClose {
            pendingStreamClose = nil
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: false)
        }
    }

    // MARK: - Sending

    /// Whether the client takes stanzas: it is connected and its teardown has not begun. A teardown that has begun
    /// stops stream management from queuing while `state` is still `.connected`, so a stanza taken from then on would
    /// be neither delivered nor re-sent on a resume. A requested disconnect still takes stanzas until its teardown
    /// starts, which is where this differs from `checkActiveSession`.
    public var acceptsStanzas: Bool {
        guard cleanUpTask == nil, case .connected = state else { return false }
        return true
    }

    /// `onAccepted` runs once the stanza is taken for this session, before the write. See `ModuleContext.sendStanza`.
    /// A `<message>` waits until the session's setup has completed, so it never goes out on a session that ends before
    /// it is set up.
    public func send(_ stanza: any XMPPStanza, onAccepted: ModuleContext.StanzaAcceptanceHandler? = nil) async throws {
        if stanza.element.name == "message" {
            try await awaitSessionReady()
        }
        guard acceptsStanzas else {
            throw XMPPClientError.notConnected
        }
        for interceptor in interceptors {
            interceptor.processOutgoing(stanza.element)
        }
        onAccepted?()
        try await connection.send(XMPPStreamWriter.stanza(stanza.element))
    }

    /// Sends an IQ and awaits the matching result. Returns the result's child element or `nil`.
    /// Cancellation stops waiting for the reply, though an accepted write may still complete.
    /// `onTerminal` runs exactly once with the request's outcome, before the caller resumes. For an accepted reply it
    /// also runs before the next inbound stanza is dispatched.
    public func sendIQ(
        _ request: XMPPIQ, timeout: Duration = .seconds(30),
        onTerminal: ModuleContext.IQTerminalHandler? = nil
    ) async throws -> XMLElement? {
        guard case .connected = state else {
            onTerminal?(.failure(XMPPClientError.notConnected))
            throw XMPPClientError.notConnected
        }
        var iq = request
        let stanzaID = iq.id ?? generateID()
        iq.id = stanzaID
        guard pendingIQs[stanzaID] == nil else {
            let error = XMPPClientError.unexpectedStreamState("A request with this identifier is already pending")
            onTerminal?(.failure(error))
            throw error
        }
        pendingIQToken &+= 1
        let token = pendingIQToken
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    onTerminal?(.failure(CancellationError()))
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.resolvePendingIQ(id: stanzaID, token: token, result: .failure(XMPPClientError.timeout))
                }
                pendingIQs[stanzaID] = PendingIQ(
                    continuation: continuation, requestTo: iq.to, token: token,
                    onTerminal: onTerminal, timeoutTask: timeoutTask
                )
                pendingIQs[stanzaID]?.sendTask = Task {
                    do {
                        try Task.checkCancellation()
                        try await send(iq)
                    } catch {
                        resolvePendingIQ(id: stanzaID, token: token, result: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { await self.resolvePendingIQ(id: stanzaID, token: token, result: .failure(CancellationError())) }
        }
    }

    private func resolvePendingIQ(id: String, token: UInt64, result: Result<XMPPIQ, any Error>, cancelSend: Bool = true) {
        guard let pending = pendingIQs[id], pending.token == token else { return }
        pendingIQs.removeValue(forKey: id)
        pending.timeoutTask.cancel()
        if cancelSend { pending.sendTask?.cancel() }
        pending.onTerminal?(result)
        pending.continuation.resume(with: result.map(\.childElement))
    }

    // MARK: - Private: Stream Negotiation

    private func openStream() async throws {
        let bareJID = "\(credentials.username)@\(domain)"
        try await connection.send(XMPPStreamWriter.streamOpening(to: domain, from: bareJID))
    }

    private func requestTLS(reader: EventReader) async throws {
        let starttls = XMLElement(name: "starttls", namespace: XMPPNamespaces.tls)
        try await connection.send(XMPPStreamWriter.stanza(starttls))

        let element = try await reader.awaitStanza()
        guard XMPPConnection.isTLSProceed(element) else {
            throw XMPPClientError.tlsNegotiationFailed("The server refused to start TLS")
        }
    }

    /// Attempts to resume a previous SM session. Returns `true` if resumed.
    private func attemptSMResume(features: XMLElement, reader: EventReader) async throws -> Bool {
        guard let sm = modules[ObjectIdentifier(StreamManagementModule.self)] as? StreamManagementModule,
              sm.isResumable,
              features.child(named: "sm", namespace: XMPPNamespaces.sm) != nil else {
            return false
        }

        let resumeElement = sm.buildResumeElement()
        try await connection.send(XMPPStreamWriter.stanza(resumeElement))
        let response = try await reader.awaitStanza()
        let result = sm.processResumeResponse(response)

        switch result {
        case let .resumed(jid, retransmitQueue):
            try await adoptResumedStream(jid: jid, retransmitQueue: retransmitQueue)
            return true
        case .failed:
            log.info("Stream resumption failed, continuing with a new session")
            return false
        }
    }

    // MARK: - Private: Authentication

    private func authenticate(features: XMLElement, reader: EventReader) async throws {
        var authenticator = SASLAuthenticator()
        let cbData = await connection.channelBindingData
        let authElement: XMLElement
        do {
            authElement = try authenticator.begin(
                features: features, authcid: credentials.username, password: credentials.password,
                channelBindingData: cbData, requiresSCRAM: requiresSCRAM
            )
        } catch {
            throw authenticationFailure(error)
        }

        try await connection.send(XMPPStreamWriter.stanza(authElement))

        // Drive the SASL exchange
        while true {
            let element = try await reader.awaitStanza()

            let response = authenticator.receive(element)
            recordVerifiedSCRAMMechanism(authenticator.verifiedSCRAMMechanism)
            switch response {
            case let .continueWith(reply):
                try await connection.send(XMPPStreamWriter.stanza(reply))
            case .success:
                return
            case let .failure(error):
                throw authenticationFailure(error)
            }
        }
    }

    // MARK: - Private: SASL2 Authentication

    /// The Bind 2 tag is the client's software name rather than the account's resource, which can be a host name that
    /// XEP-0386 §4 keeps out of the tag. The resource still goes to RFC 6120 binding on servers without Bind 2.
    private func authenticateSASL2(
        features: XMLElement,
        resumeElement: XMLElement?,
        requestsSM: Bool,
        requestsCarbons: Bool,
        reader: EventReader
    ) async throws -> SASL2Authenticator.AuthResult {
        var authenticator = SASL2Authenticator()
        var inlinePayloads: [XMLElement] = []
        if let resumeElement {
            inlinePayloads.append(resumeElement)
        }
        inlinePayloads.append(buildBind2Request(tag: userAgent.software, enableSM: requestsSM, enableCarbons: requestsCarbons))

        let cbData = await connection.channelBindingData
        let authElement: XMLElement
        do {
            authElement = try authenticator.begin(
                features: features,
                authcid: credentials.username,
                password: credentials.password,
                inlinePayloads: inlinePayloads,
                userAgent: userAgent,
                channelBindingData: cbData,
                requiresSCRAM: requiresSCRAM
            )
        } catch {
            throw authenticationFailure(error)
        }

        try await connection.send(XMPPStreamWriter.stanza(authElement))

        // Drive the SASL2 exchange
        while true {
            let element = try await reader.awaitStanza()

            let response = authenticator.receive(element)
            recordVerifiedSCRAMMechanism(authenticator.verifiedSCRAMMechanism)
            switch response {
            case let .continueWith(reply):
                try await connection.send(XMPPStreamWriter.stanza(reply))
            case let .success(result):
                return result
            case .failure(.unsupportedSignInStep):
                // XEP-0388 §2.4: only `<response/>` or `<abort/>` may answer mid-exchange.
                try await connection.send(XMPPStreamWriter.stanza(XMLElement(name: "abort", namespace: XMPPNamespaces.sasl2)))
                throw authenticationFailure(.unsupportedSignInStep)
            case let .failure(error):
                throw authenticationFailure(error)
            }
        }
    }

    private func authenticationFailure(_ error: SASLAuthError) -> XMPPClientError {
        if error == .plainRefused {
            eventContinuation.yield(.plainSignInRefused)
            return .plainSignInRefused
        }
        let failure = AuthenticationFailure(error)
        eventContinuation.yield(.authenticationFailed(failure))
        return .authenticationFailed(failure)
    }

    /// Processes inline feature results from Bind 2 (SM enabled, carbons, etc.).
    private func processBind2Results(bound: XMLElement?, requestsSM: Bool, requestsCarbons: Bool) {
        if let sm = modules[ObjectIdentifier(StreamManagementModule.self)] as? StreamManagementModule {
            // Only an `<enabled>` inside `<bound>` starts the session. An inline enable counts as the stream's one
            // attempt even when it failed or went unanswered.
            if requestsSM {
                sm.markInlineEnableSent()
            }
            if let smEnabled = bound?.child(named: "enabled", namespace: XMPPNamespaces.sm) {
                sm.processInlineEnabled(smEnabled)
            }
        }

        // The server sends no answer to an inline carbons request, so sending it enables them.
        if requestsCarbons,
           let carbons = modules[ObjectIdentifier(CarbonsModule.self)] as? CarbonsModule {
            carbons.markInlineEnabled()
        }
    }

    // MARK: - Private: Resource Binding

    private func bindResource(reader: EventReader) async throws -> FullJID {
        var bindIQ = XMPPIQ(type: .set, id: generateID())
        var bindChild = XMLElement(name: "bind", namespace: XMPPNamespaces.bind)
        if let resource = preferredResource, !resource.isEmpty {
            // Normalize through OpaqueString so the requested resource matches what the now-stricter
            // FullJID.parse accepts when the server echoes the bound JID; on failure, let the server assign.
            if let normalized = FullJID.normalizeResourcePart(resource) {
                var resourceElement = XMLElement(name: "resource")
                resourceElement.addText(normalized)
                bindChild.addChild(resourceElement)
            } else {
                log.warning("preferredResource failed OpaqueString normalization; letting server assign")
            }
        }
        bindIQ.element.addChild(bindChild)

        try await connection.send(XMPPStreamWriter.stanza(bindIQ.element))

        let element = try await reader.awaitStanza()

        let resultIQ = XMPPIQ(element: element)
        guard resultIQ.isResult else {
            throw XMPPClientError.bindingFailed("Bind IQ returned type=\(resultIQ.type ?? "nil")")
        }

        guard let bind = resultIQ.childElement,
              let jidString = bind.childText(named: "jid"),
              let fullJID = FullJID.parse(jidString) else {
            throw XMPPClientError.bindingFailed("No JID in bind result")
        }

        return fullJID
    }

    // MARK: - Private: Session

    private func establishSession(reader: EventReader) async throws {
        var sessionIQ = XMPPIQ(type: .set, id: generateID())
        let sessionChild = XMLElement(name: "session", namespace: XMPPNamespaces.session)
        sessionIQ.element.addChild(sessionChild)

        try await connection.send(XMPPStreamWriter.stanza(sessionIQ.element))

        let element = try await reader.awaitStanza()

        let resultIQ = XMPPIQ(element: element)
        guard resultIQ.isResult else {
            throw XMPPClientError.sessionFailed("Session IQ returned type=\(resultIQ.type ?? "nil")")
        }
    }

    // MARK: - Private: Dispatch Loop

    private func startReader(reader: EventReader) {
        readerTask = Task { [weak self] in
            while let event = await reader.next() {
                guard let self else { return }
                await handleEvent(event)
            }
            await self?.handleStreamEnd()
        }
    }

    private func handleEvent(_ event: XMLStreamEvent) async {
        switch event {
        case .streamOpened:
            break
        case let .stanzaReceived(element):
            dispatchStanza(element)
        case .streamClosed:
            if let pending = pendingStreamClose {
                // A `disconnect()` is awaiting this reply. Resolve it and let that path own teardown so `cleanUp`
                // stays single-sourced during a requested disconnect.
                pendingStreamClose = nil
                pending.timeoutTask.cancel()
                pending.continuation.resume(returning: true)
            } else {
                await cleanUp(reason: mapDisconnectReason(.streamError(nil, text: nil)))
            }
        case let .error(error):
            await cleanUp(reason: mapDisconnectReason(.connectionLost(error.message)))
        }
    }

    /// During a user-initiated `disconnect()`, concurrent stream-end / stream-error / connection-lost events must
    /// be remapped to `.requested` — otherwise `AccountService.handleDisconnect` interprets the race-emitted error
    /// as a failure and schedules a reconnect for a session the user asked to close.
    private func mapDisconnectReason(_ reason: DisconnectReason) -> DisconnectReason {
        disconnectInFlight ? .requested : reason
    }

    private func dispatchStanza(_ element: XMLElement) {
        // Stream errors arrive at depth 1 as <error> within the stream namespace.
        if element.name == "error" {
            let condition = XMPPStreamError.parse(from: element)

            // Handle see-other-host redirect (RFC 6120 §4.9.3.19)
            if condition == .seeOtherHost, let (host, port) = Self.parseSeeOtherHost(from: element) {
                Task { [weak self] in
                    guard let self else { return }
                    await cleanUp(reason: mapDisconnectReason(.redirect(host: host, port: port)))
                }
                return
            }

            let text = element.children.compactMap({ node -> String? in
                guard case let .element(child) = node,
                      child.name == "text",
                      child.namespace == XMPPNamespaces.streams else { return nil }
                return child.textContent
            }).first
            Task { [weak self] in
                guard let self else { return }
                await cleanUp(reason: mapDisconnectReason(.streamError(condition, text: text)))
            }
            return
        }

        // Run incoming interceptors first; if any consumes the stanza, stop.
        guard !interceptors.contains(where: { $0.processIncoming(element) }) else { return }

        switch element.name {
        case "message":
            dispatchMessage(element)
        case "presence":
            dispatchPresence(element)
        case "iq":
            dispatchIQ(element)
        default:
            break
        }
    }

    private func dispatchMessage(_ element: XMLElement) {
        let message = XMPPMessage(element: element)
        eventContinuation.yield(.messageReceived(message))
        for module in modules.values {
            try? module.handleMessage(message)
        }
    }

    private func dispatchPresence(_ element: XMLElement) {
        let presence = XMPPPresence(element: element)
        eventContinuation.yield(.presenceReceived(presence))
        for module in modules.values {
            try? module.handlePresence(presence)
        }
    }

    private func dispatchIQ(_ element: XMLElement) {
        let iq = XMPPIQ(element: element)
        if let stanzaID = iq.id, let pending = pendingIQs[stanzaID] {
            if IQReplyPolicy.accepts(reply: iq, requestTo: pending.requestTo, ownJID: connectedJIDLock.withLock { $0 }) {
                let result: Result<XMPPIQ, any Error>
                if iq.isError {
                    let error = XMPPStanzaError.parse(from: iq.element.child(named: "error"))
                        ?? XMPPStanzaError(errorType: .cancel, condition: .undefinedCondition)
                    result = .failure(error)
                } else {
                    result = .success(iq)
                }
                // A reply can precede the send task's completion, so let that task finish normally.
                resolvePendingIQ(id: stanzaID, token: pending.token, result: result, cancelSend: false)
                return
            }
            // A same-ID get/set is a request (e.g. our own disco query reflected to this resource), not a rejected reply.
            if iq.isResult || iq.isError {
                let type = iq.type ?? "absent"
                let from = iq.element.attribute("from") ?? "absent"
                let requestTo = pending.requestTo?.description ?? "absent"
                log.debug("Ignoring IQ \(stanzaID) as a reply: type \(type) from \(from) for a request to \(requestTo)")
            }
        }
        eventContinuation.yield(.iqReceived(iq))
        let handled = modules.values.contains { (try? $0.handleIQ(iq)) == true }
        // RFC 6120 §8.2.3: Reply service-unavailable for unhandled get/set IQs
        if !handled, iq.isGet || iq.isSet {
            replyServiceUnavailable(for: iq)
        }
    }

    private func replyServiceUnavailable(for iq: XMPPIQ) {
        guard let errorIQ = XMPPIQ.errorReply(for: iq, type: .cancel, condition: .serviceUnavailable) else { return }
        Task {
            try? await self.send(errorIQ)
        }
    }

    private func handleStreamEnd() async {
        guard case .connected = state else { return }
        await cleanUp(reason: mapDisconnectReason(.connectionLost("Stream ended")))
    }

    // MARK: - Private: Cleanup

    private func cleanUp(reason: DisconnectReason) async {
        if case .disconnected = state { return }
        // `state` isn't `.disconnected` until the teardown finishes, and cancelling the reader sends its loop into
        // `handleStreamEnd`. A later caller therefore waits for the running teardown instead of repeating it.
        if let cleanUpTask {
            await cleanUpTask.value
            return
        }
        // Same reentrancy guard as disconnect() — cleanUp also runs from stream-error/redirect/connection-lost paths.
        disconnectInFlight = true
        readerTask?.cancel()
        readerTask = nil

        let teardown = Task { await tearDown(reason: reason) }
        cleanUpTask = teardown
        await teardown.value
    }

    private func tearDown(reason: DisconnectReason) async {
        await Self.$isTearingDown.withValue(true) {
            for module in modules.values {
                await module.handleDisconnect()
            }
        }
        await connection.disconnect()

        state = .disconnected
        connectedJIDLock.withLock { $0 = nil }
        serverStreamLock.withLock { $0 = (nil, nil) }
        tlsInfoLock.withLock { $0 = nil }

        for (id, pending) in pendingIQs {
            resolvePendingIQ(id: id, token: pending.token, result: .failure(XMPPClientError.notConnected))
        }
        if let pending = pendingStreamClose {
            pending.timeoutTask.cancel()
            pendingStreamClose = nil
            pending.continuation.resume(returning: false)
        }
        // Resolve any service still awaiting the readiness signals so it doesn't hang on this dead client.
        settleInitialPresenceReadiness(open: true)
        settleSessionReadiness(.closed)

        eventContinuation.yield(.disconnected(reason))
        // Terminal: callers drop instance and rebuild on reconnect. `finish()` releases any pending for-await consumers.
        eventContinuation.finish()
    }

    // MARK: - Private: Module Context

    private func makeModuleContext() -> ModuleContext {
        ModuleContext(
            sendStanza: { [weak self] stanza, onAccepted in
                guard let self else { throw XMPPClientError.notConnected }
                try await send(stanza, onAccepted: onAccepted)
            },
            sendIQ: { [weak self] iq, terminal in
                guard let self else {
                    terminal?(.failure(XMPPClientError.notConnected))
                    throw XMPPClientError.notConnected
                }
                return try await sendIQ(iq, onTerminal: terminal)
            },
            emitEvent: { [eventContinuation] event in
                eventContinuation.yield(event)
            },
            generateID: {
                Self.makeStanzaID()
            },
            connectedJID: { [connectedJIDLock] in
                connectedJIDLock.withLock { $0 }
            },
            domain: domain,
            // The registry is reached through a weak client, since it holds the modules that hold this context.
            availableFeatures: { [weak self] in
                Set(self?.registeredModulesLock.withLock { $0 }.flatMap(\.features) ?? [])
            },
            sendElement: { [weak self] element in
                try await self?.connection.send(XMPPStreamWriter.stanza(element))
            },
            serverStreamFeatures: { [serverStreamLock] in
                serverStreamLock.withLock { $0.features }
            },
            serverStreamLang: { [serverStreamLock] in
                serverStreamLock.withLock { $0.lang }
            },
            dispatchDecryptedMessage: { [weak self] message in
                self?.registeredModulesLock.withLock { $0 }.forEach { $0.handleDecryptedMessage(message) }
            },
            reportConnectionLost: { [weak self] detail in
                Task { [weak self] in
                    guard let self else { return }
                    await cleanUp(reason: mapDisconnectReason(.connectionLost(detail)))
                }
            }
        )
    }
}
