import CryptoKit
import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.omemo")

/// Implements XEP-0384 OMEMO Encryption and XEP-0380 Explicit Message Encryption.
///
/// Manages device lists, bundles, session establishment (X3DH), and
/// per-message encryption/decryption (Double Ratchet, with AES-256-CBC
/// payloads in OMEMO 2 and AES-128-GCM in legacy OMEMO).
/// Uses PEPModule for all PubSub operations.
public final class OMEMOModule: XMPPModule, Sendable {
    // MARK: - State

    struct State {
        var context: ModuleContext?
        /// Each version's device lists, since a contact can list different devices on each.
        var deviceLists: [OMEMOWireFormat: [BareJID: [UInt32]]] = [:]
        var ownIdentity: OwnIdentity?
        var pendingIdentity: OMEMOIdentityData?
        /// Set when the stored keys could not be read, so this connection neither generates a device nor publishes.
        var identityUnavailable = false
        var sessions: [SessionKey: OMEMOSession] = [:]
        /// The sessions this connection built, or took up from a key exchange that reached it live or as a carbon.
        var liveSessionKeys: Set<SessionKey> = []
        var usedPreKeyIDs: Set<UInt32> = []
        /// Each version's key exchanges this connection took up, so a replayed one cannot build a session again.
        var acceptedKeyExchanges: [OMEMOWireFormat: Set<[UInt8]>] = [:]
        /// Each version's ratchet keys whose chains this connection sent a heartbeat for.
        var heartbeatChains: [OMEMOWireFormat: Set<[UInt8]>] = [:]
        /// The pre-key ids of this module's last successful OMEMO 2 bundle publish.
        var publishedPreKeyIDs: Set<UInt32>?
        /// The signed pre-key id of this module's last successful OMEMO 2 bundle publish.
        var publishedSignedPreKeyID: UInt32?
        /// The pre-key ids of this module's last legacy publish whose bundle and device-list entry both succeeded.
        var publishedLegacyPreKeyIDs: Set<UInt32>?
        /// The signed pre-key id of that legacy publish.
        var publishedLegacySignedPreKeyID: UInt32?
        /// Set while a legacy publication, its bundle out, writes this device onto the account's legacy list, so a
        /// notification leaving the device off that list meanwhile asks for a re-announce.
        var isWritingLegacyListEntry = false
        /// The latest OMEMO 2 bundle publish. Each publish waits for the one before it.
        var bundlePublish: Task<Void, any Error>?
        /// Replaced by the account's guard, which outlives this module, before the module connects.
        var trustGuard = OMEMOTrustGuard()
        /// See `OMEMOService.seenDeviceCacheByAccount` for the cache-survival rationale and the opaque-`accountID` contract.
        var seenDeviceClassificationProvider: (any SeenDeviceClassificationProviding)?
        var seenDeviceClassificationAccountID: String?
        var emergencyRetractGuard: (any EmergencyRetractGuarding)?
        var emergencyRetractConfirmation: EmergencyRetractConfirmation?
        var orphanDeviceRecordPurger: (any OrphanDeviceRecordPurging)?
        /// The one task that reads, changes and publishes this device's list after the connect: a setup attempt or a
        /// re-announce. It empties the slot when it ends, unless a newer task took it.
        var ownListTask: Task<Void, Never>?
        var ownListTaskGeneration: UInt64 = 0
        /// The versions whose list a notification showed without this device while a re-announce could not start.
        var pendingReannounces: Set<OMEMOWireFormat> = []
        /// Each version's senders whose list this connection fetched again for a device it left out.
        var refreshedListSenders: [OMEMOWireFormat: Set<BareJID>] = [:]
        var identityPersister: (any OMEMOIdentityPersisting)?
        var identityPersisterAccountID: String?
        /// Set from the session's establishment until it ends.
        var isSessionEstablished = false
        /// The running series of setup attempts. Only attempts of the current generation commit an outcome.
        var setupLoopTask: Task<Void, Never>?
        var setupGeneration: UInt64 = 0
        /// Set once an attempt on this connection completed the setup.
        var setupCompleted = false
        var firstAttempt: SetupAttemptGate = .pending([])
        /// Set while an attempt runs or is about to, so encryptions wait for the identity it installs.
        var attemptInFlight = false
        /// Encryptions and resets waiting for the running attempt to install an identity.
        var identityWaiters: [CheckedContinuation<Void, Never>] = []
    }

    let state: OSAllocatedUnfairLock<State>
    let pepModule: PEPModule
    /// Tells room occupants' real addresses, whose sessions decrypt their room messages.
    let mucModule: MUCModule?
    let setupRetryDelays: [Duration]
    private let drawDeviceID: @Sendable () -> OMEMODeviceID

    public var features: [String] {
        [XMPPNamespaces.omemo, XMPPNamespaces.eme]
    }

    public convenience init(pepModule: PEPModule, mucModule: MUCModule? = nil) {
        self.init(pepModule: pepModule, mucModule: mucModule, setupRetryDelays: [.seconds(10), .seconds(60), .seconds(300)])
    }

    init(
        pepModule: PEPModule, mucModule: MUCModule? = nil, setupRetryDelays: [Duration],
        drawDeviceID: @escaping @Sendable () -> OMEMODeviceID = OMEMODeviceID.random
    ) {
        self.pepModule = pepModule
        self.mucModule = mucModule
        self.setupRetryDelays = setupRetryDelays
        self.drawDeviceID = drawDeviceID
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    // MARK: - XMPPModule

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    /// Installs the configured identity, because the session's stanzas can reach `handleMessage` before `handleConnect`
    /// runs, and a resumed session never runs it.
    public func handleSessionEstablished(resumed: Bool) {
        state.withLock { $0.isSessionEstablished = true }
        guard !state.withLock({ $0.identityUnavailable }) else {
            settleFirstAttempt()
            return
        }
        do {
            try installPendingIdentity()
        } catch {
            markIdentityUnavailable()
            log.warning("OMEMO identity could not be restored")
            log.debug("OMEMO identity could not be restored: \(error)")
            settleFirstAttempt()
            return
        }
        // Without an identity, an attempt installs one: the attempt `handleConnect` starts, or on a resumed session the
        // one a `retrySetup()` call starts. Marking it in flight now makes an encryption that starts before that
        // attempt's task wait for it, and that attempt settles the first-attempt gate. A resumed session with an
        // identity starts no attempt of its own, so the gate settles here. An attempt a later `retrySetup()` starts
        // runs after any re-announce, in the own-list slot.
        let hasIdentity = state.withLock { state in
            if state.ownIdentity == nil { state.attemptInFlight = true }
            return state.ownIdentity != nil
        }
        if resumed, hasIdentity {
            settleFirstAttempt()
        }
    }

    /// Starts setting up this device's encryption and returns, so the session does not wait for it.
    public func handleConnect() async throws {
        let (isUnavailable, replaced) = state.withLock { state in
            state.identityUnavailable ? (true, nil) : (false, startSetupLoop(&state))
        }
        replaced?.cancel()
        if isUnavailable {
            settleFirstAttempt()
        }
    }

    public func handleDisconnect() async {
        let (ownListTask, setupLoopTask, waiters) = state.withLock { state in
            defer {
                state.ownListTask = nil
                state.setupLoopTask = nil
            }
            state.setupGeneration &+= 1
            state.setupCompleted = false
            state.attemptInFlight = false
            state.isSessionEstablished = false
            var waiters = state.identityWaiters
            state.identityWaiters.removeAll()
            if case let .pending(attemptWaiters) = state.firstAttempt {
                waiters += attemptWaiters
            }
            state.firstAttempt = .closed
            return (state.ownListTask, state.setupLoopTask, waiters)
        }
        ownListTask?.cancel()
        setupLoopTask?.cancel()
        for waiter in waiters {
            waiter.resume()
        }
        state.withLock {
            $0.ownIdentity = nil
            $0.identityUnavailable = false
            $0.pendingReannounces.removeAll()
            $0.refreshedListSenders.removeAll()
            $0.deviceLists.removeAll()
            $0.sessions.removeAll()
            $0.liveSessionKeys.removeAll()
            $0.usedPreKeyIDs.removeAll()
            $0.acceptedKeyExchanges.removeAll()
            $0.heartbeatChains.removeAll()
            $0.publishedPreKeyIDs = nil
            $0.publishedSignedPreKeyID = nil
            $0.publishedLegacyPreKeyIDs = nil
            $0.publishedLegacySignedPreKeyID = nil
            $0.isWritingLegacyListEntry = false
            $0.seenDeviceClassificationProvider = nil
            $0.seenDeviceClassificationAccountID = nil
            $0.emergencyRetractGuard = nil
            $0.emergencyRetractConfirmation = nil
            $0.orphanDeviceRecordPurger = nil
            $0.identityPersister = nil
            $0.identityPersisterAccountID = nil
        }
    }

    public func handleMessage(_ message: XMPPMessage) throws {
        handleDeviceListNotification(message)
        handleEncryptedMessage(message)
    }

    // MARK: - Public API

    public var ownIdentityData: OMEMOIdentityData? {
        state.withLock { $0.ownIdentity.map(Self.identityData) }
    }

    static func identityData(of identity: OwnIdentity) -> OMEMOIdentityData {
        OMEMOIdentityData(
            deviceID: identity.deviceID.value,
            identityKeyRaw: identity.identityKeyPair.rawRepresentation,
            signedPreKeyID: identity.signedPreKey.keyID,
            signedPreKeyRaw: identity.signedPreKey.rawRepresentation,
            signedPreKeySignature: identity.signedPreKey.signature,
            preKeys: identity.preKeys.map {
                OMEMOIdentityData.PreKeyData(keyID: $0.keyID, keyRaw: $0.rawRepresentation)
            },
            retainedSignedPreKeys: identity.retainedSignedPreKeys.map(\.identityData)
        )
    }

    /// Sets the identity to install when the next session is established, instead of generating a fresh one.
    public func configureIdentity(_ data: OMEMOIdentityData) {
        state.withLock { $0.pendingIdentity = data }
    }

    /// Keeps this connection from generating a new device when the stored keys could not be read. Encryption stays
    /// unavailable until a later connect loads them.
    package func markIdentityUnavailable() {
        state.withLock {
            $0.identityUnavailable = true
            $0.pendingIdentity = nil
        }
    }

    /// Wires the seen-device classification provider for `pruneStaleBundles`. See `SeenDeviceClassificationProviding` for the cache contract.
    package func configureSeenDeviceClassificationProvider(
        _ provider: any SeenDeviceClassificationProviding,
        accountID: String
    ) {
        state.withLock {
            $0.seenDeviceClassificationProvider = provider
            $0.seenDeviceClassificationAccountID = accountID
        }
    }

    /// Wires the store a generated identity is saved to before anything uses it, under `accountID`.
    package func configureIdentityPersister(_ persister: any OMEMOIdentityPersisting, accountID: String) {
        state.withLock {
            $0.identityPersister = persister
            $0.identityPersisterAccountID = accountID
        }
    }

    /// Wires the emergency-retract dependencies. See `EmergencyRetractGuarding` for the reconnect-survival rationale; `orphanPurger` deletes trust/session rows for retracted own-deviceIDs.
    package func configureEmergencyRetract(
        confirmation: EmergencyRetractConfirmation?,
        guard inFlightGuard: any EmergencyRetractGuarding,
        orphanPurger: any OrphanDeviceRecordPurging
    ) {
        state.withLock {
            $0.emergencyRetractConfirmation = confirmation
            $0.emergencyRetractGuard = inFlightGuard
            $0.orphanDeviceRecordPurger = orphanPurger
        }
    }

    /// Returns the set of pre-key IDs consumed during this session.
    public func consumedPreKeyIDs() -> Set<UInt32> {
        state.withLock { $0.usedPreKeyIDs }
    }

    /// Adds one-time pre-keys to the installed identity. They go out with the next bundle publish.
    package func addPreKeys(_ preKeys: [OMEMOPreKey]) {
        state.withLock { $0.ownIdentity?.preKeys += preKeys }
    }

    /// Drops pre-keys used up elsewhere, such as by an earlier connection, from the bundle and from the keys a key
    /// exchange can take up. This connection holds no record of their key exchanges, so it could not tell a replay of
    /// one. Keys this connection used itself stay open to a new key exchange, such as one from a second contact who
    /// took the same key from the bundle, because this connection's record tells a replay of the first.
    package func retirePreKeys(_ keyIDs: Set<UInt32>) {
        state.withLock { state in
            let retired = keyIDs.subtracting(state.usedPreKeyIDs)
            state.ownIdentity?.preKeys.removeAll { retired.contains($0.keyID) }
        }
    }

    /// Whether the bundle this connection last published in either version lags behind the keys this device can hand
    /// out, as when nothing was published yet, pre-keys were used up or added since, or the signed pre-key was
    /// replaced. A failed publish leaves the last published keys in place.
    package var bundleNeedsPublish: Bool {
        state.withLock { state in
            guard let identity = state.ownIdentity else { return false }
            let preKeyIDs = Self.publishablePreKeyIDs(of: identity, used: state.usedPreKeyIDs)
            return state.publishedPreKeyIDs != preKeyIDs || state.publishedSignedPreKeyID != identity.signedPreKey.keyID
                || state.legacyPublicationLags(signedPreKeyID: identity.signedPreKey.keyID, preKeyIDs: preKeyIDs)
        }
    }

    /// Publishes the bundle as the identity stands when the publish starts, then the legacy bundle and device-list entry
    /// when they lag. Bundle publishes never overlap: one asked for during another starts once it ends. Each runs in a
    /// task of its own, so a caller's cancellation fails no publish.
    package func republishBundle() async throws {
        try await publishOMEMO2Bundle()
        try await publishLegacyDeviceInOwnListSlot()
    }

    /// Publishes the OMEMO 2 bundle once any earlier bundle publish has ended.
    func publishOMEMO2Bundle() async throws {
        let publish = state.withLock { state in
            let previous = state.bundlePublish
            let publish = Task {
                _ = await previous?.result
                try await publishCurrentBundle()
            }
            state.bundlePublish = publish
            return publish
        }
        try await publish.value
    }

    /// Restores previously persisted sessions into the module's in-memory state. A session that fails to decode, or
    /// whose record is in another version than its entry names, counts as no session.
    public func restoreSessions(_ entries: [StoredSessionEntry]) {
        let undecodable = state.withLock { state in
            var undecodable = 0
            for entry in entries {
                if let session = try? OMEMOSession(serialized: entry.sessionData, associatedData: entry.associatedData), session.format == entry.version {
                    state.sessions[SessionKey(jid: entry.jid, deviceID: entry.deviceID, version: entry.version)] = session
                } else {
                    undecodable += 1
                }
            }
            return undecodable
        }
        if undecodable > 0 {
            log.warning("OMEMO skipped \(undecodable) stored session(s) that could not be decoded")
        }
    }

    /// Exports the state of the session in `version` with a device for persistent storage.
    public func exportSession(jid: BareJID, deviceID: UInt32, version: OMEMOWireFormat) -> StoredSessionEntry? {
        state.withLock { Self.storedEntry(SessionKey(jid: jid, deviceID: deviceID, version: version), in: $0.sessions) }
    }

    static func storedEntry(_ key: SessionKey, in sessions: [SessionKey: OMEMOSession]) -> StoredSessionEntry? {
        sessions[key].map {
            StoredSessionEntry(jid: key.jid, deviceID: key.deviceID, version: key.version, sessionData: $0.serialized, associatedData: $0.associatedData)
        }
    }

    /// Exports all sessions for persistent storage (e.g., on disconnect).
    public func allSessionEntries() -> [StoredSessionEntry] {
        state.withLock { state in
            state.sessions.map { key, session in
                StoredSessionEntry(
                    jid: key.jid, deviceID: key.deviceID, version: key.version,
                    sessionData: session.serialized, associatedData: session.associatedData
                )
            }
        }
    }

    struct EncryptionResult {
        let keyElement: XMLElement
        let sessionKey: SessionKey
    }

    /// Encryption results plus the devices dropped, as for a bundle that could not be fetched (surfaced via
    /// `omemoRecipientsPartial`).
    struct EncryptionBatch {
        var results: [EncryptionResult]
        var dropped: [DroppedOMEMORecipient]
    }

    /// Cap on concurrent per-recipient bundle fetches during encrypt. Without bounding, a peer with thousands of
    /// devices saturates SM ack windows (observed at 950+). 64 stays below SM-window pressure while amortizing TLS
    /// handshakes; chunked iteration still completes every device.
    private static let encryptConcurrencyCap = 64

    /// Wraps `keyMaterial` for each of `devices` through its session in `version`.
    func encryptKeysInParallel(
        keyMaterial: [UInt8], identity: OwnIdentity,
        devices: [(jid: BareJID, deviceID: UInt32)], version: OMEMOWireFormat
    ) async throws -> EncryptionBatch {
        assert(
            Set(devices.map { OMEMODeviceKey(jid: $0.jid, deviceID: $0.deviceID) }).count == devices.count,
            "Duplicate devices would corrupt Double Ratchet sessions"
        )
        // XEP-0384 §5.4: a listed device without a bundle is not an error — skip it (guards against stale PEP entries).
        // Chunked via `stride` + per-chunk `withThrowingTaskGroup` so at most `encryptConcurrencyCap` fetches are in flight.
        enum Outcome: Sendable {
            case encrypted(EncryptionResult)
            case dropped(DroppedOMEMORecipient)
        }
        var batch = EncryptionBatch(results: [], dropped: [])
        batch.results.reserveCapacity(devices.count)
        for chunkStart in stride(from: 0, to: devices.count, by: Self.encryptConcurrencyCap) {
            let chunkEnd = min(chunkStart + Self.encryptConcurrencyCap, devices.count)
            let chunk = Array(devices[chunkStart ..< chunkEnd])
            try await withThrowingTaskGroup(of: Outcome.self) { group in
                for device in chunk {
                    group.addTask {
                        do {
                            let result = try await self.encryptKeyForDevice(
                                keyMaterial: keyMaterial, jid: device.jid,
                                deviceID: device.deviceID, identity: identity, version: version
                            )
                            return .encrypted(result)
                        } catch OMEMOModuleError.bundleNotFound {
                            log.debug(
                                "OMEMO: skipping \(device.jid)/\(device.deviceID) — bundle not found"
                            )
                            return .dropped(DroppedOMEMORecipient(jid: device.jid, deviceID: device.deviceID))
                        } catch let stanzaError as XMPPStanzaError
                            where stanzaError.condition == .itemNotFound {
                            log.debug(
                                "OMEMO: skipping \(device.jid)/\(device.deviceID) — item-not-found"
                            )
                            return .dropped(DroppedOMEMORecipient(jid: device.jid, deviceID: device.deviceID))
                        }
                    }
                }
                for try await outcome in group {
                    switch outcome {
                    case let .encrypted(result):
                        batch.results.append(result)
                    case let .dropped(drop):
                        batch.dropped.append(drop)
                    }
                }
            }
        }
        return batch
    }

    // MARK: - Identity Generation

    /// The identity a setup attempt works with. `ownList` is the account's device list when the identity was generated
    /// against it, and nil for an installed one. A generated identity is not installed yet.
    struct ConnectIdentity {
        let identity: OwnIdentity
        let ownList: [UInt32]?
    }

    /// The identity a setup attempt works with. Generates a new device only when none was configured, with an id
    /// neither of the account's lists holds (XEP-0384). Returns `nil` when the configured keys could not be read, since
    /// replacing them would lose the device. Throws `ownDeviceListUnreadable` when either list could not be read, since
    /// a new id could then collide. A later attempt reads them again.
    func connectIdentity() async throws -> ConnectIdentity? {
        let (installed, unavailable) = state.withLock { ($0.ownIdentity, $0.identityUnavailable) }
        if unavailable { return nil }
        if let installed { return ConnectIdentity(identity: installed, ownList: nil) }
        do {
            if let restored = try installPendingIdentity() { return ConnectIdentity(identity: restored, ownList: nil) }
        } catch {
            markIdentityUnavailable()
            log.warning("OMEMO identity could not be restored")
            log.debug("OMEMO identity could not be restored: \(error)")
            return nil
        }
        let ownList: [UInt32]
        let ownLegacyList: [UInt32]
        do {
            ownList = try await fetchDeviceListFromPEP(nil, version: .omemo2) ?? []
            ownLegacyList = try await fetchDeviceListFromPEP(nil, version: .legacy) ?? []
        } catch {
            log.warning("OMEMO own device list could not be read; no device is created yet")
            log.debug("OMEMO own device list could not be read: \(error)")
            throw OMEMOSetupFailure.ownDeviceListUnreadable
        }
        return try ConnectIdentity(identity: generateOwnIdentity(avoiding: ownList + ownLegacyList), ownList: ownList)
    }

    /// Returns `nil` when no identity is pending.
    @discardableResult
    private func installPendingIdentity() throws -> OwnIdentity? {
        guard let pending = state.withLock({ $0.pendingIdentity }) else { return nil }
        let identity = try restoreIdentity(from: pending)
        state.withLock {
            $0.pendingIdentity = nil
            $0.ownIdentity = identity
        }
        return identity
    }

    private func restoreIdentity(from data: OMEMOIdentityData) throws -> OwnIdentity {
        let context = state.withLock { $0.context }
        guard let connectedJID = context?.connectedJID() else {
            throw OMEMOModuleError.notSetUp
        }
        let identityKeyPair = try OMEMOIdentityKeyPair(rawRepresentation: data.identityKeyRaw)
        let signedPreKey = try OMEMOSignedPreKey(
            keyID: data.signedPreKeyID,
            rawRepresentation: data.signedPreKeyRaw,
            signature: data.signedPreKeySignature
        )
        let preKeys = try data.preKeys.map {
            try OMEMOPreKey(keyID: $0.keyID, rawRepresentation: $0.keyRaw)
        }
        return try OwnIdentity(
            deviceID: OMEMODeviceID(value: data.deviceID),
            identityKeyPair: identityKeyPair,
            signedPreKey: signedPreKey,
            retainedSignedPreKeys: data.retainedSignedPreKeys.map(OMEMOSignedPreKey.init),
            preKeys: preKeys,
            connectedJID: connectedJID
        )
    }

    func generateOwnIdentity(avoiding listedDeviceIDs: [UInt32]) throws -> OwnIdentity {
        var deviceID = drawDeviceID()
        while listedDeviceIDs.contains(deviceID.value) {
            deviceID = drawDeviceID()
        }
        let identityKeyPair = OMEMOIdentityKeyPair()
        let signedPreKey = try OMEMOPreKeyManager.generateSignedPreKey(
            keyID: 1, identityKey: identityKeyPair
        )
        let preKeys = OMEMOPreKeyManager.generatePreKeys(
            startID: 1, count: OMEMOPreKeyManager.targetPreKeyCount
        )
        let context = state.withLock { $0.context }
        guard let connectedJID = context?.connectedJID() else {
            throw OMEMOModuleError.notSetUp
        }
        return OwnIdentity(
            deviceID: deviceID,
            identityKeyPair: identityKeyPair,
            signedPreKey: signedPreKey,
            preKeys: preKeys,
            connectedJID: connectedJID
        )
    }

    func requireOwnIdentity() throws -> OwnIdentity {
        guard let identity = state.withLock({ $0.ownIdentity }) else {
            throw OMEMOModuleError.notSetUp
        }
        return identity
    }

    // MARK: - Bundle Management

    /// Pre-keys a contact used stay in the identity for decryption until the connection ends, but leave the bundle.
    static func publishablePreKeyIDs(of identity: OwnIdentity, used: Set<UInt32>) -> Set<UInt32> {
        Set(identity.preKeys.map(\.keyID)).subtracting(used)
    }

    private func publishCurrentBundle() async throws {
        let current = state.withLock { state in
            state.ownIdentity.map { ($0, Self.publishablePreKeyIDs(of: $0, used: state.usedPreKeyIDs)) }
        }
        guard let (identity, preKeyIDs) = current else { throw OMEMOModuleError.notSetUp }
        try await publishOwnBundle(identity, preKeyIDs: preKeyIDs)
        state.withLock { state in
            // A disconnect during the publish reset this module, so what it published no longer counts.
            guard state.ownIdentity != nil else { return }
            state.publishedPreKeyIDs = preKeyIDs
            state.publishedSignedPreKeyID = identity.signedPreKey.keyID
        }
    }

    private func publishOwnBundle(
        _ identity: OwnIdentity, preKeyIDs: Set<UInt32>
    ) async throws {
        let bundle = OMEMOPreKeyManager.buildBundle(
            deviceID: identity.deviceID,
            identityKeyPair: identity.identityKeyPair,
            signedPreKey: identity.signedPreKey,
            preKeys: identity.preKeys.filter { preKeyIDs.contains($0.keyID) }
        )
        let payload = buildBundleElement(bundle)
        // Every device's bundle is an item of one node, which keeps as many items as there are devices.
        try await pepModule.publishItem(
            node: XMPPNamespaces.omemoBundles, itemID: "\(identity.deviceID.value)",
            payload: payload, options: pepPublishOptions(maxItems: "max")
        )
    }

    // MARK: - Stale Bundle Pruning

    func pruneStaleBundles(ownDeviceID: UInt32, ownDeviceList: [UInt32]) async throws -> [UInt32] {
        let context = state.withLock { state in
            OMEMOMaintenance.PruneContext(
                provider: state.seenDeviceClassificationProvider,
                accountID: state.seenDeviceClassificationAccountID,
                retractGuard: state.emergencyRetractGuard,
                retractConfirmation: state.emergencyRetractConfirmation,
                orphanPurger: state.orphanDeviceRecordPurger
            )
        }
        let maintenance = OMEMOMaintenance(context: context, operations: .init(
            fetchBundlePayload: { [self] deviceID in
                try await pepModule.retrieveItems(node: XMPPNamespaces.omemoBundles, from: nil, itemID: "\(deviceID)").first?.payload
            },
            isValidBundle: { [self] payload, deviceID in parseBundleElement(payload, deviceID: deviceID) != nil },
            publishDeviceList: { [self] devices in try await publishDeviceList(devices, version: .omemo2) },
            retractBundle: { [self] deviceID in
                try await pepModule.retractItem(node: XMPPNamespaces.omemoBundles, itemID: "\(deviceID)")
            },
            cacheDeviceList: { [self] devices in
                let connectedJID = state.withLock { $0.context?.connectedJID()?.bareJID }
                if let connectedJID { state.withLock { $0.deviceLists[.omemo2, default: [:]][connectedJID] = devices } }
            }
        ))
        return try await maintenance.pruneStaleBundles(ownDeviceID: ownDeviceID, ownDeviceList: ownDeviceList)
    }

    /// The bundle `jid`'s device `deviceID` publishes for `version`: an item of the one OMEMO 2 bundles node, or the
    /// item of the device's own legacy bundle node.
    func fetchBundle(
        from jid: BareJID, deviceID: UInt32, version: OMEMOWireFormat
    ) async throws -> OMEMOBundle {
        let bundle: OMEMOBundle? = switch version {
        case .omemo2:
            try await pepModule.retrieveItems(node: XMPPNamespaces.omemoBundles, from: jid, itemID: "\(deviceID)")
                .first.flatMap { parseBundleElement($0.payload, deviceID: deviceID) }
        case .legacy:
            try await pepModule.retrieveItems(node: XMPPNamespaces.omemoLegacyBundles(deviceID: deviceID), from: jid, maxItems: 1)
                .first.flatMap { parseLegacyBundleElement($0.payload, deviceID: deviceID) }
        }
        guard let bundle else { throw OMEMOModuleError.bundleNotFound }
        return bundle
    }

    // MARK: - Encryption

    private func encryptKeyForDevice(
        keyMaterial: [UInt8], jid: BareJID,
        deviceID: UInt32, identity: OwnIdentity, version: OMEMOWireFormat
    ) async throws -> EncryptionResult {
        let sessionKey = SessionKey(jid: jid, deviceID: deviceID, version: version)
        let established = try await getOrEstablishSession(
            sessionKey: sessionKey, identity: identity
        )
        // Encrypts with the stored session under one lock, so what a message or key exchange changed in it meanwhile stays.
        let built = try state.withLock { state in
            var session = state.sessions[sessionKey] ?? established
            try state.trustGuard.admitSession(with: sessionKey.device, fingerprint: session.peerFingerprint).check()
            let built = try session.encryptKey(keyMaterial)
            state.sessions[sessionKey] = session
            return built
        }
        return EncryptionResult(
            keyElement: keyElement(deviceID: deviceID, data: built.data, isKex: built.isKex, version: version), sessionKey: sessionKey
        )
    }

    // MARK: - Session Management

    private func getOrEstablishSession(
        sessionKey: SessionKey, identity: OwnIdentity
    ) async throws -> OMEMOSession {
        if let existing = state.withLock({ $0.sessions[sessionKey] }) {
            return existing
        }
        return try await establishSession(
            sessionKey: sessionKey, identity: identity
        )
    }

    private func establishSession(
        sessionKey: SessionKey, identity: OwnIdentity
    ) async throws -> OMEMOSession {
        let bundle = try await fetchBundle(
            from: sessionKey.jid, deviceID: sessionKey.deviceID, version: sessionKey.version
        )
        return try establishSession(sessionKey: sessionKey, identity: identity, bundle: bundle)
    }

    /// Builds a session in `sessionKey`'s version from the device's `bundle` and installs it, unless a session appeared
    /// meanwhile. A bundle whose key contradicts the one held for the device or, with none held, the key of the device's
    /// session in another version is refused. Throws `notSetUp`, installing nothing, once the module lost its identity,
    /// as a disconnect leaves it.
    func establishSession(
        sessionKey: SessionKey, identity: OwnIdentity, bundle: OMEMOBundle
    ) throws -> OMEMOSession {
        // XEP-0384 rejects a key exchange without a pre-key, so a bundle that lists none is as good as missing.
        guard let selectedPreKey = bundle.preKeys.randomElement() else {
            throw OMEMOModuleError.bundleNotFound
        }
        let peerBundle = OMEMOX3DHPeerBundle(
            identityKey: bundle.identityKey,
            signedPreKey: bundle.signedPreKey,
            signedPreKeySignature: bundle.signedPreKeySignature,
            oneTimePreKey: selectedPreKey.publicKey
        )
        let format = sessionKey.version
        let x3dhResult = try OMEMOX3DH.initiatorKeyAgreement(
            identityKeyPair: identity.identityKeyPair,
            peerBundle: peerBundle,
            format: format
        )
        let keyExchange = try OMEMOKeyExchangeHeader(
            preKeyID: selectedPreKey.id,
            signedPreKeyID: bundle.signedPreKeyID,
            identityKey: OMEMOX3DH.identityKey(of: identity.identityKeyPair, format: format),
            ephemeralKey: x3dhResult.ephemeralPublicKey
        )
        let session = try OMEMOSession(
            ratchet: OMEMODoubleRatchetSession(
                asInitiatorWithSharedSecret: x3dhResult.sharedSecret,
                peerSignedPreKey: bundle.signedPreKey,
                format: format
            ),
            associatedData: x3dhResult.associatedData,
            start: .sent(keyExchange, isConfirmed: false)
        )
        // A key exchange from the device can have started a session while the bundle was fetched. That session wins,
        // since the device already uses it, and the discarded bundle's key is never held.
        let (kept, context) = try state.withLock { state -> (OMEMOSession?, ModuleContext?) in
            guard state.ownIdentity != nil else { throw OMEMOModuleError.notSetUp }
            if let kept = state.sessions[sessionKey] { return (kept, nil) }
            try state.trustGuard.admitSession(
                with: sessionKey.device, fingerprint: omemoFingerprint(of: bundle.identityKey, format: session.format),
                standIn: Self.existingSession(for: sessionKey, in: state.sessions)
            ).check()
            state.sessions[sessionKey] = session
            state.liveSessionKeys.insert(sessionKey)
            return (nil, state.context)
        }
        if let kept { return kept }
        context?.emitEvent(.omemoSessionEstablished(
            jid: sessionKey.jid, deviceID: sessionKey.deviceID, version: session.format,
            identityKey: bundle.identityKey, consumedPreKeyID: nil
        ))
        return session
    }

    func randomBytes(_ count: Int) -> [UInt8] {
        (0 ..< count).map { _ in UInt8.random(in: 0 ... 255) }
    }
}

// MARK: - Public Types

public extension OMEMOModule {
    /// Elements to attach to an outgoing message for OMEMO encryption: one `<encrypted>` element for each version some
    /// recipient device receives the message in, at least one of them.
    struct EncryptedMessageElements: Sendable {
        /// `<encrypted xmlns='urn:xmpp:omemo:2'>` with header and payload, for the devices that list OMEMO 2. Nil when
        /// none of them receives the message.
        public let omemo2Encrypted: XMLElement?
        /// `<encrypted xmlns='eu.siacs.conversations.axolotl'>`, whose payload is the body alone, for the devices that
        /// list only legacy OMEMO. Nil when none of them receives the message.
        public let legacyEncrypted: XMLElement?
        /// `<encryption xmlns='urn:xmpp:eme:0'>` (XEP-0380), naming OMEMO 2 when its element is present, else legacy OMEMO.
        public let encryption: XMLElement
        /// Devices skipped because no bundle was fetchable (`item-not-found` / `bundleNotFound`). Non-empty signals partial coverage.
        public let droppedRecipients: [DroppedOMEMORecipient]

        public init(
            omemo2Encrypted: XMLElement?,
            legacyEncrypted: XMLElement?,
            encryption: XMLElement,
            droppedRecipients: [DroppedOMEMORecipient] = []
        ) {
            self.omemo2Encrypted = omemo2Encrypted
            self.legacyEncrypted = legacyEncrypted
            self.encryption = encryption
            self.droppedRecipients = droppedRecipients
        }
    }

    /// Serializable identity data for persistent storage.
    struct OMEMOIdentityData: Sendable {
        public let deviceID: UInt32
        /// Ed25519 seed (32 bytes).
        public let identityKeyRaw: [UInt8]
        public let signedPreKeyID: UInt32
        /// X25519 private key raw (32 bytes).
        public let signedPreKeyRaw: [UInt8]
        /// Ed25519 signature over the signed pre-key (64 bytes).
        public let signedPreKeySignature: [UInt8]
        public let preKeys: [PreKeyData]
        /// The older signed pre-keys this device still takes key exchanges for, besides the current one.
        public let retainedSignedPreKeys: [SignedPreKeyData]

        public struct PreKeyData: Sendable {
            public let keyID: UInt32
            /// X25519 private key raw (32 bytes).
            public let keyRaw: [UInt8]

            public init(keyID: UInt32, keyRaw: [UInt8]) {
                self.keyID = keyID
                self.keyRaw = keyRaw
            }
        }

        public struct SignedPreKeyData: Sendable {
            public let keyID: UInt32
            /// X25519 private key raw (32 bytes).
            public let keyRaw: [UInt8]
            /// Ed25519 signature over the signed pre-key (64 bytes).
            public let signature: [UInt8]

            public init(keyID: UInt32, keyRaw: [UInt8], signature: [UInt8]) {
                self.keyID = keyID
                self.keyRaw = keyRaw
                self.signature = signature
            }
        }

        public init(
            deviceID: UInt32,
            identityKeyRaw: [UInt8],
            signedPreKeyID: UInt32,
            signedPreKeyRaw: [UInt8],
            signedPreKeySignature: [UInt8],
            preKeys: [PreKeyData],
            retainedSignedPreKeys: [SignedPreKeyData] = []
        ) {
            self.deviceID = deviceID
            self.identityKeyRaw = identityKeyRaw
            self.signedPreKeyID = signedPreKeyID
            self.signedPreKeyRaw = signedPreKeyRaw
            self.signedPreKeySignature = signedPreKeySignature
            self.preKeys = preKeys
            self.retainedSignedPreKeys = retainedSignedPreKeys
        }
    }

    /// Serializable session entry for persistent storage.
    struct StoredSessionEntry: Sendable {
        public let jid: BareJID
        public let deviceID: UInt32
        /// The OMEMO version the session speaks, which its record has to be in.
        public let version: OMEMOWireFormat
        /// Serialized `OMEMOSession` bytes.
        public let sessionData: [UInt8]
        /// X3DH associated data (64 bytes in OMEMO 2, 66 in legacy).
        public let associatedData: [UInt8]

        public init(jid: BareJID, deviceID: UInt32, version: OMEMOWireFormat, sessionData: [UInt8], associatedData: [UInt8]) {
            self.jid = jid
            self.deviceID = deviceID
            self.version = version
            self.sessionData = sessionData
            self.associatedData = associatedData
        }
    }
}

// MARK: - Identity Persistence

/// Stores a newly generated identity with its keys, keyed by the opaque `accountID` the module was configured with.
/// Returns whether the identity was stored. With a persister configured, the module uses a new identity only once it
/// was stored.
package protocol OMEMOIdentityPersisting: Sendable {
    func persistNewIdentity(_ data: OMEMOModule.OMEMOIdentityData, accountID: String) async -> Bool
}

/// What `OMEMOService` uses to keep the module's pre-keys and published bundle in step, as a protocol so unit tests can
/// drive that upkeep through a stub.
package protocol OMEMOPreKeyMaintaining: Sendable {
    var ownIdentityData: OMEMOModule.OMEMOIdentityData? { get }
    func consumedPreKeyIDs() -> Set<UInt32>
    var bundleNeedsPublish: Bool { get }
    func addPreKeys(_ preKeys: [OMEMOPreKey])
    func retirePreKeys(_ keyIDs: Set<UInt32>)
    func installSignedPreKeys(
        current: OMEMOModule.OMEMOIdentityData.SignedPreKeyData, retained: [OMEMOModule.OMEMOIdentityData.SignedPreKeyData]
    ) throws
    func republishBundle() async throws
}

extension OMEMOModule: OMEMOPreKeyMaintaining {}

// MARK: - Seen Device Classification

/// Bundle probe outcome: `.healthy`, `.stale` (missing/unparseable), or `.transient` (ambiguous — do not act).
package enum BundleClassification: String, Codable {
    case stale
    case healthy
    case transient
}

/// Per-device record carried across reconnects to gate auto-retract on a
/// two-stale healthy-observation lineage. `hasObservedHealthy` is
/// load-bearing: without it, `(.stale, staleStreak: 2)` produced by
/// `unseen → stale → stale` is indistinguishable from the same shape
/// produced by `healthy → stale → stale`, and the gate would retract a
/// sibling whose bundle simply hasn't been published yet.
package struct SeenDeviceRecord: Equatable, Codable {
    package let deviceID: UInt32
    package let lastClassification: BundleClassification
    /// Consecutive `.stale` observations since the last `.healthy` (or since
    /// the lineage began for an `unseen → stale → …` trajectory).
    package let staleStreak: Int
    /// `true` once `.healthy` has been recorded at any prior cycle. The
    /// retract gate fires only when both this is true and the streak reaches
    /// the threshold.
    package let hasObservedHealthy: Bool

    package init(
        deviceID: UInt32,
        lastClassification: BundleClassification,
        staleStreak: Int,
        hasObservedHealthy: Bool
    ) {
        self.deviceID = deviceID
        self.lastClassification = lastClassification
        self.staleStreak = staleStreak
        self.hasObservedHealthy = hasObservedHealthy
    }
}

/// Read/write access to the per-account seen-device classification cache.
/// See `OMEMOService.seenDeviceCacheByAccount` for the cache-survival rationale and the opaque-`accountID` contract.
/// Non-throwing — the service-side implementation absorbs `OMEMOStore` errors so the prune pipeline does not abort.
package protocol SeenDeviceClassificationProviding: Sendable {
    /// Returns the cache for `accountID`, lazy-loading from the store on first read; coalesces concurrent first-loads.
    func loadSeenDevices(accountID: String) async -> [UInt32: SeenDeviceRecord]

    /// Merges per-device updates (last-write-wins per deviceID) and upserts only the delta rows.
    func mergeSeenDevices(_ updates: [UInt32: SeenDeviceRecord], accountID: String) async

    /// Drops rows whose deviceID is not in `currentDeviceIDs` — defends against the "old healthy survives after disappearance" attack.
    func clearSeenDevicesAbsent(from currentDeviceIDs: Set<UInt32>, accountID: String) async

    /// Wholesale replace. Used by emergency-retract to install a singleton baseline; delta-merge would leave old sibling rows and re-trigger the gate.
    func replaceSeenDevices(_ records: [UInt32: SeenDeviceRecord], accountID: String) async
}

/// Returned from the over-cap emergency-retract confirmation closure; `true` authorizes publish-singleton + retract + cleanup.
package typealias EmergencyRetractConfirmation = @Sendable (_ deviceCount: Int, _ ownDeviceID: UInt32) async -> Bool

/// Service-side reentrancy guard for the emergency-retract path.
/// Lives on `OMEMOService` so the in-flight flag survives a mid-retract module rebuild (see `seenDeviceCacheByAccount` for the same reconnect rationale).
package protocol EmergencyRetractGuarding: Sendable {
    /// Atomically checks and sets the in-flight flag. Returns `true` iff the caller claimed it.
    func tryClaimInFlight(accountID: String) async -> Bool

    /// Clears the in-flight flag. Called via `defer` across the entire publish/retract path.
    func releaseInFlight(accountID: String) async
}

/// Cleans up trust/session rows for own-deviceIDs that were retracted via
/// the emergency-retract path. Defense in depth beside encryption, which
/// wraps keys only for devices still on the account's lists: orphan rows in
/// the store would let an offline-restored backup target retracted device
/// IDs whose bundles are still locally cached.
package protocol OrphanDeviceRecordPurging: Sendable {
    func purgeOrphanDeviceRecords(deviceIDs: [UInt32], accountID: String) async throws
}

// MARK: - Errors

/// Errors from OMEMO protocol operations. Cryptographic failures surface as `.cryptographicFailure`.
public enum OMEMOModuleError: Error, Equatable {
    case notSetUp
    case bundleNotFound
    case noSession
    case notForThisDevice
    /// A key exchange named no one-time pre-key, or one this device no longer holds.
    case unknownPreKey
    /// A key exchange this connection already took up arrived again.
    case replayedKeyExchange
    /// The device is marked untrusted, so no key exchange from it is taken up and nothing is encrypted for it.
    case untrustedDevice
    /// The device's identity key is not the one held for it, or cannot be read.
    case changedIdentityKey
    case invalidKeyData
    case invalidHeader
    case invalidPayload
    /// No peer device received a key, as when every listed device's bundle
    /// was missing. The message was not sent.
    case noUsableRecipientDevices
    case cryptographicFailure(String)

    /// Maps `OMEMOCryptoError` and `CryptoKitError` to `.cryptographicFailure` so callers get readable text.
    /// Every other error passes through unchanged.
    static func translatingCryptoFailure(_ error: any Error) -> any Error {
        switch error {
        case let cryptoError as OMEMOCryptoError:
            OMEMOModuleError.cryptographicFailure(cryptoError.displayText)
        case is CryptoKitError:
            // OMEMO only hits CryptoKit throws when building, signing with, or agreeing on a stored or peer key,
            // so one fixed phrase covers them.
            OMEMOModuleError.cryptographicFailure("The encryption keys are invalid or unusable")
        default:
            error
        }
    }
}

// MARK: - Private Types

struct OwnIdentity {
    let deviceID: OMEMODeviceID
    let identityKeyPair: OMEMOIdentityKeyPair
    var signedPreKey: OMEMOSignedPreKey
    /// The older signed pre-keys a key exchange may still name, kept for a period after a rotation.
    var retainedSignedPreKeys: [OMEMOSignedPreKey] = []
    var preKeys: [OMEMOPreKey]
    let connectedJID: FullJID
}
