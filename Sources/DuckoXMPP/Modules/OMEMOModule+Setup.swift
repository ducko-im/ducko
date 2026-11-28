import Logging

private let log = Logger(label: "im.ducko.xmpp.omemo")

/// Why a setup attempt could not go on.
enum OMEMOSetupFailure: Error {
    /// One of the account's device lists could not be read, so a new device's id could collide with a listed one.
    case ownDeviceListUnreadable
}

extension OMEMOModule {
    /// Whether the connection's first setup attempt, and the work after it when it completed the setup, has ended.
    enum SetupAttemptGate {
        case pending([CheckedContinuation<Void, Never>])
        case settled
        /// The connection ended.
        case closed
    }
}

extension OMEMOModule.State {
    /// Whether the connection's first attempt, and with it the connect's own publishes of the device list, is done, so
    /// a re-announce cannot overlap them.
    var isConnectSettled: Bool {
        if case .settled = firstAttempt { true } else { false }
    }
}

/// Setting up this device's encryption on a connection without holding the session up: its identity, its entry on the
/// account's device list and its bundle (XEP-0384). Attempts that do not finish are retried after
/// `setupRetryDelays`, and a refusal ends them. Each attempt runs in the own-list slot, so it never overlaps a
/// re-announce, and the waits between attempts leave the slot free for one. The legacy publication follows the attempt
/// that completes, and its outcome changes nothing about the setup's.
extension OMEMOModule {
    // MARK: - Public API

    /// Returns once the connection's first setup attempt has had its outcome and, when it completed the setup, the
    /// stale-bundle pruning and the legacy publication after it have ended, whether they succeeded or not. Returns at
    /// once when the session runs none (a resumed session with an identity, or unreadable stored keys), or once the
    /// connection has ended.
    public func awaitSetupAttempt() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isParked = state.withLock { state -> Bool in
                guard case var .pending(waiters) = state.firstAttempt else { return false }
                waiters.append(continuation)
                state.firstAttempt = .pending(waiters)
                return true
            }
            if !isParked { continuation.resume() }
        }
    }

    /// Starts a fresh series of attempts. The first runs as soon as any running attempt has ended. Returns false
    /// and does nothing while no session is up, when the stored keys could not be read, or once setup has completed on
    /// this connection.
    @discardableResult
    public func retrySetup() -> Bool {
        let (isStarted, replaced) = state.withLock { state -> (Bool, Task<Void, Never>?) in
            guard state.isSessionEstablished, !state.identityUnavailable, !state.setupCompleted else { return (false, nil) }
            return (true, startSetupLoop(&state))
        }
        replaced?.cancel()
        return isStarted
    }

    /// Waits while an attempt runs and no identity is installed, so an encryption or reset started meanwhile uses the
    /// identity the attempt installs. Returns at once otherwise.
    package func awaitIdentityIfSettingUp() async {
        while state.withLock({ $0.ownIdentity == nil && $0.attemptInFlight }) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let isParked = state.withLock { state -> Bool in
                    guard state.ownIdentity == nil, state.attemptInFlight else { return false }
                    state.identityWaiters.append(continuation)
                    return true
                }
                if !isParked { continuation.resume() }
            }
        }
    }

    // MARK: - Attempts

    /// Replaces the running series of attempts with a new one, under the lock, and returns the replaced one for the
    /// caller to cancel.
    func startSetupLoop(_ state: inout State) -> Task<Void, Never>? {
        state.setupGeneration &+= 1
        state.attemptInFlight = true
        let generation = state.setupGeneration
        let replaced = state.setupLoopTask
        state.setupLoopTask = Task { [weak self] in
            await self?.runSetupLoop(generation: generation)
        }
        return replaced
    }

    private func runSetupLoop(generation: UInt64) async {
        var delays = setupRetryDelays[...]
        while await runSetupAttempt(generation: generation) == .incomplete, let delay = delays.popFirst() {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
        }
    }

    /// Runs one attempt in the own-list slot once the task it replaces has ended, so that task's reads and writes of
    /// the list are done before the attempt reads it. Returns the outcome the attempt committed, or nil when it
    /// committed none.
    private func runSetupAttempt(generation: UInt64) async -> OMEMOSetupStatus? {
        await withCheckedContinuation { (continuation: CheckedContinuation<OMEMOSetupStatus?, Never>) in
            let isQueued = state.withLock { state -> Bool in
                guard state.setupGeneration == generation else { return false }
                state.attemptInFlight = true
                let previous = state.ownListTask
                fillOwnListSlot(&state) { module in
                    await previous?.value
                    let committed = await module.performSetupAttempt(generation: generation)
                    continuation.resume(returning: committed.status)
                    if committed.isFirstCompletion {
                        await module.pruneStaleBundlesAfterSetup()
                        await module.publishLegacyDeviceAfterSetup()
                        module.settleFirstAttempt()
                    }
                }
                return true
            }
            if !isQueued { continuation.resume(returning: nil) }
        }
    }

    private func performSetupAttempt(generation: UInt64) async -> (status: OMEMOSetupStatus?, isFirstCompletion: Bool) {
        guard state.withLock({ $0.setupGeneration == generation }) else { return (nil, false) }
        let status = await attemptSetup(generation: generation)
        return commitSetupStatus(status, generation: generation)
    }

    /// Nil when the stored keys could not be read, which no later attempt can fix.
    private func attemptSetup(generation: UInt64) async -> OMEMOSetupStatus? {
        let connected: ConnectIdentity
        do {
            guard let identity = try await connectIdentity() else { return nil }
            connected = identity
        } catch {
            return Self.setupStatus(for: error)
        }
        if connected.ownList != nil, await !installGeneratedIdentity(connected.identity, generation: generation) {
            return .incomplete
        }
        do {
            guard try await ensureOwnDeviceInList(connected.identity.deviceID, listed: connected.ownList, version: .omemo2) else { return .incomplete }
            try await publishOMEMO2Bundle()
        } catch {
            return Self.setupStatus(for: error)
        }
        return .complete
    }

    /// Stores a generated identity, when a persister is configured, then installs it while `generation` is current, and returns whether it did. An
    /// identity stored for an attempt that was superseded meanwhile is left for the next attempt to install, so that
    /// one does not store a second device over it.
    private func installGeneratedIdentity(_ identity: OwnIdentity, generation: UInt64) async -> Bool {
        let data = Self.identityData(of: identity)
        let (persister, accountID) = state.withLock { ($0.identityPersister, $0.identityPersisterAccountID) }
        if let persister, let accountID {
            guard await persister.persistNewIdentity(data, accountID: accountID) else { return false }
        }
        return state.withLock { state in
            guard state.setupGeneration == generation else {
                state.pendingIdentity = data
                return false
            }
            state.ownIdentity = identity
            return true
        }
    }

    /// Commits the outcome of a current attempt: it ends the attempt for the encryptions waiting on it, reports a
    /// status, and settles the first-attempt gate, which the first completion leaves to the work after it. A
    /// superseded attempt commits nothing.
    private func commitSetupStatus(
        _ status: OMEMOSetupStatus?, generation: UInt64
    ) -> (status: OMEMOSetupStatus?, isFirstCompletion: Bool) {
        struct Commit {
            let context: ModuleContext?
            let waiters: [CheckedContinuation<Void, Never>]
            let isFirstCompletion: Bool
        }
        let committed = state.withLock { state -> Commit? in
            guard state.setupGeneration == generation else { return nil }
            state.attemptInFlight = false
            let waiters = state.identityWaiters
            state.identityWaiters.removeAll()
            let isFirstCompletion = status == .complete && !state.setupCompleted
            if isFirstCompletion {
                state.setupCompleted = true
            }
            return Commit(context: state.context, waiters: waiters, isFirstCompletion: isFirstCompletion)
        }
        guard let committed else { return (nil, false) }
        for waiter in committed.waiters {
            waiter.resume()
        }
        if let status {
            logSetupStatus(status)
            committed.context?.emitEvent(.omemoSetupChanged(status))
        }
        if !committed.isFirstCompletion {
            settleFirstAttempt()
        }
        return (status, committed.isFirstCompletion)
    }

    /// Settles the first-attempt gate, and lets re-announces start, since the connection's own publishes of the list
    /// are done. Only the first call does anything.
    func settleFirstAttempt() {
        let settled = state.withLock { state -> (waiters: [CheckedContinuation<Void, Never>], pendingReannounces: Set<OMEMOWireFormat>)? in
            guard case let .pending(waiters) = state.firstAttempt else { return nil }
            state.firstAttempt = .settled
            return (waiters, state.pendingReannounces)
        }
        guard let settled else { return }
        // A notification asked for a re-announce while the connect's own publishes ran.
        for version in settled.pendingReannounces {
            reannounceOwnDevice(in: version)
        }
        for waiter in settled.waiters {
            waiter.resume()
        }
    }

    /// A server error refuses the setup when it names a known condition and is not one to wait out.
    static func setupStatus(for error: any Error) -> OMEMOSetupStatus {
        log.debug("OMEMO setup attempt failed: \(OMEMOModuleError.translatingCryptoFailure(error))")
        guard let stanzaError = error as? XMPPStanzaError else { return .incomplete }
        switch stanzaError.errorType {
        case .wait, .continue:
            return .incomplete
        case .cancel, .auth, .modify:
            return stanzaError.condition == .undefinedCondition ? .incomplete : .refused(stanzaError.condition)
        }
    }

    private func logSetupStatus(_ status: OMEMOSetupStatus) {
        switch status {
        case .complete:
            let deviceID = state.withLock { $0.ownIdentity?.deviceID.value }
            log.info("OMEMO setup complete, device ID: \(deviceID.map(String.init) ?? "none")")
        case .incomplete:
            log.warning("OMEMO setup is incomplete")
        case let .refused(condition):
            log.warning("OMEMO setup was refused: \(condition.rawValue)")
        }
    }

    // MARK: - Pruning

    /// Best-effort defense-in-depth pass against PEP entries whose bundles are missing, once setup has completed on the
    /// connection. It changes nothing about the setup's outcome.
    private func pruneStaleBundlesAfterSetup() async {
        let current = state.withLock { state -> (deviceID: UInt32, ownList: [UInt32])? in
            guard let identity = state.ownIdentity else { return nil }
            let deviceID = identity.deviceID.value
            return (deviceID, state.deviceLists[.omemo2]?[identity.connectedJID.bareJID] ?? [deviceID])
        }
        guard let current else { return }
        do {
            _ = try await pruneStaleBundles(ownDeviceID: current.deviceID, ownDeviceList: current.ownList)
        } catch let stanzaError as XMPPStanzaError {
            log.warning("OMEMO stale-bundle pruning failed: \(stanzaError.condition.rawValue)")
        } catch {
            log.warning("OMEMO stale-bundle pruning failed")
            log.debug("OMEMO stale-bundle pruning failed: \(error)")
        }
    }
}
