// Split candidate.
// swiftlint:disable file_length
import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.jingle")

/// How long a Jingle transfer waits for each end it cannot force.
public struct JingleTiming: Sendable {
    /// How long a receive that holds every byte, or whose peer ended it, waits for the stream to end.
    public let endOfStreamWait: Duration
    /// How long a finished receive waits for a checksum the offer promised.
    public let checksumWait: Duration
    /// How long received data or a peer's end waits for this side to claim the receive.
    public let unclaimedReceiveExpiry: Duration
    /// How long a finished send waits for the receiver to confirm it.
    public let senderConfirmationWait: Duration
    /// How long a dial to a nominated proxy may take before it counts as a proxy error. Shorter than the socket's own
    /// default, because a proxy is optional: waiting on an unreachable one only delays the IBB fallback that follows.
    public let proxyConnectWait: Duration
    /// How long a send the peer accepted waits for a transport to become ready before it gives up.
    public let transportReadyWait: Duration
    /// How long a SOCKS5 send waits for the peer to take more bytes before it gives up.
    public let sendStallWait: Duration
    /// How long a SOCKS5 receive waits for the peer to send more bytes before it gives up.
    public let receiveStallWait: Duration

    public init(
        endOfStreamWait: Duration = .seconds(15),
        checksumWait: Duration = .seconds(10),
        unclaimedReceiveExpiry: Duration = .seconds(60),
        senderConfirmationWait: Duration = .seconds(30),
        proxyConnectWait: Duration = .seconds(2),
        transportReadyWait: Duration = .seconds(120),
        sendStallWait: Duration = .seconds(30),
        receiveStallWait: Duration = .seconds(30)
    ) {
        self.endOfStreamWait = endOfStreamWait
        self.checksumWait = checksumWait
        self.unclaimedReceiveExpiry = unclaimedReceiveExpiry
        self.senderConfirmationWait = senderConfirmationWait
        self.proxyConnectWait = proxyConnectWait
        self.transportReadyWait = transportReadyWait
        self.sendStallWait = sendStallWait
        self.receiveStallWait = receiveStallWait
    }
}

/// Implements XEP-0166 Jingle and XEP-0234 Jingle File Transfer —
/// handles session negotiation for peer-to-peer file transfers.
///
/// Also handles XEP-0260 SOCKS5 transport negotiation: discovers Proxy65
/// services, builds transport candidates, and orchestrates SOCKS5 connections.
///
/// Removing a session under the state lock is a session's terminal commit, and only the path that removes it reports the
/// outcome. A successful end is committed by the task that owns the transfer (the receive's claim or a running send); peer
/// stanzas and wait limits only record it and wake that owner.
public final class JingleModule: XMPPModule, Sendable { // swiftlint:disable:this type_body_length
    // MARK: - Types

    /// Errors from the Jingle module.
    public enum JingleError: Error, Equatable {
        case notConnected
        case sessionNotFound
        case noConnectedJID
        case alreadyAccepted
        case transportNegotiationFailed(String)
        case transportFailed(String)
    }

    enum ChecksumResult: Equatable {
        case verified
        case mismatch(expected: String, computed: String)
        case unsupportedAlgorithm(String)
    }

    private struct ProxyInfo {
        let jid: String
        let host: String
        let port: UInt16
    }

    /// A proxy bytestream this side has connected to but which carries nothing until the offering party activates it
    /// (XEP-0260 §2.4). Kept separate from the session's active connection so neither a transport wait nor a claim can take it early.
    private struct PendingProxy {
        let connection: SOCKS5Connection
        let cid: String
    }

    private struct DisconnectSnapshot {
        let sids: [String]
        let context: ModuleContext?
        let resources: [SessionResources]
    }

    private struct TerminateSnapshot {
        let session: JingleSession
        let resources: SessionResources
    }

    /// How the peer ended a receive without failing it.
    private enum PeerEnd {
        case ibbClosed
        case terminatedSuccess
    }

    /// The receiving side of a session. The transfer contract is copied in when the session is created.
    private struct ReceiveState {
        let expectedSize: Int64
        let offeredChecksum: JingleChecksumInfo?
        let checksumPromised: Bool
        var sessionInfoChecksum: JingleChecksumInfo?
        var peerEnd: PeerEnd?
        var isClaimed = false
        /// Wakes a claimed IBB receive once the stream ended or its end-of-stream wait elapsed.
        var wake: CheckedContinuation<Void, Error>?
        var checksumWait: CheckedContinuation<Void, Error>?
        var expiryTask: Task<Void, Never>?
        var endOfStreamTask: Task<Void, Never>?

        init(content: JingleContent) {
            let description = content.description
            self.expectedSize = description.size
            self.offeredChecksum = description.hash.map {
                JingleChecksumInfo(contentName: content.name, algo: description.hashAlgo ?? "sha-256", hash: $0)
            }
            self.checksumPromised = description.hashUsed
        }
    }

    /// How the receiver confirmed a send.
    private enum SendConfirmation {
        case received
        case terminatedSuccess
    }

    /// The sending side of a session, created when a send starts and kept until the session ends.
    private struct SendState {
        let transport: JingleTransportKind
        var confirmation: SendConfirmation?
        /// Set while `sendFileData` runs, which then owns committing the session's successful end.
        var isOwnerActive = true
        var wait: CheckedContinuation<Void, Error>?
        /// Ends the session once the confirmation wait elapses. Cancelled with the session, so it can never end a later
        /// session that reuses this sid.
        var cleanupTask: Task<Void, Never>?
    }

    /// How a claimed receive reads its bytes.
    private enum ReceiveTransport {
        case socks5(SOCKS5Connection)
        case ibb
    }

    /// What a send needs, captured when it starts.
    private struct SendStart {
        let context: ModuleContext
        let connection: SOCKS5Connection?
        let ibbState: IBBSessionState?
    }

    /// What a claim task needs, captured when it claims the receive.
    private struct ReceiveClaim {
        let context: ModuleContext
        let expectedSize: Int64
        let transport: ReceiveTransport
        let expiryTask: Task<Void, Never>?
        /// The session this claim was taken against, so its owner cannot commit an end against a later session that
        /// reused the sid while the owner was waiting.
        let offerID: String
    }

    /// A receive removed by its owner, with what its notifications need.
    private struct CommittedReceive {
        let peer: FullJID
        let content: JingleContent
        let peerEnd: PeerEnd?
        let resources: SessionResources
    }

    /// Outcome of registering a wait under the lock.
    private enum WaitRegistration {
        case gone
        case ready
        case waiting
    }

    /// Outcome of resolving a send's end under the lock.
    private enum SendEnd {
        case committed(JingleTransportKind, SessionResources)
        case confirmed
        case failed(any Error)
        /// A write failed before the receiver confirmed, and the session was removed with it.
        case abandoned(any Error, SessionResources)
        case unconfirmed
    }

    /// Sentinel CID for connections accepted by the local listener.
    private static let listenerCID = "direct-listener"

    /// Default block size for IBB transport (bytes per data chunk).
    private static let defaultIBBBlockSize = 4096

    // MARK: - State

    private struct SessionResources {
        let offerID: String
        var session: JingleSession?
        var connection: SOCKS5Connection?
        var pendingProxy: PendingProxy?
        /// A connection this side's listener accepted that the peer has not yet nominated with candidate-used. It carries
        /// nothing until then (XEP-0260 §2.4), so a peer's candidate-error can still switch the session to IBB.
        var pendingDirect: SOCKS5Connection?
        /// The direct candidate the peer nominated with candidate-used, kept so a connection the listener accepts
        /// afterwards is promoted at once.
        var nominatedDirectCID: String?
        var listener: SOCKS5Listener?
        var ibb: IBBSessionState?
        var transportWait: CheckedContinuation<Void, Error>?
        var receive: ReceiveState?
        var send: SendState?
        /// Abandons a send the peer accepted once no transport became ready in time.
        var transportDeadline: Task<Void, Never>?

        var continuations: SessionContinuations {
            SessionContinuations(
                transport: transportWait, wake: receive?.wake, checksumWait: receive?.checksumWait, sendWait: send?.wait,
                tasks: [receive?.expiryTask, receive?.endOfStreamTask, send?.cleanupTask, transportDeadline].compactMap(\.self)
            )
        }

        func closeTransport() async {
            await connection?.close()
            await pendingProxy?.connection.close()
            await pendingDirect?.close()
            await listener?.close()
        }

        func cancel(with error: any Error) {
            continuations.cancel(with: error)
            Task { await closeTransport() }
        }

        mutating func takeTransportWait() -> CheckedContinuation<Void, Error>? {
            defer { transportWait = nil }
            return transportWait
        }

        mutating func takePendingProxy() -> PendingProxy? {
            defer { pendingProxy = nil }
            return pendingProxy
        }

        mutating func takePendingDirect() -> SOCKS5Connection? {
            defer { pendingDirect = nil }
            return pendingDirect
        }

        mutating func takeListener() -> SOCKS5Listener? {
            defer { listener = nil }
            return listener
        }
    }

    private struct State {
        var context: ModuleContext?
        var resources: [String: SessionResources] = [:]
        var cachedProxy65: ProxyInfo?
        var ibbSIDToJingleSID: [String: String] = [:]
    }

    private let state: OSAllocatedUnfairLock<State>
    private let timing: JingleTiming
    private let localAddresses: @Sendable () -> [NetworkInterfaces.Address]
    private let startListener: @Sendable (SOCKS5Listener) async throws -> UInt16

    public var features: [String] {
        [XMPPNamespaces.jingle, XMPPNamespaces.jingleFileTransfer,
         XMPPNamespaces.jingleS5B, XMPPNamespaces.jingleIBB]
    }

    public convenience init(timing: JingleTiming = .init()) {
        self.init(timing: timing, localAddresses: NetworkInterfaces.localAddresses, startListener: { try await $0.start() })
    }

    init(
        timing: JingleTiming = .init(),
        localAddresses: @escaping @Sendable () -> [NetworkInterfaces.Address],
        startListener: @escaping @Sendable (SOCKS5Listener) async throws -> UInt16
    ) {
        self.timing = timing
        self.localAddresses = localAddresses
        self.startListener = startListener
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleDisconnect() async {
        let snapshot = state.withLock { state in
            let sids = state.resources.compactMap { $0.value.session == nil ? nil : $0.key }
            let resources = Array(state.resources.keys).compactMap { detachSessionResources(sid: $0, state: &state) }
            state.cachedProxy65 = nil
            return DisconnectSnapshot(sids: sids, context: state.context, resources: resources)
        }
        for resources in snapshot.resources {
            resources.continuations.cancel(with: JingleError.notConnected)
            await resources.closeTransport()
        }

        for sid in snapshot.sids {
            snapshot.context?.emitEvent(.jingleFileTransferFailed(sid: sid, reason: .disconnected))
        }
    }

    // MARK: - IQ Handling

    public func handleIQ(_ iq: XMPPIQ) throws -> Bool {
        guard iq.isSet, let child = iq.childElement else { return false }

        if child.name == "jingle", child.namespace == XMPPNamespaces.jingle {
            handleJingleIQ(iq, jingle: child)
            return true
        } else if child.namespace == XMPPNamespaces.ibb {
            handleIBBIQ(iq, child: child)
            return true
        }
        return false
    }

    private func handleJingleIQ(_ iq: XMPPIQ, jingle: XMLElement) {
        guard let actionStr = jingle.attribute("action"),
              let action = JingleAction(rawValue: actionStr),
              let sid = jingle.attribute("sid") else { return }

        let (context, session, hasResources) = state.withLock { ($0.context, $0.resources[sid]?.session, $0.resources[sid] != nil) }
        guard let context else { return }

        // `XMPPClient` dispatches IQs serially, so the sender stays verified for the handler below, and the conflict check
        // keeps a live sid from being replaced.
        if action == .sessionInitiate {
            guard !hasResources else {
                log.debug("Rejecting session-initiate for a live sid: \(sid)")
                replyError(to: iq, type: .cancel, condition: .conflict, jingleCondition: .tieBreak, context: context)
                return
            }
        } else {
            guard let session, iq.from == .full(session.peer) else {
                log.debug("Rejecting \(actionStr) for an unknown session, sid: \(sid)")
                replyError(to: iq, type: .cancel, condition: .itemNotFound, jingleCondition: .unknownSession, context: context)
                return
            }
        }

        switch action {
        case .sessionInitiate, .sessionAccept, .sessionTerminate, .sessionInfo,
             .transportInfo, .transportReplace, .contentAdd:
            acknowledgeIQ(iq, context: context)
        case .transportAccept, .transportReject, .contentAccept, .contentReject, .contentRemove:
            break
        }

        switch action {
        case .sessionInitiate:
            handleSessionInitiate(jingle, from: iq.from, sid: sid, context: context)
        case .sessionAccept:
            handleSessionAccept(jingle, sid: sid, context: context)
        case .sessionTerminate:
            handleSessionTerminate(jingle, sid: sid, context: context)
        case .transportInfo:
            handleTransportInfo(jingle, sid: sid, context: context)
        case .transportReplace:
            handleTransportReplace(jingle, sid: sid, from: iq.from, context: context)
        case .transportAccept:
            handleTransportAccept(iq, sid: sid, context: context)
        case .transportReject:
            handleTransportReject(iq, sid: sid, context: context)
        case .sessionInfo:
            handleSessionInfo(jingle, sid: sid, context: context)
        case .contentAdd:
            handleContentAdd(jingle, sid: sid, context: context)
        case .contentAccept, .contentReject:
            replyOutOfOrder(to: iq, context: context)
        case .contentRemove:
            handleContentRemove(jingle, iq: iq, sid: sid, context: context)
        }
    }

    private func acknowledgeIQ(_ iq: XMPPIQ, context: ModuleContext) {
        guard let result = XMPPIQ.resultReply(for: iq) else { return }
        Task {
            do {
                try await context.sendStanza(result)
            } catch {
                log.warning("Failed to acknowledge IQ: \(error)")
            }
        }
    }

    /// Replies to `iq` with an error holding a stanza `condition` and, for Jingle errors, a `jingleCondition`.
    private func replyError(
        to iq: XMPPIQ,
        type: XMPPStanzaError.ErrorType,
        condition: XMPPStanzaError.Condition,
        jingleCondition: JingleErrorCondition? = nil,
        context: ModuleContext
    ) {
        guard let errorIQ = XMPPIQ.errorReply(
            for: iq, type: type, condition: condition, applicationCondition: jingleCondition?.element
        ) else { return }
        Task {
            do {
                try await context.sendStanza(errorIQ)
            } catch {
                log.warning("Failed to send IQ error: \(error)")
            }
        }
    }

    private func replyOutOfOrder(to iq: XMPPIQ, context: ModuleContext) {
        replyError(to: iq, type: .cancel, condition: .unexpectedRequest, jingleCondition: .outOfOrder, context: context)
    }

    // MARK: - Action Handlers

    private func handleSessionInitiate(_ jingle: XMLElement, from: JID?, sid: String, context: ModuleContext) {
        guard let from,
              case let .full(fullJID) = from else {
            log.warning("Invalid session-initiate: missing or bare from JID")
            return
        }

        guard let contentElement = jingle.child(named: "content"),
              let content = JingleContent(from: contentElement) else {
            log.debug("Declining a session-initiate with missing or malformed content, sid: \(sid)")
            refuseSessionInitiate(sid: sid, peer: fullJID, reason: .decline, context: context)
            return
        }

        switch content.effectiveSenders {
        case .initiator, .both:
            break
        case .responder, .none:
            // This side only receives files the peer offers, so a request for a file is declined.
            log.debug("Declining a session-initiate that offers no file, sid: \(sid)")
            refuseSessionInitiate(sid: sid, peer: fullJID, reason: .decline, context: context)
            return
        }

        guard !Self.requiresUnsupportedRange(jingle, fullSize: content.description.size) else {
            // Nothing here resumes a transfer, so a partial offer would land a fragment under the whole file's name.
            log.debug("Declining a session-initiate that offers only part of a file, sid: \(sid)")
            refuseSessionInitiate(sid: sid, peer: fullJID, reason: .decline, context: context)
            return
        }

        let session = JingleSession(peer: fullJID, role: .responder, content: content)
        let offerID = state.withLock { Self.addSession(session, sid: sid, state: &$0) }

        let offer = JingleFileOffer(
            offerID: offerID,
            sid: sid,
            from: fullJID,
            fileName: content.description.name,
            fileSize: content.description.size,
            mediaType: content.description.mediaType
        )
        context.emitEvent(.jingleFileTransferReceived(offer))
    }

    /// Ends a session-initiate this side will not take. Nothing was stored for it, so its sid stays free.
    private func refuseSessionInitiate(sid: String, peer: FullJID, reason: JingleTerminateReason, context: ModuleContext) {
        Task {
            do {
                try await sendSessionTerminate(sid: sid, peer: peer, reason: reason, context: context)
            } catch {
                log.warning("Failed to refuse a session-initiate: \(error)")
            }
        }
    }

    /// Stores a new session, stamped so a later session reusing this sid is distinguishable, and with its receiving
    /// state when this side is the responder. Returns the session's offer id. Must be called within a state.withLock.
    @discardableResult
    private static func addSession(_ session: JingleSession, sid: String, state: inout State) -> String {
        var stamped = session
        let offerID = state.resources[sid]?.offerID ?? makeOfferID()
        if state.resources[sid] == nil { state.resources[sid] = SessionResources(offerID: offerID) }
        stamped.offerID = offerID
        state.resources[sid]?.session = stamped
        if stamped.role == .responder {
            state.resources[sid]?.receive = ReceiveState(content: stamped.content)
        }
        return stamped.offerID
    }

    /// The session under `sid`, when it is the one `offerID` names. A nil `offerID` names whichever session holds the sid.
    private static func session(_ sid: String, offerID: String?, in state: State) -> JingleSession? {
        guard let session = state.resources[sid]?.session, offerID == nil || session.offerID == offerID else { return nil }
        return session
    }

    private func handleSessionInfo(_ jingle: XMLElement, sid: String, context: ModuleContext) {
        if let checksum = jingle.child(named: "checksum", namespace: XMPPNamespaces.jingleFileTransfer) {
            let contentName = checksum.attribute("name") ?? ""
            guard let file = checksum.child(named: "file"),
                  let hashElement = file.child(named: "hash", namespace: XMPPNamespaces.hashes2),
                  let algo = hashElement.attribute("algo"),
                  let hashValue = hashElement.textContent else {
                log.warning("session-info checksum: malformed element for sid: \(sid)")
                return
            }
            let info = JingleChecksumInfo(contentName: contentName, algo: algo, hash: hashValue)
            let checksumWait = state.withLock { state -> CheckedContinuation<Void, Error>? in
                guard var receive = state.resources[sid]?.receive else { return nil }
                receive.sessionInfoChecksum = info
                let wait = receive.checksumWait
                receive.checksumWait = nil
                state.resources[sid]?.receive = receive
                return wait
            }
            checksumWait?.resume()
            context.emitEvent(.jingleChecksumReceived(sid: sid, checksum: info))
            return
        }

        if jingle.child(named: "received", namespace: XMPPNamespaces.jingleFileTransfer) != nil {
            let sendWait = state.withLock { state -> CheckedContinuation<Void, Error>? in
                guard var send = state.resources[sid]?.send else { return nil }
                if send.confirmation == nil {
                    send.confirmation = .received
                }
                let wait = send.wait
                send.wait = nil
                state.resources[sid]?.send = send
                return wait
            }
            sendWait?.resume()
        }
    }

    // MARK: - Content Action Handlers

    /// Adding contents to a session is unsupported, so every offered content is rejected.
    private func handleContentAdd(_ jingle: XMLElement, sid: String, context: ModuleContext) {
        let contents = jingle.children(named: "content").compactMap { element -> XMLElement? in
            guard let name = element.attribute("name"), let creator = element.attribute("creator") else { return nil }
            return XMLElement(name: "content", attributes: ["creator": creator, "name": name])
        }
        let peer = state.withLock { $0.resources[sid]?.session?.peer }
        guard !contents.isEmpty, let peer else {
            log.warning("content-add without content elements for sid: \(sid)")
            return
        }

        Task {
            var iq = XMPPIQ(type: .set, to: .full(peer), id: context.generateID())
            var jingle = XMLElement(
                name: "jingle",
                namespace: XMPPNamespaces.jingle,
                attributes: ["action": JingleAction.contentReject.rawValue, "sid": sid]
            )
            for content in contents {
                jingle.addChild(content)
            }
            iq.element.addChild(jingle)
            do {
                try await context.sendStanza(iq)
            } catch {
                log.warning("Failed to send content-reject: \(error)")
            }
        }
    }

    private func handleContentRemove(_ jingle: XMLElement, iq: XMPPIQ, sid: String, context: ModuleContext) {
        let names = jingle.children(named: "content").compactMap { $0.attribute("name") }
        let primaryName = state.withLock { $0.resources[sid]?.session?.content.name }
        guard let primaryName, !names.isEmpty, names.allSatisfy({ $0 == primaryName }) else {
            replyOutOfOrder(to: iq, context: context)
            return
        }

        acknowledgeIQ(iq, context: context)
        abandonTransport(sid: sid, reason: .cancel, terminateReason: .cancel, context: context)
    }

    private func handleSessionAccept(_ jingle: XMLElement, sid: String, context: ModuleContext) {
        let offeredSize = state.withLock { state -> Int64? in
            guard let session = state.resources[sid]?.session, session.role == .initiator else { return nil }
            // Armed before the range check: a rejected range abandons the session, which cancels the deadline with it.
            startTransportDeadline(sid: sid, offerID: session.offerID, state: &state)
            return session.content.description.size
        }
        guard let offeredSize else {
            log.debug("Ignoring session-accept for a session this side did not initiate, sid: \(sid)")
            return
        }

        guard !Self.requiresUnsupportedRange(jingle, fullSize: offeredSize) else {
            // Sending a slice would need a resume this side does not implement, and sending the whole file would not be
            // what the peer accepted.
            log.debug("Failing a session-accept that asks for part of the file, sid: \(sid)")
            abandonTransport(sid: sid, reason: .cancel, terminateReason: .cancel, context: context)
            return
        }

        Task { await beginTransportConnection(sid: sid, context: context) }
    }

    /// Starts the deadline by which a send the peer accepted needs a ready transport. A repeated session-accept keeps the
    /// first one. Must be called within a state.withLock.
    private func startTransportDeadline(sid: String, offerID: String, state: inout State) {
        guard state.resources[sid]?.transportDeadline == nil else { return }
        let wait = timing.transportReadyWait
        state.resources[sid]?.transportDeadline = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            transportDeadlineExpired(sid: sid, offerID: offerID)
        }
    }

    private func transportDeadlineExpired(sid: String, offerID: String) {
        guard let context = state.withLock({ $0.context }) else { return }
        abandonTransport(sid: sid, reason: .timeout, terminateReason: .timeout, context: context) { state in
            state.resources[sid]?.session?.offerID == offerID && !Self.isTransportReady(sid: sid, in: state)
        }
    }

    /// Whether any content's `<range/>` asks for anything but the whole file: every present `offset` must be zero and
    /// every present `length` the full size. Read from the raw elements, so content that fails to parse cannot slip a
    /// range past the check.
    private static func requiresUnsupportedRange(_ jingle: XMLElement, fullSize: Int64) -> Bool {
        jingle.children(named: "content").contains { content in
            guard let description = content.child(named: "description", namespace: XMPPNamespaces.jingleFileTransfer),
                  let range = description.child(named: "file")?.child(named: "range") else { return false }
            if let offset = range.attribute("offset"), Int64(offset) != 0 { return true }
            if let length = range.attribute("length"), Int64(length) != fullSize { return true }
            return false
        }
    }

    private func handleSessionTerminate(_ jingle: XMLElement, sid: String, context: ModuleContext) {
        guard let failure = JingleTransferFailureReason(terminationReason: parseTerminateReason(jingle)) else {
            handleSuccessTerminate(sid: sid, context: context)
            return
        }

        let removed = removeSession(sid: sid)
        guard let removed else {
            log.debug("Ignoring session-terminate for unknown sid: \(sid)")
            return
        }
        // Whoever is waiting learns the peer's reason, such as a decline, rather than that the session went missing.
        removed.resources.cancel(with: JingleError.transportFailed(failure.displayText))
        context.emitEvent(.jingleFileTransferFailed(sid: sid, reason: failure))
    }

    private func handleSuccessTerminate(sid: String, context: ModuleContext) {
        let role = state.withLock { $0.resources[sid]?.session?.role }
        switch role {
        case nil:
            log.debug("Ignoring session-terminate for unknown sid: \(sid)")
        case .initiator?:
            handleSenderSuccessTerminate(sid: sid, context: context)
        case .responder?:
            handlePeerSuccessEnd(sid: sid, end: .terminatedSuccess, context: context)
        }
    }

    /// Outcome of a receiver's success terminate on a sending session.
    private enum SenderTerminateResolution {
        case recorded(CheckedContinuation<Void, Error>?)
        case committed(JingleTransportKind, SessionResources)
        case notStarted
    }

    private func handleSenderSuccessTerminate(sid: String, context: ModuleContext) {
        let resolution = state.withLock { state -> SenderTerminateResolution? in
            guard state.resources[sid]?.session != nil else { return nil }
            guard var send = state.resources[sid]?.send else { return .notStarted }
            guard !send.isOwnerActive else {
                send.confirmation = .terminatedSuccess
                let wait = send.wait
                send.wait = nil
                state.resources[sid]?.send = send
                return .recorded(wait)
            }
            guard let resources = detachSessionResources(sid: sid, state: &state) else { return nil }
            return .committed(send.transport, resources)
        }

        switch resolution {
        case nil:
            log.debug("Ignoring session-terminate for unknown sid: \(sid)")
        case let .recorded(wait):
            wait?.resume()
        case let .committed(transport, resources):
            resources.cancel(with: JingleError.sessionNotFound)
            context.emitEvent(.jingleFileTransferCompleted(sid: sid, transport: transport))
        case .notStarted:
            abandonTransport(sid: sid, reason: .cancel, terminateReason: nil, context: context)
        }
    }

    /// Outcome of a peer's successful end on a receiving session.
    private enum PeerSuccessEndResolution {
        case recorded(wake: CheckedContinuation<Void, Error>?)
        case nothingClaimable
    }

    /// Records a peer's successful end of a receive and wakes its claim, or fails a receive with nothing left to claim.
    private func handlePeerSuccessEnd(sid: String, end: PeerEnd, context: ModuleContext) {
        let resolution = state.withLock { state -> PeerSuccessEndResolution? in
            guard state.resources[sid]?.session != nil, var receive = state.resources[sid]?.receive else { return nil }
            let hasBufferedBytes = state.resources[sid]?.ibb?.receivedData.isEmpty == false
            let hasConnection = state.resources[sid]?.connection != nil
            guard hasBufferedBytes || receive.isClaimed || hasConnection else { return .nothingClaimable }

            if receive.peerEnd == nil || end == .terminatedSuccess {
                receive.peerEnd = end
            }
            let wake = receive.wake
            receive.wake = nil
            if !receive.isClaimed {
                startUnclaimedExpiry(sid: sid, receive: &receive)
            } else if wake == nil, hasConnection {
                armEndOfStream(sid: sid, receive: &receive)
            }
            state.resources[sid]?.receive = receive
            return .recorded(wake: wake)
        }

        switch resolution {
        case nil:
            log.debug("Ignoring a peer's end for an unknown receive, sid: \(sid)")
        case let .recorded(wake):
            wake?.resume()
        case .nothingClaimable:
            abandonTransport(sid: sid, reason: .incomplete, terminateReason: nil, context: context)
        }
    }

    private func handleTransportInfo(_ jingle: XMLElement, sid: String, context: ModuleContext) {
        let transportElement = extractTransportElement(from: jingle)
        guard let transportElement else {
            log.warning("transport-info without transport element for sid: \(sid)")
            return
        }

        if let candidateUsed = transportElement.child(named: "candidate-used"),
           let cid = candidateUsed.attribute("cid") {
            handleCandidateUsed(sid: sid, cid: cid, context: context)
        } else if transportElement.child(named: "candidate-error") != nil {
            handleCandidateError(sid: sid, context: context)
        } else if transportElement.child(named: "proxy-error") != nil {
            handleProxyError(sid: sid, context: context)
        } else if let activated = transportElement.child(named: "activated") {
            handleProxyActivated(sid: sid, cid: activated.attribute("cid"))
        }
    }

    private func handleCandidateUsed(sid: String, cid: String, context: ModuleContext) {
        let session = state.withLock { $0.resources[sid]?.session }
        guard let session, Self.acceptsSOCKS5Outcome(session) else { return }

        // If we're the initiator and the peer selected a candidate, handle by type
        guard session.role == .initiator else { return }

        if case let .socks5(transport) = session.content.transport {
            let candidate = transport.candidates.first { $0.cid == cid }
            guard let candidate else { return }

            switch candidate.type {
            case .direct:
                // The peer nominated this side's listener. Its connection carries the file once the listener has also
                // accepted it, in either order. The transport attempt closes the listener once its accept returns.
                let wake = state.withLock { state -> CheckedContinuation<Void, Error>? in
                    guard Self.socks5OutcomeOpen(sid: sid, offerID: session.offerID, in: state) else { return nil }
                    state.resources[sid]?.nominatedDirectCID = cid
                    return Self.promoteNominatedDirect(sid: sid, state: &state)
                }
                wake?.resume()
            case .proxy:
                Task {
                    await connectAndActivateProxy(
                        sid: sid, candidate: candidate, transportSID: transport.sid,
                        session: session, context: context
                    )
                }
            }
        }
    }

    /// A proxy-error means the nominated proxy's bytestream is dead (XEP-0260 §2.4). The initiator falls back to IBB
    /// itself. A responder cannot replace the transport, so it only closes its parked proxy socket and waits for the
    /// initiator's transport-replace.
    private func handleProxyError(sid: String, context: ModuleContext) {
        log.debug("Peer reported a proxy error for sid: \(sid)")
        switch state.withLock({ $0.resources[sid]?.session?.role }) {
        case .initiator?:
            handleCandidateError(sid: sid, context: context)
        case .responder?:
            releasePendingProxy(sid: sid)
        case nil:
            log.debug("Ignoring a proxy-error for an unknown session, sid: \(sid)")
        }
    }

    /// `SOCKS5Connection.connect` counts its timeout in seconds, while the module's waits are `Duration`s.
    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// Whether `cid` names a proxy candidate of the transport this session offered.
    private static func isProxyCandidate(cid: String, in session: JingleSession) -> Bool {
        guard case let .socks5(transport) = session.content.transport,
              let candidate = transport.candidates.first(where: { $0.cid == cid }) else { return false }
        if case .proxy = candidate.type { return true }
        return false
    }

    /// The offering side activated the proxy it nominated, so the socket parked when this side connected is now a live
    /// bytestream (XEP-0260 §2.4). Publishing it here is what lets the transport wait and the claim reach it.
    private func handleProxyActivated(sid: String, cid: String?) {
        let promoted = state.withLock { state -> (wake: CheckedContinuation<Void, Error>?, stale: SOCKS5Connection?) in
            guard let pending = state.resources[sid]?.takePendingProxy() else { return (nil, nil) }
            // An activation can arrive after this session already settled on IBB, and promoting the parked socket then
            // would have the claim read a proxy stream nobody writes to while the bytes that did arrive sit unread.
            guard let session = state.resources[sid]?.session, Self.acceptsSOCKS5Outcome(session) else {
                return (nil, pending.connection)
            }
            return (Self.publishSOCKS5(pending.connection, cid: cid ?? pending.cid, sid: sid, state: &state), nil)
        }
        if let stale = promoted.stale {
            Task { await stale.close() }
        }
        promoted.wake?.resume()
    }

    /// Connects to the proxy the peer nominated, activates it, and only then announces it (XEP-0260 §2.4-2.5).
    /// Announcing first would leave the peer reading a bytestream this side has no connection to write to.
    private func connectAndActivateProxy(
        sid: String,
        candidate: SOCKS5Transport.Candidate,
        transportSID: String,
        session: JingleSession,
        context: ModuleContext
    ) async {
        // The candidate was looked up by this cid, so it carries the one to announce and to record.
        let cid = candidate.cid
        let connection = SOCKS5Connection()
        do {
            try await connection.connect(
                host: candidate.host, port: candidate.port,
                destinationAddress: computeDestinationAddress(session: session),
                timeout: Self.seconds(timing.proxyConnectWait)
            )
            try await activateProxy(
                proxyJID: candidate.jid, targetJID: session.peer.description,
                transportSID: transportSID, context: context
            )
        } catch {
            log.debug("Proxy activation failed for sid \(sid): \(error)")
            await connection.close()
            // A repeated nomination that fails after another dial published the transport, or after its session ended,
            // decides nothing: falling back would close the transport that is carrying the file.
            let isCurrent = state.withLock { Self.socks5OutcomeOpen(sid: sid, offerID: session.offerID, in: $0) }
            guard isCurrent else { return }
            // XEP-0260 §2.4 asks the failing side to say so, and both sides to fall back rather than give up.
            sendTransportInfo(
                sid: sid, session: session, context: context, transportChild: XMLElement(name: "proxy-error")
            )
            handleCandidateError(sid: sid, context: context)
            return
        }

        sendTransportInfo(
            sid: sid, session: session, context: context,
            transportChild: XMLElement(name: "activated", attributes: ["cid": cid])
        )

        let published = state.withLock { state -> (continuation: CheckedContinuation<Void, Error>?, unselected: SOCKS5Connection?)? in
            // Nothing collapses repeated nominations, so a peer that names its proxy again starts another dial. The
            // first to publish owns the transport: a later winner would replace a socket an owner may already be
            // reading, leaving that one open with nothing left to close it. The loser closes its own connection below.
            guard Self.socks5OutcomeOpen(sid: sid, offerID: session.offerID, in: state) else { return nil }
            let unselected = state.resources[sid]?.takePendingDirect()
            return (Self.publishSOCKS5(connection, cid: cid, sid: sid, state: &state), unselected)
        }
        guard let published else {
            await connection.close()
            return
        }
        // The peer chose the proxy, so a connection it made to this side's listener carries nothing.
        await published.unselected?.close()
        published.continuation?.resume()
    }

    private func handleCandidateError(sid: String, context: ModuleContext) {
        let ibbSID = Self.makeStreamID()
        let fallback = state.withLock { state -> (session: JingleSession, transport: IBBTransport)? in
            // Only the responder connects to candidates, so the initiator's candidate-error decides nothing on the
            // responder: the initiator follows it with a transport-replace or a session-terminate. A connection the peer
            // nominated with candidate-used, published or still awaiting proxy activation, outweighs a candidate-error
            // (XEP-0260 §2.4). One the listener accepted without a nomination is dropped with the rest.
            guard let session = state.resources[sid]?.session, session.role == .initiator,
                  Self.socks5OutcomeOpen(sid: sid, offerID: nil, in: state) else {
                return nil
            }
            // Propose IBB fallback. Switching before the SOCKS5 resources close makes their late outcomes stale.
            state.resources[sid]?.session?.transportState = .replacePending
            state.resources[sid]?.session?.selectedTransport = .ibb
            state.resources[sid]?.ibb = IBBSessionState(ibbSID: ibbSID, blockSize: Self.defaultIBBBlockSize)
            state.ibbSIDToJingleSID[ibbSID] = sid
            return (session, IBBTransport(sid: ibbSID, blockSize: Self.defaultIBBBlockSize))
        }
        guard let fallback else {
            log.debug("Ignoring candidate-error that calls for no fallback, sid: \(sid)")
            return
        }
        cleanupTransport(sid: sid)
        sendTransportReplace(sid: sid, ibbTransport: fallback.transport, session: fallback.session, context: context)
    }

    /// Whether a SOCKS5 outcome still applies, which stops once the session switches to IBB. An outcome for a session that
    /// ended or was abandoned finds no session before reaching this check.
    private static func acceptsSOCKS5Outcome(_ session: JingleSession) -> Bool {
        session.selectedTransport != .ibb
    }

    /// Whether a SOCKS5 outcome can still decide the transport of the session under `sid` (the one `offerID` names, when
    /// given): it still takes SOCKS5, and no connection is published or parked awaiting activation to own it. Must be
    /// called within a state.withLock.
    private static func socks5OutcomeOpen(sid: String, offerID: String?, in state: State) -> Bool {
        guard let session = session(sid, offerID: offerID, in: state), acceptsSOCKS5Outcome(session) else { return false }
        return state.resources[sid]?.connection == nil && state.resources[sid]?.pendingProxy == nil
    }

    /// Publishes the listener's connection once the peer both reached it and nominated it, returning the transport waiter
    /// to resume. Must be called within a state.withLock.
    private static func promoteNominatedDirect(sid: String, state: inout State) -> CheckedContinuation<Void, Error>? {
        guard let cid = state.resources[sid]?.nominatedDirectCID, let connection = state.resources[sid]?.takePendingDirect() else {
            return nil
        }
        return publishSOCKS5(connection, cid: cid, sid: sid, state: &state)
    }

    /// Makes `connection` the session's transport, returning the transport waiter to resume. Must be called within a
    /// state.withLock.
    private static func publishSOCKS5(
        _ connection: SOCKS5Connection, cid: String, sid: String, state: inout State
    ) -> CheckedContinuation<Void, Error>? {
        state.resources[sid]?.connection = connection
        state.resources[sid]?.session?.transportState = .connected(candidateCID: cid)
        state.resources[sid]?.session?.selectedTransport = .socks5
        return state.resources[sid]?.takeTransportWait()
    }

    private func parseTerminateReason(_ jingle: XMLElement) -> JingleTerminateReason? {
        guard let reasonElement = jingle.child(named: "reason") else { return nil }
        for case let .element(child) in reasonElement.children {
            if let reason = JingleTerminateReason(rawValue: child.name) {
                return reason
            }
        }
        return nil
    }

    private func extractTransportElement(from jingle: XMLElement) -> XMLElement? {
        // Try <content><transport> first, then <transport> directly under <jingle>
        if let content = jingle.child(named: "content") {
            if let transport = content.child(named: "transport", namespace: XMPPNamespaces.jingleS5B) {
                return transport
            }
            if let transport = content.child(named: "transport", namespace: XMPPNamespaces.jingleIBB) {
                return transport
            }
        }
        if let transport = jingle.child(named: "transport", namespace: XMPPNamespaces.jingleS5B) {
            return transport
        }
        return jingle.child(named: "transport", namespace: XMPPNamespaces.jingleIBB)
    }

    // MARK: - Transport Replace/Accept/Reject

    /// Outcome of a transport-replace under the lock.
    private enum TransportReplaceResolution {
        case unknown
        case rejected
        case accepted(CheckedContinuation<Void, Error>?)
    }

    private func handleTransportReplace(_ jingle: XMLElement, sid: String, from: JID?, context: ModuleContext) {
        let transportElement = extractTransportElement(from: jingle)
        guard let transportElement,
              let ibbTransport = IBBTransport(from: transportElement) else {
            log.warning("transport-replace without valid IBB transport for sid: \(sid)")
            sendTransportReject(sid: sid, context: context)
            return
        }

        guard let from, case .full = from else {
            log.warning("transport-replace with invalid from JID")
            return
        }

        let resolution = state.withLock { state -> TransportReplaceResolution in
            guard state.resources[sid]?.session != nil else { return .unknown }
            // An IBB sid owned by another session, an open SOCKS5 connection, or a claimed receive keeps its transport.
            if let owner = state.ibbSIDToJingleSID[ibbTransport.sid], owner != sid { return .rejected }
            guard state.resources[sid]?.connection == nil, state.resources[sid]?.receive?.isClaimed != true else { return .rejected }

            if let previous = state.resources[sid]?.ibb, state.ibbSIDToJingleSID[previous.ibbSID] == sid {
                state.ibbSIDToJingleSID.removeValue(forKey: previous.ibbSID)
            }
            state.resources[sid]?.ibb = IBBSessionState(ibbSID: ibbTransport.sid, blockSize: ibbTransport.blockSize)
            state.ibbSIDToJingleSID[ibbTransport.sid] = sid
            state.resources[sid]?.session?.transportState = .pending
            state.resources[sid]?.session?.selectedTransport = .ibb
            return .accepted(state.resources[sid]?.takeTransportWait())
        }

        switch resolution {
        case .unknown:
            log.debug("Ignoring transport-replace for unknown sid: \(sid)")
        case .rejected:
            log.debug("Rejecting transport-replace that would displace a transport, sid: \(sid)")
            sendTransportReject(sid: sid, context: context)
        case let .accepted(continuation):
            sendTransportAccept(sid: sid, ibbTransport: ibbTransport, context: context)
            continuation?.resume()
        }
    }

    private func handleTransportAccept(_ iq: XMPPIQ, sid: String, context: ModuleContext) {
        let accepted = state.withLock { state -> (isExpected: Bool, wake: CheckedContinuation<Void, Error>?) in
            // Only a replace this side proposed can be accepted; an unrequested one must not unsettle a transport in use.
            guard Self.isReplacePending(sid: sid, in: state) else { return (false, nil) }
            state.resources[sid]?.session?.transportState = .pending
            return (true, state.resources[sid]?.takeTransportWait())
        }
        guard accepted.isExpected else {
            replyOutOfOrder(to: iq, context: context)
            return
        }
        acknowledgeIQ(iq, context: context)
        accepted.wake?.resume()
    }

    private func handleTransportReject(_ iq: XMPPIQ, sid: String, context: ModuleContext) {
        // Only a replace this side proposed can be rejected; an unrequested reject must not end a transfer in progress.
        guard abandonTransport(sid: sid, reason: .transportReject, context: context, if: { Self.isReplacePending(sid: sid, in: $0) }) else {
            replyOutOfOrder(to: iq, context: context)
            return
        }
        acknowledgeIQ(iq, context: context)
    }

    /// Whether this side proposed a transport-replace the peer has not yet answered. Must be called within a
    /// state.withLock.
    private static func isReplacePending(sid: String, in state: State) -> Bool {
        guard case .replacePending? = state.resources[sid]?.session?.transportState else { return false }
        return true
    }

    /// Fails a session no owner can end: reports `reason` locally and, unless `terminateReason` is `nil` because the peer
    /// already ended it, notifies the peer. The session is removed, so anything that later addresses the sid finds no
    /// session. Does nothing and returns `false` when the session already ended or `applies` rejects it.
    @discardableResult
    private func abandonTransport(
        sid: String,
        reason: JingleTransferFailureReason,
        terminateReason: JingleTerminateReason? = .failedTransport,
        context: ModuleContext,
        if applies: @Sendable (State) -> Bool = { _ in true }
    ) -> Bool {
        guard let abandoned = removeSession(sid: sid, if: applies) else { return false }
        endAbandonedSession(sid: sid, resources: abandoned.resources, reason: reason, terminateReason: terminateReason, context: context)
        return true
    }

    /// Ends a session already detached on a failure: reports `reason` locally and, unless `terminateReason` is `nil`,
    /// notifies the peer.
    private func endAbandonedSession(
        sid: String,
        resources: SessionResources,
        reason: JingleTransferFailureReason,
        terminateReason: JingleTerminateReason?,
        context: ModuleContext
    ) {
        resources.cancel(with: JingleError.transportNegotiationFailed(reason.displayText))
        context.emitEvent(.jingleFileTransferFailed(sid: sid, reason: reason))
        guard let terminateReason, let peer = resources.session?.peer else { return }
        Task {
            do {
                try await sendSessionTerminate(sid: sid, peer: peer, reason: terminateReason, context: context)
            } catch {
                log.warning("Failed to send session-terminate for an abandoned transport: \(error)")
            }
        }
    }

    /// Removes the session and its transfer state in one critical section, which commits the session's end.
    private func removeSession(
        sid: String, if applies: @Sendable (State) -> Bool = { _ in true }
    ) -> (session: JingleSession, resources: SessionResources)? {
        state.withLock { state in
            guard let session = state.resources[sid]?.session, applies(state),
                  let resources = detachSessionResources(sid: sid, state: &state) else { return nil }
            return (session, resources)
        }
    }

    private func sendTransportReplace(sid: String, ibbTransport: IBBTransport, session: JingleSession, context: ModuleContext) {
        Task {
            var iq = XMPPIQ(type: .set, to: .full(session.peer), id: context.generateID())
            var jingle = XMLElement(
                name: "jingle",
                namespace: XMPPNamespaces.jingle,
                attributes: ["action": JingleAction.transportReplace.rawValue, "sid": sid]
            )
            var content = XMLElement(
                name: "content",
                attributes: ["creator": session.content.creator, "name": session.content.name]
            )
            content.addChild(ibbTransport.toXML())
            jingle.addChild(content)
            iq.element.addChild(jingle)
            do {
                try await context.sendStanza(iq)
            } catch {
                log.warning("Failed to send transport-replace: \(error)")
                abandonTransport(sid: sid, reason: .transportReplaceFailed, context: context)
            }
        }
    }

    private func sendTransportAccept(sid: String, ibbTransport: IBBTransport, context: ModuleContext) {
        let session = state.withLock { $0.resources[sid]?.session }
        guard let session else { return }
        Task {
            var iq = XMPPIQ(type: .set, to: .full(session.peer), id: context.generateID())
            var jingle = XMLElement(
                name: "jingle",
                namespace: XMPPNamespaces.jingle,
                attributes: ["action": JingleAction.transportAccept.rawValue, "sid": sid]
            )
            var content = XMLElement(
                name: "content",
                attributes: ["creator": session.content.creator, "name": session.content.name]
            )
            content.addChild(ibbTransport.toXML())
            jingle.addChild(content)
            iq.element.addChild(jingle)
            do {
                try await context.sendStanza(iq)
            } catch {
                log.warning("Failed to send transport-accept: \(error)")
            }
        }
    }

    private func sendTransportReject(sid: String, context: ModuleContext) {
        let session = state.withLock { $0.resources[sid]?.session }
        guard let session else { return }
        Task {
            var iq = XMPPIQ(type: .set, to: .full(session.peer), id: context.generateID())
            let jingle = XMLElement(
                name: "jingle",
                namespace: XMPPNamespaces.jingle,
                attributes: ["action": JingleAction.transportReject.rawValue, "sid": sid]
            )
            iq.element.addChild(jingle)
            do {
                try await context.sendStanza(iq)
            } catch {
                log.warning("Failed to send transport-reject: \(error)")
            }
        }
    }

    // MARK: - IBB IQ Handling

    private func handleIBBIQ(_ iq: XMPPIQ, child: XMLElement) {
        let context = state.withLock { $0.context }
        guard let context else { return }

        switch child.name {
        case "open":
            handleIBBOpen(iq, open: child, context: context)
        case "data":
            handleIBBData(iq, data: child, context: context)
        case "close":
            handleIBBClose(iq, context: context)
        default:
            break
        }
    }

    /// The session an IBB stanza addresses, when its sender is that session's peer. Must be called within a state.withLock.
    private static func ibbSessionID(for ibbSID: String, from: JID?, state: State) -> String? {
        guard let sid = state.ibbSIDToJingleSID[ibbSID],
              let session = state.resources[sid]?.session,
              from == .full(session.peer) else { return nil }
        return sid
    }

    private func replyIBBItemNotFound(to iq: XMPPIQ, ibbSID: String, context: ModuleContext) {
        log.debug("Rejecting IBB stanza for an unknown stream, ibb-sid: \(ibbSID)")
        replyError(to: iq, type: .cancel, condition: .itemNotFound, context: context)
    }

    /// Closes a bytestream whose data cannot be trusted and fails the transfer with it, so the sender stops sending
    /// blocks the receive will never use.
    private func failIBBStream(sid: String, context: ModuleContext) {
        let target = state.withLock { state -> (ibbSID: String, peer: FullJID)? in
            guard let session = state.resources[sid]?.session, let ibbState = state.resources[sid]?.ibb else { return nil }
            return (ibbState.ibbSID, session.peer)
        }
        if let target {
            Task {
                do {
                    try await sendIBBClose(ibbSID: target.ibbSID, peer: target.peer, context: context)
                } catch {
                    log.warning("Failed to close a broken IBB stream: \(error)")
                }
            }
        }
        abandonTransport(sid: sid, reason: .failedTransport, context: context)
    }

    private func handleIBBOpen(_ iq: XMPPIQ, open element: XMLElement, context: ModuleContext) {
        guard let ibbSID = element.attribute("sid") else { return }
        let from = iq.from
        let isKnown = state.withLock { Self.ibbSessionID(for: ibbSID, from: from, state: $0) != nil }
        guard isKnown else {
            replyIBBItemNotFound(to: iq, ibbSID: ibbSID, context: context)
            return
        }
        acknowledgeIQ(iq, context: context)
    }

    /// Outcome of an IBB data stanza under the lock.
    private enum IBBDataOutcome {
        case unknownStream
        case notAccepted(sid: String)
        case reusedSequence(sid: String)
        case badRequest(sid: String)
        case brokenStream(sid: String)
        case appended(sid: String, transferred: Int64, total: Int64)
    }

    private func handleIBBData(_ iq: XMPPIQ, data element: XMLElement, context: ModuleContext) {
        guard let ibbSID = element.attribute("sid"),
              let seqStr = element.attribute("seq"),
              let seq = UInt16(seqStr),
              let base64Content = element.textContent else {
            return
        }

        let decoded = Base64.decode(base64Content)
        let from = iq.from
        let outcome = state.withLock { state -> IBBDataOutcome in
            guard let sid = Self.ibbSessionID(for: ibbSID, from: from, state: state),
                  var receive = state.resources[sid]?.receive,
                  var ibbState = state.resources[sid]?.ibb else { return .unknownStream }

            // Bytes are only worth holding once the user has taken the offer; until then the peer is sending uninvited.
            guard state.resources[sid]?.session?.isAccepted == true else {
                log.debug("IBB data before the transfer was accepted, ibb-sid: \(ibbSID)")
                return .notAccepted(sid: sid)
            }

            guard let decoded else {
                log.debug("IBB data: invalid base64 for ibb-sid: \(ibbSID)")
                return .badRequest(sid: sid)
            }
            guard seq == ibbState.nextExpectedSeq else {
                log.debug("IBB data: unexpected seq \(seq), expected \(ibbState.nextExpectedSeq)")
                // A sequence number just consumed is a retransmit, which XEP-0047 answers with unexpected-request;
                // anything else means blocks were lost and the stream cannot be trusted.
                return seq == ibbState.nextExpectedSeq &- 1 ? .reusedSequence(sid: sid) : .brokenStream(sid: sid)
            }
            guard Int64(ibbState.receivedData.count + decoded.count) <= receive.expectedSize else {
                log.debug("IBB data: more bytes than the offer declared, ibb-sid: \(ibbSID)")
                return .brokenStream(sid: sid)
            }

            ibbState.receivedData.append(contentsOf: decoded)
            ibbState.nextExpectedSeq &+= 1
            state.resources[sid]?.ibb = ibbState

            let transferred = Int64(ibbState.receivedData.count)
            if !receive.isClaimed {
                startUnclaimedExpiry(sid: sid, receive: &receive)
            } else if receive.peerEnd == nil, receive.wake != nil, transferred >= receive.expectedSize {
                armEndOfStream(sid: sid, receive: &receive)
            }
            state.resources[sid]?.receive = receive
            return .appended(sid: sid, transferred: transferred, total: receive.expectedSize)
        }

        replyIBBData(outcome, to: iq, ibbSID: ibbSID, context: context)
    }

    private func replyIBBData(_ outcome: IBBDataOutcome, to iq: XMPPIQ, ibbSID: String, context: ModuleContext) {
        switch outcome {
        case .unknownStream:
            replyIBBItemNotFound(to: iq, ibbSID: ibbSID, context: context)
        case let .notAccepted(sid):
            replyError(to: iq, type: .cancel, condition: .unexpectedRequest, context: context)
            // The session goes with the refusal. Left alive, its offer would still be acceptable, and accepting it would
            // wait on a stream this side has already told the sender to stop.
            abandonTransport(sid: sid, reason: .cancel, terminateReason: .cancel, context: context)
        case let .reusedSequence(sid):
            replyError(to: iq, type: .cancel, condition: .unexpectedRequest, context: context)
            failIBBStream(sid: sid, context: context)
        case let .badRequest(sid):
            replyError(to: iq, type: .cancel, condition: .badRequest, context: context)
            failIBBStream(sid: sid, context: context)
        case let .brokenStream(sid):
            acknowledgeIQ(iq, context: context)
            failIBBStream(sid: sid, context: context)
        case let .appended(sid, transferred, total):
            acknowledgeIQ(iq, context: context)
            context.emitEvent(.jingleFileTransferProgress(sid: sid, bytesTransferred: transferred, totalBytes: total))
        }
    }

    private func handleIBBClose(_ iq: XMPPIQ, context: ModuleContext) {
        guard let child = iq.childElement,
              let ibbSID = child.attribute("sid") else { return }

        let from = iq.from
        let target = state.withLock { state -> (sid: String, role: JingleSession.Role)? in
            guard let sid = Self.ibbSessionID(for: ibbSID, from: from, state: state),
                  let session = state.resources[sid]?.session else { return nil }
            return (sid, session.role)
        }
        guard let target else {
            replyIBBItemNotFound(to: iq, ibbSID: ibbSID, context: context)
            return
        }

        acknowledgeIQ(iq, context: context)
        if target.role == .initiator {
            // The peer closed the stream this side sends on.
            abandonTransport(sid: target.sid, reason: .cancel, terminateReason: .cancel, context: context)
        } else {
            handlePeerSuccessEnd(sid: target.sid, end: .ibbClosed, context: context)
        }
    }

    // MARK: - Session State Cleanup

    /// Removes the complete lifetime record under the lock; callers release its captured resources outside it.
    private func detachSessionResources(sid: String, state: inout State) -> SessionResources? {
        guard let resources = state.resources.removeValue(forKey: sid) else { return nil }
        if let ibb = resources.ibb, state.ibbSIDToJingleSID[ibb.ibbSID] == sid {
            state.ibbSIDToJingleSID.removeValue(forKey: ibb.ibbSID)
        }
        return resources
    }

    /// Holds the waits and tasks cleanup detached, for the caller to end outside the lock with its own error.
    private struct SessionContinuations {
        let transport: CheckedContinuation<Void, Error>?
        let wake: CheckedContinuation<Void, Error>?
        let checksumWait: CheckedContinuation<Void, Error>?
        let sendWait: CheckedContinuation<Void, Error>?
        let tasks: [Task<Void, Never>]

        func cancel(with error: Error) {
            for task in tasks {
                task.cancel()
            }
            for continuation in [transport, wake, checksumWait, sendWait].compactMap(\.self) {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Receive Waits

    /// Arms the wait after which a claimed receive stops waiting for its stream to end. Must be called within a
    /// state.withLock.
    private func armEndOfStream(sid: String, receive: inout ReceiveState) {
        guard receive.endOfStreamTask == nil else { return }
        let wait = timing.endOfStreamWait
        receive.endOfStreamTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            await endOfStreamWaitElapsed(sid: sid)
        }
    }

    /// Wakes a waiting IBB claim, or closes a SOCKS5 claim's connection so its read ends. The claim finalizes either way.
    private func endOfStreamWaitElapsed(sid: String) async {
        let (wake, connection) = state.withLock { state -> (CheckedContinuation<Void, Error>?, SOCKS5Connection?) in
            guard state.resources[sid]?.session != nil else { return (nil, nil) }
            let wake = state.resources[sid]?.receive?.wake
            state.resources[sid]?.receive?.wake = nil
            return (wake, wake == nil ? state.resources[sid]?.connection : nil)
        }
        wake?.resume()
        await connection?.close()
    }

    /// Starts the expiry that fails a receive nobody claims. Must be called within a state.withLock.
    private func startUnclaimedExpiry(sid: String, receive: inout ReceiveState) {
        guard receive.expiryTask == nil else { return }
        let expiry = timing.unclaimedReceiveExpiry
        receive.expiryTask = Task { [weak self] in
            try? await Task.sleep(for: expiry)
            guard !Task.isCancelled, let self else { return }
            unclaimedReceiveExpired(sid: sid)
        }
    }

    private func unclaimedReceiveExpired(sid: String) {
        let (context, peerEnd) = state.withLock { ($0.context, $0.resources[sid]?.receive?.peerEnd) }
        guard let context else { return }
        let terminateReason: JingleTerminateReason? = peerEnd == .terminatedSuccess ? nil : .timeout
        abandonTransport(sid: sid, reason: .timeout, terminateReason: terminateReason, context: context) { state in
            state.resources[sid]?.receive?.isClaimed == false
        }
    }

    // MARK: - Public API

    /// Waits until the transport is ready for data transfer (SOCKS5 connected or IBB established). Given `offerID`, it waits
    /// only on the session of that offer, so a later session reusing the sid is not mistaken for it.
    public func awaitTransportReady(sid: String, offerID: String? = nil) async throws {
        try await withCheckedThrowingContinuation { continuation in
            // A wait for a session that no longer exists fails at once instead of hanging. A second wait fails instead of
            // displacing the first one's continuation.
            let readiness = state.withLock { state -> Result<Bool, JingleError> in
                guard Self.session(sid, offerID: offerID, in: state) != nil else { return .failure(.sessionNotFound) }
                if Self.isTransportReady(sid: sid, in: state) { return .success(true) }
                guard state.resources[sid]?.transportWait == nil else {
                    return .failure(.transportFailed("The transfer is already waiting for a connection"))
                }
                state.resources[sid]?.transportWait = continuation
                return .success(false)
            }
            switch readiness {
            case .success(true): continuation.resume()
            case .success(false): break
            case let .failure(error): continuation.resume(throwing: error)
            }
        }
    }

    /// Whether data can flow: a SOCKS5 connection is up, or an IBB stream is set up that the peer is not still being asked
    /// to accept.
    private static func isTransportReady(sid: String, in state: State) -> Bool {
        guard let session = state.resources[sid]?.session else { return false }
        switch session.transportState {
        case .connected:
            return true
        case .replacePending:
            return false
        case .pending, .connecting, .failed:
            return state.resources[sid]?.ibb != nil
        }
    }

    /// Offers `file` to the given peer and returns the session ID once the peer acknowledged the offer. When the peer
    /// rejects the offer, the session ends and the rejection is thrown.
    public func initiateFileTransfer(to peer: FullJID, file: JingleFileDescription) async throws -> String {
        guard let context = state.withLock({ $0.context }) else {
            throw JingleError.notConnected
        }

        guard let myJID = context.connectedJID() else {
            throw JingleError.noConnectedJID
        }

        let sid = Self.makeStreamID()
        let offerID = makeOfferID()
        state.withLock { $0.resources[sid] = SessionResources(offerID: offerID) }
        return try await withTaskCancellationHandler {
            do {
                return try await prepareFileTransfer(to: peer, file: file, preparation: (sid, offerID), myJID: myJID, context: context)
            } catch {
                if let resources = detachPreparation(sid: sid, offerID: offerID) {
                    resources.continuations.cancel(with: error)
                    await resources.closeTransport()
                }
                throw error
            }
        } onCancel: {
            self.detachPreparation(sid: sid, offerID: offerID)?.cancel(with: CancellationError())
        }
    }

    private func detachPreparation(sid: String, offerID: String) -> SessionResources? {
        state.withLock { state in
            guard state.resources[sid]?.offerID == offerID else { return nil }
            return detachSessionResources(sid: sid, state: &state)
        }
    }

    private func prepareFileTransfer(
        to peer: FullJID, file: JingleFileDescription, preparation: (sid: String, offerID: String), myJID: FullJID, context: ModuleContext
    ) async throws -> String {
        let (sid, offerID) = preparation
        let transportSID = Self.makeStreamID()
        let candidates = try await buildCandidates(sid: sid, offerID: offerID, context: context)

        let transport = JingleTransportDescription.socks5(SOCKS5Transport(sid: transportSID, candidates: candidates))
        let content = JingleContent(
            name: "a-file-offer",
            creator: "initiator",
            senders: .initiator,
            description: file,
            transport: transport
        )

        let session = JingleSession(peer: peer, role: .initiator, content: content)
        try Task.checkCancellation()
        let attached = state.withLock { state in
            guard state.resources[sid]?.offerID == offerID else { return false }
            Self.addSession(session, sid: sid, state: &state)
            return true
        }
        guard attached else { throw JingleError.sessionNotFound }

        var iq = XMPPIQ(type: .set, to: .full(peer), id: context.generateID())
        var jingle = XMLElement(
            name: "jingle",
            namespace: XMPPNamespaces.jingle,
            attributes: [
                "action": JingleAction.sessionInitiate.rawValue,
                "initiator": myJID.description,
                "sid": sid
            ]
        )
        jingle.addChild(content.toXML())
        iq.element.addChild(jingle)

        try await sendJingleIQ(iq, context: context, failure: JingleError.transportNegotiationFailed)
        try Task.checkCancellation()
        guard state.withLock({ $0.resources[sid]?.offerID == offerID }) else { throw JingleError.sessionNotFound }
        return sid
    }

    /// A random session or stream ID. The clients of one account each count their own IDs, so a peer that tells sessions
    /// apart by ID alone would see counted IDs collide.
    private static func makeStreamID() -> String {
        hexString((0 ..< 16).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// Accepts a pending incoming file transfer. Given `offerID`, it accepts only the session of that offer, so an accept
    /// the user gave one offer cannot take a later one that reused its sid.
    public func acceptFileTransfer(sid: String, offerID: String? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else { throw JingleError.notConnected }
        guard let myJID = context.connectedJID() else {
            throw JingleError.noConnectedJID
        }

        let session = try claimAcceptance(sid: sid, offerID: offerID)

        var iq = XMPPIQ(type: .set, to: .full(session.peer), id: context.generateID())
        var jingle = XMLElement(
            name: "jingle",
            namespace: XMPPNamespaces.jingle,
            attributes: [
                "action": JingleAction.sessionAccept.rawValue,
                "responder": myJID.description,
                "sid": sid
            ]
        )
        jingle.addChild(Self.acceptedContent(from: session.content).toXML())
        iq.element.addChild(jingle)

        do {
            try await context.sendStanza(iq)
        } catch {
            // Only this session's own acceptance is rolled back: a sid freed and re-offered while the send was in
            // flight belongs to a later session, and this failure says nothing about whether that one was accepted.
            state.withLock { state in
                guard state.resources[sid]?.session?.offerID == session.offerID else { return }
                state.resources[sid]?.session?.isAccepted = false
            }
            throw error
        }

        // Responder begins transport connection after sending session-accept
        Task { await beginTransportConnection(sid: sid, context: context) }
    }

    /// The content to echo back in a session-accept. XEP-0260 §2.2 forbids the responder from offering any host and port
    /// the initiator already offered, so the initiator's candidate list is dropped while the transport's stream id and
    /// the file description are echoed unchanged. This side dials rather than listening, so it advertises none of its
    /// own in their place.
    private static func acceptedContent(from content: JingleContent) -> JingleContent {
        guard case let .socks5(transport) = content.transport, !transport.candidates.isEmpty else { return content }
        return JingleContent(
            name: content.name, creator: content.creator, senders: content.senders,
            description: content.description, transport: .socks5(SOCKS5Transport(sid: transport.sid))
        )
    }

    /// Must run before `acceptFileTransfer` first suspends, so a concurrent repeated accept can't send a second
    /// session-accept.
    private func claimAcceptance(sid: String, offerID: String?) throws -> JingleSession {
        let claim = state.withLock { state -> Result<JingleSession, JingleError> in
            guard let session = Self.session(sid, offerID: offerID, in: state) else { return .failure(.sessionNotFound) }
            guard !session.isAccepted else { return .failure(.alreadyAccepted) }
            state.resources[sid]?.session?.isAccepted = true
            return .success(session)
        }
        return try claim.get()
    }

    /// Sends a `session-info` IQ with `<received/>` per XEP-0234 §5.1 after file reception.
    private func sendReceivedSessionInfo(sid: String, peer: FullJID, content: JingleContent, context: ModuleContext) async throws {
        var iq = XMPPIQ(type: .set, to: .full(peer), id: context.generateID())
        var jingle = XMLElement(
            name: "jingle",
            namespace: XMPPNamespaces.jingle,
            attributes: [
                "action": JingleAction.sessionInfo.rawValue,
                "sid": sid
            ]
        )
        jingle.addChild(XMLElement(
            name: "received",
            namespace: XMPPNamespaces.jingleFileTransfer,
            attributes: ["creator": content.creator, "name": content.name]
        ))
        iq.element.addChild(jingle)

        try await context.sendStanza(iq)
    }

    static func verifyChecksum(_ info: JingleChecksumInfo, data: [UInt8]) -> ChecksumResult {
        guard info.algo == "sha-256" else { return .unsupportedAlgorithm(info.algo) }
        let computed = JingleFileDescription.sha256Hash(of: data)
        return computed == info.hash ? .verified : .mismatch(expected: info.hash, computed: computed)
    }

    /// Declines a pending incoming file transfer. Given `offerID`, it declines only the session of that offer.
    public func declineFileTransfer(sid: String, offerID: String? = nil) async throws {
        try await terminateSession(sid: sid, reason: .decline, offerID: offerID)
    }

    /// Terminates a Jingle session with the given reason. A transfer waiting on the session fails with `sessionNotFound`,
    /// and no event is emitted. Given `offerID`, it ends only the session of that offer.
    public func terminateSession(sid: String, reason: JingleTerminateReason, offerID: String? = nil) async throws {
        let (context, snapshot) = state.withLock { state -> (ModuleContext?, TerminateSnapshot?) in
            guard let session = Self.session(sid, offerID: offerID, in: state) else { return (state.context, nil) }
            guard let resources = detachSessionResources(sid: sid, state: &state) else { return (state.context, nil) }
            return (state.context, TerminateSnapshot(session: session, resources: resources))
        }
        guard let context else { throw JingleError.notConnected }
        guard let snapshot else { throw JingleError.sessionNotFound }

        snapshot.resources.continuations.cancel(with: JingleError.sessionNotFound)
        await snapshot.resources.closeTransport()

        try await sendSessionTerminate(sid: sid, peer: snapshot.session.peer, reason: reason, context: context)
    }

    private func sendSessionTerminate(sid: String, peer: FullJID, reason: JingleTerminateReason, context: ModuleContext) async throws {
        var iq = XMPPIQ(type: .set, to: .full(peer), id: context.generateID())
        var jingle = XMLElement(
            name: "jingle",
            namespace: XMPPNamespaces.jingle,
            attributes: [
                "action": JingleAction.sessionTerminate.rawValue,
                "sid": sid
            ]
        )

        var reasonElement = XMLElement(name: "reason")
        reasonElement.addChild(XMLElement(name: reason.rawValue))
        jingle.addChild(reasonElement)
        iq.element.addChild(jingle)

        try await context.sendStanza(iq)
    }

    // MARK: - File Data Transfer

    /// Sends file data over the established transport (SOCKS5 or IBB) for a session.
    /// Returns once the receiver confirmed the data or the confirmation wait elapsed.
    public func sendFileData(sid: String, data: [UInt8]) async throws {
        let start = state.withLock { state -> Result<SendStart, JingleError> in
            guard let context = state.context else { return .failure(.notConnected) }
            guard state.resources[sid]?.session != nil else { return .failure(.sessionNotFound) }
            // An unnominated connection or an IBB switch the peer has not accepted carries nothing yet.
            guard Self.isTransportReady(sid: sid, in: state) else {
                return .failure(.transportFailed("No connection is open for the transfer"))
            }
            let connection = state.resources[sid]?.connection
            let ibbState = state.resources[sid]?.ibb
            // Recording starts before the first byte, so a confirmation that arrives mid-write is kept.
            state.resources[sid]?.send = SendState(transport: connection == nil ? .ibb : .socks5)
            return .success(SendStart(context: context, connection: connection, ibbState: ibbState))
        }
        let started = try start.get()

        var writeError: (any Error)?
        do {
            if let connection = started.connection {
                try await sendSOCKS5Data(sid: sid, data: data, connection: connection, context: started.context)
            } else if let ibbState = started.ibbState {
                try await sendIBBData(sid: sid, data: data, ibbState: ibbState, context: started.context)
            }
        } catch {
            writeError = error
        }

        try await finishSend(sid: sid, writeError: writeError, context: started.context)
    }

    /// Commits, returns from, or fails a send whose bytes were written or whose write threw.
    private func finishSend(sid: String, writeError: (any Error)?, context: ModuleContext) async throws {
        let deadline = ContinuousClock.now + timing.senderConfirmationWait
        var end = resolveSendEnd(sid: sid, writeError: writeError, releasesOwner: false)
        if case .unconfirmed = end {
            do {
                try await awaitSendConfirmation(sid: sid, until: deadline)
            } catch {
                state.withLock { $0.resources[sid]?.send?.isOwnerActive = false }
                throw error
            }
            end = resolveSendEnd(sid: sid, writeError: nil, releasesOwner: true)
        }

        switch end {
        case let .committed(transport, resources):
            resources.cancel(with: JingleError.sessionNotFound)
            context.emitEvent(.jingleFileTransferCompleted(sid: sid, transport: transport))
        case .confirmed:
            // The receiver normally ends the session itself; end it once the wait elapses if it hasn't.
            let cleanup = Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard !Task.isCancelled else { return }
                try? await self?.terminateSession(sid: sid, reason: .success)
            }
            let isLive = state.withLock { state -> Bool in
                guard state.resources[sid]?.send != nil else { return false }
                state.resources[sid]?.send?.cleanupTask = cleanup
                return true
            }
            if !isLive { cleanup.cancel() }
        case let .failed(error):
            throw error
        case let .abandoned(error, resources):
            // Reported like any other failed session, and the peer is told rather than left waiting for the rest.
            endAbandonedSession(sid: sid, resources: resources, reason: .incomplete, terminateReason: .failedTransport, context: context)
            throw error
        case .unconfirmed:
            try? await terminateSession(sid: sid, reason: .success)
        }
    }

    /// Resolves a send's end under the lock. `.unconfirmed` keeps the owner active unless `releasesOwner` is set.
    private func resolveSendEnd(sid: String, writeError: (any Error)?, releasesOwner: Bool) -> SendEnd {
        state.withLock { state -> SendEnd in
            guard state.resources[sid]?.session != nil, var send = state.resources[sid]?.send else {
                return .failed(writeError ?? JingleError.sessionNotFound)
            }
            switch send.confirmation {
            case .terminatedSuccess:
                guard let resources = detachSessionResources(sid: sid, state: &state) else { return .failed(JingleError.sessionNotFound) }
                return .committed(send.transport, resources)
            case .received:
                // The receiver already has every byte, so a write that failed afterwards changes nothing.
                send.isOwnerActive = false
                state.resources[sid]?.send = send
                return .confirmed
            case nil:
                // A write that failed before the receiver confirmed leaves nothing to carry on with. The session goes in the
                // same critical section, so neither a later session under the sid nor a peer's end can slip in between.
                if let writeError {
                    guard let resources = detachSessionResources(sid: sid, state: &state) else { return .failed(writeError) }
                    return .abandoned(writeError, resources)
                }
                if releasesOwner {
                    send.isOwnerActive = false
                    state.resources[sid]?.send = send
                }
                return .unconfirmed
            }
        }
    }

    /// Waits until the receiver confirms the send or `deadline` passes. Throws when the session is torn down meanwhile.
    private func awaitSendConfirmation(sid: String, until deadline: ContinuousClock.Instant) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let registration = state.withLock { state -> WaitRegistration in
                guard state.resources[sid]?.session != nil, let send = state.resources[sid]?.send else { return .gone }
                guard send.confirmation == nil else { return .ready }
                state.resources[sid]?.send?.wait = continuation
                return .waiting
            }
            switch registration {
            case .gone:
                continuation.resume(throwing: JingleError.sessionNotFound)
            case .ready:
                continuation.resume()
            case .waiting:
                Task { [weak self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    let wait = self?.state.withLock { state -> CheckedContinuation<Void, Error>? in
                        let wait = state.resources[sid]?.send?.wait
                        state.resources[sid]?.send?.wait = nil
                        return wait
                    }
                    wait?.resume()
                }
            }
        }
    }

    func sendSOCKS5Data(
        sid: String, data: [UInt8], connection: SOCKS5Connection, context: ModuleContext
    ) async throws {
        let totalBytes = Int64(data.count)
        let chunkSize = 4096
        var offset = 0

        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = Array(data[offset ..< end])
            do {
                try await connection.send(chunk, stallTimeout: timing.sendStallWait)
            } catch let error as SOCKS5Connection.SOCKS5Error {
                throw JingleError.transportFailed(error.displayText)
            }
            offset = end
            let transferred = Int64(offset)
            context.emitEvent(.jingleFileTransferProgress(sid: sid, bytesTransferred: transferred, totalBytes: totalBytes))
        }
    }

    private func sendIBBData(
        sid: String, data: [UInt8], ibbState: IBBSessionState, context: ModuleContext
    ) async throws {
        let session = state.withLock { $0.resources[sid]?.session }
        guard let session else { throw JingleError.sessionNotFound }

        // Send IBB open handshake if not yet sent
        let needsOpen = state.withLock { !($0.resources[sid]?.ibb?.hasOpened ?? true) }
        if needsOpen {
            try await sendIBBOpen(
                ibbSID: ibbState.ibbSID, blockSize: ibbState.blockSize,
                peer: session.peer, context: context
            )
            state.withLock { $0.resources[sid]?.ibb?.hasOpened = true }
        }

        let totalBytes = Int64(data.count)
        let blockSize = ibbState.blockSize
        var offset = 0
        var seq: UInt16 = 0

        while offset < data.count {
            let end = min(offset + blockSize, data.count)
            let chunk = Array(data[offset ..< end])
            try await sendIBBChunk(
                ibbSID: ibbState.ibbSID, seq: seq, chunk: chunk,
                peer: session.peer, context: context
            )
            offset = end
            seq &+= 1
            let transferred = Int64(offset)
            context.emitEvent(.jingleFileTransferProgress(sid: sid, bytesTransferred: transferred, totalBytes: totalBytes))
        }

        // Every block was acknowledged, so the receiver holds the file whether or not the close reaches it. Its
        // confirmation, not the close, decides how the send ends.
        do {
            try await sendIBBClose(ibbSID: ibbState.ibbSID, peer: session.peer, context: context)
        } catch {
            log.debug("IBB close failed after every block was acknowledged, sid: \(sid): \(error)")
        }
    }

    private func sendIBBOpen(
        ibbSID: String, blockSize: Int,
        peer: FullJID, context: ModuleContext
    ) async throws {
        var iq = XMPPIQ(type: .set, to: .full(peer), id: context.generateID())
        let open = XMLElement(
            name: "open",
            namespace: XMPPNamespaces.ibb,
            attributes: ["sid": ibbSID, "block-size": String(blockSize), "stanza": "iq"]
        )
        iq.element.addChild(open)
        try await sendJingleIQ(iq, context: context, failure: JingleError.transportFailed)
    }

    private func sendIBBClose(
        ibbSID: String,
        peer: FullJID, context: ModuleContext
    ) async throws {
        var iq = XMPPIQ(type: .set, to: .full(peer), id: context.generateID())
        let close = XMLElement(
            name: "close",
            namespace: XMPPNamespaces.ibb,
            attributes: ["sid": ibbSID]
        )
        iq.element.addChild(close)
        try await sendJingleIQ(iq, context: context, failure: JingleError.transportFailed)
    }

    private func sendIBBChunk(
        ibbSID: String, seq: UInt16, chunk: [UInt8],
        peer: FullJID, context: ModuleContext
    ) async throws {
        var iq = XMPPIQ(type: .set, to: .full(peer), id: context.generateID())
        var dataElement = XMLElement(
            name: "data",
            namespace: XMPPNamespaces.ibb,
            attributes: ["sid": ibbSID, "seq": String(seq)]
        )
        dataElement.addText(Base64.encode(chunk))
        iq.element.addChild(dataElement)
        try await sendJingleIQ(iq, context: context, failure: JingleError.transportFailed)
    }

    /// Sends an IQ, reporting a failed exchange as the `JingleError` that `failure` makes from its readable detail.
    func sendJingleIQ(_ iq: XMPPIQ, context: ModuleContext, failure: (String) -> JingleError) async throws {
        do {
            _ = try await context.sendIQ(iq)
        } catch let error as XMPPStanzaError {
            throw failure(error.displayText)
        } catch XMPPClientError.notConnected {
            throw JingleError.notConnected
        } catch let XMPPClientError.sendFailed(reason) {
            throw failure(reason)
        } catch XMPPClientError.timeout {
            throw failure("The contact did not respond in time")
        }
    }

    /// Receives file data over the established transport (SOCKS5 or IBB) for a session, and returns it once every expected
    /// byte arrived intact. A short or corrupted receive fails the transfer and throws. Given `offerID`, it receives only
    /// the session of that offer.
    public func receiveFileData(sid: String, offerID: String? = nil) async throws -> [UInt8] {
        let claim = try claimReceive(sid: sid, offerID: offerID)
        claim.expiryTask?.cancel()

        switch claim.transport {
        case let .socks5(connection):
            // The read throws only before the full count, so a failed read has no bytes worth keeping.
            let data = await (try? receiveSOCKS5Data(sid: sid, expectedSize: claim.expectedSize, connection: connection, context: claim.context)) ?? []
            return try await finalizeReceive(sid: sid, offerID: claim.offerID, socks5Data: data, context: claim.context)
        case .ibb:
            try await awaitIBBEnd(sid: sid)
            return try await finalizeReceive(sid: sid, offerID: claim.offerID, socks5Data: nil, context: claim.context)
        }
    }

    /// Claims the receive for the calling task, which from then on alone commits its successful end.
    private func claimReceive(sid: String, offerID: String?) throws -> ReceiveClaim {
        let claim = state.withLock { state -> Result<ReceiveClaim, JingleError> in
            guard let context = state.context else { return .failure(.notConnected) }
            guard let session = Self.session(sid, offerID: offerID, in: state), var receive = state.resources[sid]?.receive else { return .failure(.sessionNotFound) }
            guard receive.expectedSize > 0 else { return .failure(.transportFailed("The file size is invalid")) }
            guard !receive.isClaimed else { return .failure(.transportFailed("The transfer is already being received")) }

            let transport: ReceiveTransport
            if let connection = state.resources[sid]?.connection {
                transport = .socks5(connection)
            } else if state.resources[sid]?.ibb != nil {
                transport = .ibb
            } else {
                return .failure(.transportFailed("No connection is open for the transfer"))
            }

            receive.isClaimed = true
            let expiryTask = receive.expiryTask
            receive.expiryTask = nil
            if case .socks5 = transport, receive.peerEnd == .terminatedSuccess {
                armEndOfStream(sid: sid, receive: &receive)
            }
            state.resources[sid]?.receive = receive
            return .success(ReceiveClaim(
                context: context, expectedSize: receive.expectedSize, transport: transport,
                expiryTask: expiryTask, offerID: session.offerID
            ))
        }
        return try claim.get()
    }

    /// Waits until a claimed IBB receive's stream ended or its end-of-stream wait elapsed.
    private func awaitIBBEnd(sid: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let registration = state.withLock { state -> WaitRegistration in
                guard state.resources[sid]?.session != nil, var receive = state.resources[sid]?.receive else { return .gone }
                guard receive.peerEnd == nil else { return .ready }
                receive.wake = continuation
                if Int64(state.resources[sid]?.ibb?.receivedData.count ?? 0) >= receive.expectedSize {
                    armEndOfStream(sid: sid, receive: &receive)
                }
                state.resources[sid]?.receive = receive
                return .waiting
            }
            switch registration {
            case .gone:
                continuation.resume(throwing: JingleError.sessionNotFound)
            case .ready:
                continuation.resume()
            case .waiting:
                break
            }
        }
    }

    /// Verifies a claimed receive and commits its end. `socks5Data` holds a SOCKS5 read's bytes; `nil` reads the IBB
    /// buffer. `offerID` binds the commit to the session the claim was taken against.
    private func finalizeReceive(sid: String, offerID: String, socks5Data: [UInt8]?, context: ModuleContext) async throws -> [UInt8] {
        let captured = state.withLock { state -> (data: [UInt8], receive: ReceiveState)? in
            guard state.resources[sid]?.session?.offerID == offerID, let receive = state.resources[sid]?.receive else { return nil }
            return (socks5Data ?? state.resources[sid]?.ibb?.receivedData ?? [], receive)
        }
        guard let captured else { throw JingleError.sessionNotFound }

        let failure = try await verifyReceivedData(sid: sid, offerID: offerID, data: captured.data, receive: captured.receive)

        let committed = state.withLock { state -> CommittedReceive? in
            guard state.resources[sid]?.session?.offerID == offerID,
                  let resources = detachSessionResources(sid: sid, state: &state), let session = resources.session else { return nil }
            let peerEnd = resources.receive?.peerEnd
            return CommittedReceive(
                peer: session.peer, content: session.content, peerEnd: peerEnd,
                resources: resources
            )
        }
        guard let committed else { throw JingleError.sessionNotFound }
        committed.resources.cancel(with: JingleError.sessionNotFound)
        let peer = committed.peer
        let peerTerminated = committed.peerEnd == .terminatedSuccess

        if let failure {
            context.emitEvent(.jingleFileTransferFailed(sid: sid, reason: failure))
            if !peerTerminated {
                Task {
                    do {
                        try await sendSessionTerminate(sid: sid, peer: peer, reason: .cancel, context: context)
                    } catch {
                        log.warning("Failed to send session-terminate for a failed receive: \(error)")
                    }
                }
            }
            throw JingleError.transportFailed(failure.displayText)
        }

        context.emitEvent(.jingleFileTransferCompleted(sid: sid, transport: socks5Data == nil ? .ibb : .socks5))
        Task {
            do {
                try await sendReceivedSessionInfo(sid: sid, peer: peer, content: committed.content, context: context)
            } catch {
                log.warning("Failed to send received session-info: \(error)")
            }
            guard !peerTerminated else { return }
            do {
                try await sendSessionTerminate(sid: sid, peer: peer, reason: .success, context: context)
            } catch {
                log.warning("Failed to send session-terminate for a completed receive: \(error)")
            }
        }
        return captured.data
    }

    /// The failure a receive's bytes amount to, or `nil` when they arrived intact or cannot be verified. Throws when the
    /// session ended while waiting for a promised checksum, so a torn-down receive is not read as one that simply
    /// arrived without a checksum to verify against.
    private func verifyReceivedData(
        sid: String, offerID: String, data: [UInt8], receive: ReceiveState
    ) async throws -> JingleTransferFailureReason? {
        guard Int64(data.count) == receive.expectedSize else { return .incomplete }

        var checksum = receive.sessionInfoChecksum ?? receive.offeredChecksum
        if checksum == nil, receive.checksumPromised {
            checksum = try await awaitPromisedChecksum(sid: sid, offerID: offerID)
        }
        guard let checksum else {
            log.debug("Completing a receive without a checksum to verify, sid: \(sid)")
            return nil
        }

        switch Self.verifyChecksum(checksum, data: data) {
        case .verified:
            return nil
        case .mismatch:
            return .checksumMismatch
        case let .unsupportedAlgorithm(algo):
            log.debug("Completing a receive unverified, unsupported hash algorithm \(algo), sid: \(sid)")
            return nil
        }
    }

    /// Waits up to the checksum wait for a checksum the offer promised, returning it if it arrived. Throws when the
    /// session ended while waiting.
    private func awaitPromisedChecksum(sid: String, offerID: String) async throws -> JingleChecksumInfo? {
        let wait = timing.checksumWait
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let registration = state.withLock { state -> WaitRegistration in
                guard state.resources[sid]?.session?.offerID == offerID, let receive = state.resources[sid]?.receive else { return .gone }
                guard receive.sessionInfoChecksum == nil else { return .ready }
                state.resources[sid]?.receive?.checksumWait = continuation
                return .waiting
            }
            switch registration {
            case .gone:
                continuation.resume(throwing: JingleError.sessionNotFound)
            case .ready:
                continuation.resume()
            case .waiting:
                Task { [weak self] in
                    try? await Task.sleep(for: wait)
                    // The timer outlives an ended session, so it only releases the wait of the session that started it.
                    let checksumWait = self?.state.withLock { state -> CheckedContinuation<Void, Error>? in
                        guard state.resources[sid]?.session?.offerID == offerID else { return nil }
                        let checksumWait = state.resources[sid]?.receive?.checksumWait
                        state.resources[sid]?.receive?.checksumWait = nil
                        return checksumWait
                    }
                    checksumWait?.resume()
                }
            }
        }
        return state.withLock { $0.resources[sid]?.receive?.sessionInfoChecksum }
    }

    func receiveSOCKS5Data(
        sid: String, expectedSize: Int64, connection: SOCKS5Connection, context: ModuleContext
    ) async throws -> [UInt8] {
        var received: [UInt8] = []
        let chunkSize = 4096
        let total = Int(expectedSize)
        // Reserve for a modest file and let a larger one grow as it arrives, rather than turning the size the peer
        // declared into one allocation.
        received.reserveCapacity(min(total, 8 * 1024 * 1024))

        while received.count < total {
            let remaining = total - received.count
            let toRead = min(chunkSize, remaining)
            let chunk: [UInt8]
            do {
                chunk = try await connection.receive(toRead, stallTimeout: timing.receiveStallWait)
            } catch let error as SOCKS5Connection.SOCKS5Error {
                throw JingleError.transportFailed(error.displayText)
            }
            received.append(contentsOf: chunk)
            let transferred = Int64(received.count)
            context.emitEvent(.jingleFileTransferProgress(sid: sid, bytesTransferred: transferred, totalBytes: expectedSize))
        }

        return received
    }

    // MARK: - Transport Connection Orchestration

    private func beginTransportConnection(sid: String, context: ModuleContext) async {
        let (session, listener) = state.withLock { state -> (JingleSession?, SOCKS5Listener?) in
            guard let session = state.resources[sid]?.session, Self.acceptsSOCKS5Outcome(session), !session.isTransportAttemptStarted else {
                return (nil, nil)
            }
            state.resources[sid]?.session?.isTransportAttemptStarted = true
            state.resources[sid]?.session?.transportState = .connecting
            let listener = state.resources[sid]?.listener
            return (session, listener)
        }
        guard let session else { return }

        let dstAddr = computeDestinationAddress(session: session)

        // An initiator only waits on its own listener and leaves an unreachable peer to the IBB fallback: dialing the
        // candidates a responder advertises needs its own responder-first address and activation handling, which
        // nothing here verifies. A responder dials the candidates the initiator offered.
        switch session.role {
        case .initiator:
            if let listener {
                defer { cleanupListener(sid: sid) }
                if let result = await awaitListenerConnection(listener, dstAddr: dstAddr) {
                    handleConnectionSuccess(sid: sid, result: result, session: session, context: context)
                    return
                }
            }
        case .responder:
            if case let .socks5(transport) = session.content.transport, !transport.candidates.isEmpty,
               let result = await tryConnectCandidates(transport.candidates.sorted { $0.priority > $1.priority }, dstAddr: dstAddr) {
                handleConnectionSuccess(sid: sid, result: result, session: session, context: context)
                return
            }
        }
        sendCandidateError(sid: sid, session: session, context: context)
    }

    private func awaitListenerConnection(
        _ listener: SOCKS5Listener,
        dstAddr: String
    ) async -> (connection: SOCKS5Connection, cid: String)? {
        do {
            let connection = try await listener.accept(expectedDstAddr: dstAddr)
            return (connection, Self.listenerCID)
        } catch {
            log.debug("Listener accept failed: \(error)")
            return nil
        }
    }

    private func cleanupTransport(sid: String) {
        let (connections, pending, listener) = state.withLock { state in
            let connection = state.resources[sid]?.connection
            state.resources[sid]?.connection = nil
            let connections = [connection, state.resources[sid]?.takePendingDirect()].compactMap(\.self)
            return (connections, state.resources[sid]?.takePendingProxy(), state.resources[sid]?.takeListener())
        }
        for connection in connections {
            Task { await connection.close() }
        }
        if let pending {
            Task { await pending.connection.close() }
        }
        if let listener {
            Task { await listener.close() }
        }
    }

    /// Drops a proxy socket that never became live, leaving the session, its receive state and its transport waiter in
    /// place so the peer's transport-replace can still switch this transfer to IBB.
    private func releasePendingProxy(sid: String) {
        let pending = state.withLock { $0.resources[sid]?.takePendingProxy() }
        if let pending {
            Task { await pending.connection.close() }
        }
    }

    private func cleanupListener(sid: String) {
        let listener = state.withLock { $0.resources[sid]?.takeListener() }
        if let listener {
            Task { await listener.close() }
        }
    }

    private func computeDestinationAddress(session: JingleSession) -> String {
        guard case let .socks5(transport) = session.content.transport else { return "" }
        let myJID = state.withLock { $0.context?.connectedJID()?.description ?? "" }
        let initiatorJID: String
        let targetJID: String
        switch session.role {
        case .initiator:
            initiatorJID = myJID
            targetJID = session.peer.description
        case .responder:
            initiatorJID = session.peer.description
            targetJID = myJID
        }
        return SOCKS5Connection.destinationAddress(sid: transport.sid, initiatorJID: initiatorJID, targetJID: targetJID)
    }

    private func tryConnectCandidates(
        _ candidates: [SOCKS5Transport.Candidate],
        dstAddr: String
    ) async -> (connection: SOCKS5Connection, cid: String)? {
        for candidate in candidates {
            let connection = SOCKS5Connection()
            do {
                // A proxy is optional, so a dial to one is bounded: waiting out the socket's own default would hold up
                // every candidate behind it and the IBB fallback after those.
                if case .proxy = candidate.type {
                    try await connection.connect(
                        host: candidate.host, port: candidate.port, destinationAddress: dstAddr,
                        timeout: Self.seconds(timing.proxyConnectWait)
                    )
                } else {
                    try await connection.connect(host: candidate.host, port: candidate.port, destinationAddress: dstAddr)
                }
                return (connection, candidate.cid)
            } catch {
                log.debug("SOCKS5 candidate \(candidate.cid) failed: \(error)")
                await connection.close()
            }
        }
        return nil
    }

    private func handleConnectionSuccess(
        sid: String,
        result: (connection: SOCKS5Connection, cid: String),
        session: JingleSession,
        context: ModuleContext
    ) {
        // A proxy bytestream carries nothing until the offering side activates it (XEP-0260 §2.4), so its socket waits
        // where no transport wait and no claim can take it, and goes live only on the peer's `<activated/>`.
        let isProxy = Self.isProxyCandidate(cid: result.cid, in: session)
        let (isCurrent, continuation) = state.withLock { state -> (Bool, CheckedContinuation<Void, Error>?) in
            // A transport already in place owns the session, including a nominated proxy still awaiting activation. An
            // attempt that finishes after it closes its own connection instead of replacing that one.
            guard Self.socks5OutcomeOpen(sid: sid, offerID: session.offerID, in: state) else { return (false, nil) }
            guard !isProxy else {
                state.resources[sid]?.pendingProxy = PendingProxy(connection: result.connection, cid: result.cid)
                return (true, nil)
            }
            // This side's listener was reached, but only the peer's candidate-used makes that connection the transport.
            guard session.role == .responder else {
                state.resources[sid]?.pendingDirect = result.connection
                return (true, Self.promoteNominatedDirect(sid: sid, state: &state))
            }
            return (true, Self.publishSOCKS5(result.connection, cid: result.cid, sid: sid, state: &state))
        }
        guard isCurrent else {
            Task { await result.connection.close() }
            return
        }
        continuation?.resume()
        switch session.role {
        case .responder:
            sendCandidateUsed(sid: sid, cid: result.cid, session: session, context: context)
        case .initiator:
            // The peer reached this side's listener, but this side dials none of the peer's candidates, and XEP-0260 §2.3
            // has it report that without waiting for the nomination. The peer's candidate-used still nominates the listener
            // (§2.4); a peer that settles the nomination only once both reports are in would otherwise wait on this one.
            sendTransportInfo(sid: sid, session: session, context: context, transportChild: XMLElement(name: "candidate-error"))
        }
    }

    private func sendCandidateUsed(sid: String, cid: String, session: JingleSession, context: ModuleContext) {
        sendTransportInfo(sid: sid, session: session, context: context,
                          transportChild: XMLElement(name: "candidate-used", attributes: ["cid": cid]))
    }

    private func sendCandidateError(sid: String, session: JingleSession, context: ModuleContext) {
        let isCurrent = state.withLock { state -> Bool in
            // A listener that times out after the peer's nominated proxy went live is not a failed transfer, and a dial for a
            // session that ended says nothing about a later one reusing its sid.
            guard Self.socks5OutcomeOpen(sid: sid, offerID: session.offerID, in: state) else { return false }
            state.resources[sid]?.session?.transportState = .failed
            return true
        }
        guard isCurrent else {
            log.debug("Ignoring stale SOCKS5 failure for sid: \(sid)")
            return
        }
        sendTransportInfo(sid: sid, session: session, context: context,
                          transportChild: XMLElement(name: "candidate-error"))
    }

    private func sendTransportInfo(sid: String, session: JingleSession, context: ModuleContext, transportChild: XMLElement) {
        guard case let .socks5(transport) = session.content.transport else { return }
        Task {
            var iq = XMPPIQ(type: .set, to: .full(session.peer), id: context.generateID())
            var jingle = XMLElement(
                name: "jingle",
                namespace: XMPPNamespaces.jingle,
                attributes: ["action": JingleAction.transportInfo.rawValue, "sid": sid]
            )
            var transportElement = XMLElement(name: "transport", namespace: XMPPNamespaces.jingleS5B, attributes: ["sid": transport.sid])
            transportElement.addChild(transportChild)
            var content = XMLElement(name: "content", attributes: ["creator": session.content.creator, "name": session.content.name])
            content.addChild(transportElement)
            jingle.addChild(content)
            iq.element.addChild(jingle)
            do {
                try await context.sendStanza(iq)
            } catch {
                log.warning("Failed to send transport-info: \(error)")
            }
        }
    }

    // MARK: - Proxy65 Discovery

    private func discoverProxy65(context: ModuleContext) async throws -> ProxyInfo? {
        let cached = state.withLock { $0.cachedProxy65 }
        if let cached { return cached }

        let items = try await queryDiscoItems(context: context)

        for item in items {
            let features = try? await queryDiscoFeatures(for: item, context: context)
            guard let features, features.contains(XMPPNamespaces.bytestreams) else { continue }

            if let proxy = try? await queryStreamhost(jid: item, context: context) {
                state.withLock { $0.cachedProxy65 = proxy }
                log.info("Discovered Proxy65: \(proxy.jid) at \(proxy.host):\(proxy.port)")
                return proxy
            }
        }

        return nil
    }

    private func queryDiscoItems(context: ModuleContext) async throws -> [String] {
        guard let domainJID = JID.parse(context.domain) else { return [] }

        var iq = XMPPIQ(type: .get, to: domainJID, id: context.generateID())
        let query = XMLElement(name: "query", namespace: XMPPNamespaces.discoItems)
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else { return [] }

        return result.children(named: "item").compactMap { $0.attribute("jid") }
    }

    private func queryDiscoFeatures(for jid: String, context: ModuleContext) async throws -> Set<String> {
        guard let targetJID = JID.parse(jid) else { return [] }

        var iq = XMPPIQ(type: .get, to: targetJID, id: context.generateID())
        let query = XMLElement(name: "query", namespace: XMPPNamespaces.discoInfo)
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else { return [] }

        return Set(result.children(named: "feature").compactMap { $0.attribute("var") })
    }

    private func queryStreamhost(jid: String, context: ModuleContext) async throws -> ProxyInfo? {
        guard let targetJID = JID.parse(jid) else { return nil }

        var iq = XMPPIQ(type: .get, to: targetJID, id: context.generateID())
        let query = XMLElement(name: "query", namespace: XMPPNamespaces.bytestreams)
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else { return nil }

        guard let streamhost = result.child(named: "streamhost"),
              let host = streamhost.attribute("host"),
              let portStr = streamhost.attribute("port"),
              let port = UInt16(portStr) else { return nil }

        return ProxyInfo(jid: jid, host: host, port: port)
    }

    // MARK: - Candidate Building

    /// Builds SOCKS5 candidates for a session and registers its direct-candidate listener.
    private func buildCandidates(
        sid: String, offerID: String, context: ModuleContext
    ) async throws -> [SOCKS5Transport.Candidate] {
        try checkPreparation(sid: sid, offerID: offerID)
        var candidates: [SOCKS5Transport.Candidate] = []
        let addresses = localAddresses().filter(\.isIPv4)
        if !addresses.isEmpty {
            let listener = SOCKS5Listener()
            let registered = state.withLock { state in
                guard state.resources[sid]?.offerID == offerID else { return false }
                state.resources[sid]?.listener = listener
                return true
            }
            guard registered else { throw JingleError.sessionNotFound }
            let port = try? await startListener(listener)
            do {
                try checkPreparation(sid: sid, offerID: offerID)
            } catch {
                // A close before start cannot prevent that later start from opening its descriptors.
                await listener.close()
                throw error
            }
            if let port {
                let myJID = context.connectedJID()?.description ?? ""
                for (index, address) in addresses.enumerated() {
                    candidates.append(SOCKS5Transport.Candidate(
                        cid: context.generateID(), host: address.ip, port: port, jid: myJID,
                        priority: UInt32(100 + addresses.count - index), type: .direct
                    ))
                }
            } else {
                await listener.close()
            }
        }

        let proxy = try? await discoverProxy65(context: context)
        try checkPreparation(sid: sid, offerID: offerID)
        if let proxy {
            candidates.append(SOCKS5Transport.Candidate(
                cid: context.generateID(), host: proxy.host, port: proxy.port, jid: proxy.jid, priority: 10, type: .proxy
            ))
        }
        return candidates
    }

    private func checkPreparation(sid: String, offerID: String) throws {
        try Task.checkCancellation()
        guard state.withLock({ $0.resources[sid]?.offerID == offerID }) else { throw JingleError.sessionNotFound }
    }

    // MARK: - Proxy Activation

    private func activateProxy(
        proxyJID: String,
        targetJID: String,
        transportSID: String,
        context: ModuleContext
    ) async throws {
        guard let proxyJ = JID.parse(proxyJID) else {
            throw JingleError.transportNegotiationFailed("The file transfer proxy address is invalid")
        }

        var iq = XMPPIQ(type: .set, to: proxyJ, id: context.generateID())
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.bytestreams, attributes: ["sid": transportSID])
        var activate = XMLElement(name: "activate")
        activate.addText(targetJID)
        query.addChild(activate)
        iq.element.addChild(query)

        _ = try await context.sendIQ(iq)
    }
}
