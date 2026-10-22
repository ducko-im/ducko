import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.sm")

/// State snapshot for resuming a Stream Management session across reconnects.
public struct SMResumeState: Sendable {
    public let resumptionId: String
    public let incomingCounter: UInt32
    public let outgoingCounter: UInt32
    public let outgoingQueue: [XMLElement]
    public let connectedJID: FullJID
    public let location: String?
    /// The stream features the server sent after sign-in to the session, which a resume brings back.
    public let serverFeatures: XMLElement?

    public init(
        resumptionId: String,
        incomingCounter: UInt32,
        outgoingCounter: UInt32,
        outgoingQueue: [XMLElement],
        connectedJID: FullJID,
        location: String?,
        serverFeatures: XMLElement? = nil
    ) {
        self.resumptionId = resumptionId
        self.incomingCounter = incomingCounter
        self.outgoingCounter = outgoingCounter
        self.outgoingQueue = outgoingQueue
        self.connectedJID = connectedJID
        self.location = location
        self.serverFeatures = serverFeatures
    }
}

/// XEP-0198 Stream Management — tracks incoming/outgoing stanza counts; reliable delivery via ack requests.
/// Must be registered as BOTH a module and an interceptor.
public final class StreamManagementModule: XMPPModule, StanzaInterceptor, Sendable {
    private struct State {
        var context: ModuleContext?
        var enabled: Bool = false
        /// True from sending `<enable/>` until it is answered or fails. The server counts from the `<enable/>`
        /// (XEP-0198 §4), so stanzas sent in between are counted and queued too.
        var countsOutgoing: Bool = false
        /// Set once an enable was attempted on this stream, inline or not, since a stream gets only one.
        var enableAttempted: Bool = false
        var incomingCounter: UInt32 = 0
        var outgoingCounter: UInt32 = 0
        var outgoingQueue: [XMLElement] = []
        var enableContinuation: CheckedContinuation<Void, any Error>?
        var pendingSyncAck: PendingSyncAck?
        var nextSyncAckWaiterID: UInt64 = 0
        var resumptionId: String?
        var location: String?
        var connectedJID: FullJID?
        var serverFeatures: XMLElement?
        /// Set from the start of a fresh session until its setup completes. Such a session cannot be resumed, since the
        /// steps its setup did not finish would not run again.
        var setupPending: Bool = false
    }

    /// Single in-flight `<r/>` → `<a h='N'/>` waiter. Resumed by exactly one
    /// of: inbound matching `<a/>`, timeout fire, send error, parent
    /// cancellation, or stream tear-down. Every resumer claims by `id`
    /// under the lock so a stale resumer from a previous request cannot
    /// hijack a fresh slot.
    private struct PendingSyncAck {
        let id: UInt64
        let expectedH: UInt32
        let continuation: CheckedContinuation<Void, any Error>
        let timeoutTask: Task<Void, Never>
    }

    /// Result of processing a `<resumed>` or `<failed>` response from the server.
    public enum ResumeResult: Sendable {
        case resumed(jid: FullJID, retransmitQueue: [XMLElement])
        case failed
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(previousState: SMResumeState? = nil) {
        if let previousState {
            var initial = State()
            initial.resumptionId = previousState.resumptionId
            initial.incomingCounter = previousState.incomingCounter
            initial.outgoingCounter = previousState.outgoingCounter
            initial.outgoingQueue = previousState.outgoingQueue
            initial.connectedJID = previousState.connectedJID
            initial.location = previousState.location
            initial.serverFeatures = previousState.serverFeatures
            self.state = OSAllocatedUnfairLock(initialState: initial)
        } else {
            self.state = OSAllocatedUnfairLock(initialState: State())
        }
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Public State Access

    /// Returns a snapshot of SM session state for resumption, or `nil` if not resumable.
    public nonisolated var resumeState: SMResumeState? {
        state.withLock { state in
            guard !state.setupPending, let resumptionId = state.resumptionId,
                  let connectedJID = state.connectedJID else { return nil }
            return SMResumeState(
                resumptionId: resumptionId,
                incomingCounter: state.incomingCounter,
                outgoingCounter: state.outgoingCounter,
                outgoingQueue: state.outgoingQueue,
                connectedJID: connectedJID,
                location: state.location,
                serverFeatures: state.serverFeatures
            )
        }
    }

    public nonisolated var isResumable: Bool {
        state.withLock { !$0.setupPending && $0.resumptionId != nil && $0.connectedJID != nil }
    }

    /// Whether SM is currently enabled on the live stream. Callers gate the
    /// disconnect-side `<r/>`/`<a/>` handshake on this — non-SM servers
    /// must skip the handshake entirely.
    public nonisolated var isEnabled: Bool {
        state.withLock { $0.enabled }
    }

    /// The post-sign-in stream features of the session that a resume continues.
    public nonisolated var sessionFeatures: XMLElement? {
        state.withLock { $0.serverFeatures }
    }

    // MARK: - Lifecycle

    /// A fresh session drops the resume fields carried in from the previous session, so a later reconnect does not try
    /// to resume that one. An inline enable has already replaced them by now, so those stay. Either way the session is
    /// not resumable until `completeSessionSetup()`.
    public func handleSessionEstablished(resumed: Bool) {
        state.withLock { state in
            state.setupPending = !resumed
            guard !resumed, !state.enabled else { return }
            Self.clearResumeFields(&state)
        }
    }

    /// Makes a fresh session resumable once its setup has completed.
    public func completeSessionSetup() {
        state.withLock { $0.setupPending = false }
    }

    public func handleConnect() async throws {
        let (alreadyEnabled, attempted) = state.withLock { ($0.enabled, $0.enableAttempted) }
        if alreadyEnabled {
            log.info("Stream Management already enabled via inline negotiation")
            return
        }
        guard !attempted, let context = state.withLock({ $0.context }) else { return }

        guard let features = context.serverStreamFeatures(),
              features.child(named: "sm", namespace: XMPPNamespaces.sm) != nil else {
            log.info("Server does not advertise Stream Management support")
            return
        }

        let element = XMLElement(
            name: "enable",
            namespace: XMPPNamespaces.sm,
            attributes: ["resume": "true"]
        )
        do {
            try await withCheckedThrowingContinuation { cont in
                state.withLock { state in
                    state.enableContinuation = cont
                    state.enableAttempted = true
                    state.outgoingCounter = 0
                    state.outgoingQueue.removeAll()
                    state.countsOutgoing = true
                }
                Task {
                    do {
                        try await context.sendElement(element)
                    } catch {
                        let pending = self.state.withLock { state -> CheckedContinuation<Void, any Error>? in
                            let c = state.enableContinuation
                            state.enableContinuation = nil
                            return c
                        }
                        pending?.resume(throwing: error)
                    }
                }
            }
        } catch {
            state.withLock { $0.countsOutgoing = false }
            log.warning("Stream Management enable failed: \(error)")
        }
    }

    public func handleDisconnect() async {
        let (enableContinuation, pendingSyncAck) = state.withLock { (state: inout State) -> (CheckedContinuation<Void, any Error>?, PendingSyncAck?) in
            let cont = state.enableContinuation
            state.enableContinuation = nil
            let pending = state.pendingSyncAck
            state.pendingSyncAck = nil
            state.enabled = false
            state.countsOutgoing = false
            // Preserve resume-related state across disconnect
            return (cont, pending)
        }
        enableContinuation?.resume(throwing: XMPPClientError.notConnected)
        pendingSyncAck?.timeoutTask.cancel()
        pendingSyncAck?.continuation.resume(throwing: XMPPClientError.notConnected)
    }

    /// Clears all state including resume fields. Called on explicit disconnect or resume failure.
    public func resetResumption() {
        state.withLock { state in
            Self.clearResumeFields(&state)
            state.enabled = false
        }
    }

    private static func clearResumeFields(_ state: inout State) {
        state.resumptionId = nil
        state.location = nil
        state.connectedJID = nil
        state.incomingCounter = 0
        state.outgoingCounter = 0
        state.outgoingQueue.removeAll()
        state.serverFeatures = nil
    }

    // MARK: - Inline Enable (Bind 2)

    /// Processes an inline `<enabled>` element from Bind 2 / SASL2 success.
    /// Called synchronously during handshake — does not use the continuation pattern. The `<enable/>` went out
    /// inside `<authenticate/>` and no stanza has been sent since, so both counters start here.
    public func processInlineEnabled(_ element: XMLElement) {
        state.withLock { state in
            state.enableAttempted = true
            state.outgoingCounter = 0
            state.outgoingQueue.removeAll()
            Self.applyEnabled(element, to: &state)
        }
    }

    /// Records that an inline enable went out, so no second `<enable/>` goes out on this stream whatever the server
    /// answered (XEP-0198 §3).
    public func markInlineEnableSent() {
        state.withLock { $0.enableAttempted = true }
    }

    /// Starts the session `<enabled/>` names. The inbound counter starts on receiving it (XEP-0198 §4), and the
    /// post-sign-in features in effect now are kept for a resume.
    private static func applyEnabled(_ element: XMLElement, to state: inout State) {
        state.enabled = true
        state.countsOutgoing = false
        state.incomingCounter = 0
        state.resumptionId = element.attribute("id")
        state.location = element.attribute("location")
        if let context = state.context {
            state.connectedJID = context.connectedJID()
            state.serverFeatures = context.serverStreamFeatures()
        }
    }

    // MARK: - Resume

    /// Builds a `<resume>` element for sending to the server during stream negotiation.
    public func buildResumeElement() -> XMLElement {
        let (previd, h) = state.withLock { (state: inout State) -> (String, UInt32) in
            (state.resumptionId ?? "", state.incomingCounter)
        }
        return XMLElement(
            name: "resume",
            namespace: XMPPNamespaces.sm,
            attributes: ["previd": previd, "h": String(h)]
        )
    }

    /// Processes a `<resumed>` or `<failed>` response from the server.
    public func processResumeResponse(_ element: XMLElement) -> ResumeResult {
        if element.name == "resumed", element.namespace == XMPPNamespaces.sm {
            return state.withLock { state in
                // Reconcile h-value: server tells us how many of our stanzas it received
                if let hStr = element.attribute("h"), let h = UInt32(hStr) {
                    Self.reconcileAck(h: h, state: &state)
                }

                let retransmitQueue = state.outgoingQueue
                guard let jid = state.connectedJID else {
                    return .failed
                }
                state.enabled = true
                return .resumed(jid: jid, retransmitQueue: retransmitQueue)
            }
        }

        // <failed> or unexpected element — reset resumption state
        resetResumption()
        return .failed
    }

    // MARK: - Sync Ack

    /// Sends `<r/>` and awaits the matching `<a h='N'/>`. See `XMPPClient.disconnect` for the disconnect-time rationale.
    /// Single-inflight: throws `streamManagementBusy`, `timeout`, or `notConnected`; propagates `CancellationError`.
    public func requestSyncAck(timeout: Duration) async throws {
        let myId = state.withLock { (state: inout State) -> UInt64 in
            state.nextSyncAckWaiterID &+= 1
            return state.nextSyncAckWaiterID
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                let timeoutTask = Task<Void, Never> { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.expirePendingSyncAck(id: myId)
                }
                installSyncAckWaiter(id: myId, continuation: cont, timeoutTask: timeoutTask)
            }
        } onCancel: { [weak self] in
            self?.cancelPendingSyncAck(id: myId)
        }
    }

    /// Atomically claims the single sync-ack slot for `id`, then resolves the
    /// outcome outside the lock — `OSAllocatedUnfairLock` is non-reentrant and
    /// resuming the continuation can re-enter module state.
    private func installSyncAckWaiter(
        id: UInt64,
        continuation: CheckedContinuation<Void, any Error>,
        timeoutTask: Task<Void, Never>
    ) {
        let outcome = state.withLock { (state: inout State) -> InstallOutcome in
            if !state.enabled { return .failNotConnected }
            if state.pendingSyncAck != nil { return .failBusy }
            if Task.isCancelled { return .failCancelled }
            guard let context = state.context else { return .failNotConnected }
            state.pendingSyncAck = PendingSyncAck(
                id: id,
                expectedH: state.outgoingCounter,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            return .registered(context: context)
        }

        switch outcome {
        case .failNotConnected:
            timeoutTask.cancel()
            continuation.resume(throwing: XMPPClientError.notConnected)
        case .failBusy:
            timeoutTask.cancel()
            continuation.resume(throwing: XMPPClientError.streamManagementBusy)
        case .failCancelled:
            timeoutTask.cancel()
            continuation.resume(throwing: CancellationError())
        case let .registered(context):
            Task { [weak self] in
                do {
                    try await context.sendElement(XMLElement(name: "r", namespace: XMPPNamespaces.sm))
                } catch {
                    self?.failPendingSyncAck(id: id, error: error)
                }
            }
        }
    }

    private enum InstallOutcome {
        case failNotConnected
        case failBusy
        case failCancelled
        case registered(context: ModuleContext)
    }

    /// Timeout-task body. The slot's own `timeoutTask` is the caller — we
    /// must NOT cancel it here (calling cancel on yourself in flight is
    /// meaningless). The other two helpers DO cancel because they fire
    /// while the timeout task is still sleeping.
    private func expirePendingSyncAck(id: UInt64) {
        let claimed = state.withLock { (state: inout State) -> PendingSyncAck? in
            guard state.pendingSyncAck?.id == id else { return nil }
            let pending = state.pendingSyncAck
            state.pendingSyncAck = nil
            return pending
        }
        claimed?.continuation.resume(throwing: XMPPClientError.timeout)
    }

    private func failPendingSyncAck(id: UInt64, error: any Error) {
        let claimed = state.withLock { (state: inout State) -> PendingSyncAck? in
            guard state.pendingSyncAck?.id == id else { return nil }
            let pending = state.pendingSyncAck
            state.pendingSyncAck = nil
            return pending
        }
        claimed?.timeoutTask.cancel()
        claimed?.continuation.resume(throwing: error)
    }

    private func cancelPendingSyncAck(id: UInt64) {
        let claimed = state.withLock { (state: inout State) -> PendingSyncAck? in
            guard state.pendingSyncAck?.id == id else { return nil }
            let pending = state.pendingSyncAck
            state.pendingSyncAck = nil
            return pending
        }
        claimed?.timeoutTask.cancel()
        claimed?.continuation.resume(throwing: CancellationError())
    }

    // MARK: - StanzaInterceptor

    public func processIncoming(_ element: XMLElement) -> Bool {
        if element.namespace == XMPPNamespaces.sm {
            handleSMElement(element)
            return true
        }

        if isStanza(element) {
            state.withLock { state in
                if state.enabled {
                    state.incomingCounter &+= 1
                }
            }
        }

        return false
    }

    public func processOutgoing(_ element: XMLElement) {
        if isStanza(element) {
            state.withLock { state in
                if state.enabled || state.countsOutgoing {
                    state.outgoingCounter &+= 1
                    state.outgoingQueue.append(element)
                }
            }
        }
    }

    private func handleSMElement(_ element: XMLElement) {
        switch element.name {
        case "enabled":
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                Self.applyEnabled(element, to: &state)
                let cont = state.enableContinuation
                state.enableContinuation = nil
                return cont
            }
            continuation?.resume()

        case "failed":
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                let cont = state.enableContinuation
                state.enableContinuation = nil
                return cont
            }
            continuation?.resume(throwing: XMPPClientError.unexpectedStreamState("SM enable failed"))

        case "r":
            let (counter, context) = state.withLock { (state: inout State) -> (UInt32, ModuleContext?) in
                (state.incomingCounter, state.context)
            }
            if let context {
                let a = XMLElement(
                    name: "a",
                    namespace: XMPPNamespaces.sm,
                    attributes: ["h": String(counter)]
                )
                Task { try? await context.sendElement(a) }
            }

        case "a":
            handleAck(element)

        default:
            break
        }
    }

    private func handleAck(_ element: XMLElement) {
        guard let hStr = element.attribute("h"), let h = UInt32(hStr) else { return }
        let claimed = state.withLock { (state: inout State) -> PendingSyncAck? in
            let valid = Self.reconcileAck(h: h, state: &state)
            // Covering-ack: `h >= expectedH` (wrap-safe via `&-`) confirms AT LEAST through snapshot. Reentrant
            // `send()` between registration and matching `<a/>` (e.g. `replyServiceUnavailable`) can advance
            // outgoingCounter past expectedH, so `h > expectedH` is still valid. Upper bound is defensive belt
            // over `reconcileAck`'s `acked <= queue.count` check.
            guard valid, let pending = state.pendingSyncAck,
                  (h &- pending.expectedH) <= UInt32(state.outgoingQueue.count) &+ 1 else {
                return nil
            }
            state.pendingSyncAck = nil
            return pending
        }
        claimed?.timeoutTask.cancel()
        claimed?.continuation.resume()
    }

    @discardableResult
    private static func reconcileAck(h: UInt32, state: inout State) -> Bool {
        let baseCounter = state.outgoingCounter &- UInt32(state.outgoingQueue.count)
        let acked = h &- baseCounter
        guard acked <= UInt32(state.outgoingQueue.count) else {
            let counter = state.outgoingCounter
            log.warning("Invalid ack h=\(h), expected at most \(counter)")
            return false
        }
        let toRemove = Int(acked)
        if toRemove > 0 {
            state.outgoingQueue.removeFirst(toRemove)
        }
        return true
    }

    private func isStanza(_ element: XMLElement) -> Bool {
        element.name == "iq" || element.name == "message" || element.name == "presence"
    }
}
