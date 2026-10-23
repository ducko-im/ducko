import CryptoKit
import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.omemo")

/// Implements XEP-0384 OMEMO Encryption and XEP-0380 Explicit Message Encryption.
///
/// Manages device lists, bundles, session establishment (X3DH), and
/// per-message encryption/decryption (Double Ratchet + AES-256-CBC).
/// Uses PEPModule for all PubSub operations.
public final class OMEMOModule: XMPPModule, Sendable {
    // MARK: - State

    struct State {
        var context: ModuleContext?
        var deviceLists: [BareJID: [UInt32]] = [:]
        var ownIdentity: OwnIdentity?
        var pendingIdentity: OMEMOIdentityData?
        /// Set when the stored keys could not be read, so this connection neither generates a device nor publishes.
        var identityUnavailable = false
        var sessions: [SessionKey: OMEMOSession] = [:]
        var usedPreKeyIDs: Set<UInt32> = []
        /// The key exchanges this connection took up, so a replayed one cannot build a session again.
        var acceptedKeyExchanges: Set<[UInt8]> = []
        /// The ratchet keys whose chains this connection sent a heartbeat for.
        var heartbeatChains: Set<[UInt8]> = []
        /// The pre-key ids of this module's last successful bundle publish.
        var publishedPreKeyIDs: Set<UInt32>?
        /// The latest bundle publish. Each publish waits for the one before it.
        var bundlePublish: Task<Void, any Error>?
        /// Replaced by the account's guard, which outlives this module, before the module connects.
        var trustGuard = OMEMOTrustGuard()
        /// See `OMEMOService.seenDeviceCacheByAccount` for the cache-survival rationale and the opaque-`accountID` contract.
        var seenDeviceClassificationProvider: (any SeenDeviceClassificationProviding)?
        var seenDeviceClassificationAccountID: String?
        var emergencyRetractGuard: (any EmergencyRetractGuarding)?
        var emergencyRetractConfirmation: EmergencyRetractConfirmation?
        var orphanDeviceRecordPurger: (any OrphanDeviceRecordPurging)?
        var registrationRetryTask: Task<Void, Never>?
    }

    let state: OSAllocatedUnfairLock<State>
    private let pepModule: PEPModule
    /// Tells room occupants' real addresses, whose sessions decrypt their room messages.
    let mucModule: MUCModule?
    private let registrationRetryDelays: [Duration]

    public var features: [String] {
        [XMPPNamespaces.omemo, XMPPNamespaces.eme]
    }

    public convenience init(pepModule: PEPModule, mucModule: MUCModule? = nil) {
        self.init(pepModule: pepModule, mucModule: mucModule, registrationRetryDelays: [.seconds(10), .seconds(60), .seconds(300)])
    }

    init(pepModule: PEPModule, mucModule: MUCModule? = nil, registrationRetryDelays: [Duration]) {
        self.pepModule = pepModule
        self.mucModule = mucModule
        self.registrationRetryDelays = registrationRetryDelays
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    // MARK: - XMPPModule

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    /// Installs the configured identity, because the session's stanzas can reach `handleMessage` before `handleConnect`
    /// runs, and a resumed session never runs it.
    public func handleSessionEstablished(resumed: Bool) {
        guard !state.withLock({ $0.identityUnavailable }) else { return }
        do {
            try installPendingIdentity()
        } catch {
            markIdentityUnavailable()
            log.warning("OMEMO identity could not be restored")
            log.debug("OMEMO identity could not be restored: \(error)")
        }
    }

    public func handleConnect() async throws {
        let identity: OwnIdentity
        let ownListKnown: Bool
        do {
            // A nil identity means the stored keys were unreadable, which whoever found that has logged.
            guard let connectIdentity = try connectIdentity() else { return }
            identity = connectIdentity
            ownListKnown = try await ensureOwnDeviceInList(identity.deviceID)
            try await republishBundle()
        } catch {
            throw OMEMOModuleError.translatingCryptoFailure(error)
        }
        let deviceID = identity.deviceID.value
        log.info("OMEMO setup complete, device ID: \(deviceID)")
        // Pruning against a guessed list would clear the seen-device records of every sibling device.
        guard ownListKnown else {
            retryOwnDeviceRegistration(identity.deviceID)
            return
        }

        // Best-effort defense-in-depth pass against PEP entries whose bundles
        // are missing — never aborts the connect chain.
        let ownList = state.withLock { $0.deviceLists[identity.connectedJID.bareJID] ?? [deviceID] }
        do {
            _ = try await pruneStaleBundles(ownDeviceID: deviceID, ownDeviceList: ownList)
        } catch let stanzaError as XMPPStanzaError {
            log.warning("OMEMO stale-bundle pruning failed: \(stanzaError.condition.rawValue)")
        } catch {
            log.warning("OMEMO stale-bundle pruning failed")
            log.debug("OMEMO stale-bundle pruning failed: \(error)")
        }
    }

    public func handleDisconnect() async {
        let registrationRetryTask = state.withLock { state in
            defer { state.registrationRetryTask = nil }
            return state.registrationRetryTask
        }
        registrationRetryTask?.cancel()
        state.withLock {
            $0.ownIdentity = nil
            $0.identityUnavailable = false
            $0.deviceLists.removeAll()
            $0.sessions.removeAll()
            $0.usedPreKeyIDs.removeAll()
            $0.acceptedKeyExchanges.removeAll()
            $0.heartbeatChains.removeAll()
            $0.publishedPreKeyIDs = nil
            $0.seenDeviceClassificationProvider = nil
            $0.seenDeviceClassificationAccountID = nil
            $0.emergencyRetractGuard = nil
            $0.emergencyRetractConfirmation = nil
            $0.orphanDeviceRecordPurger = nil
        }
    }

    public func handleMessage(_ message: XMPPMessage) throws {
        handleDeviceListNotification(message)
        handleEncryptedMessage(message)
    }

    // MARK: - Public API

    public var ownIdentityData: OMEMOIdentityData? {
        state.withLock { state in
            guard let identity = state.ownIdentity else { return nil }
            return OMEMOIdentityData(
                deviceID: identity.deviceID.value,
                identityKeyRaw: identity.identityKeyPair.rawRepresentation,
                signedPreKeyID: identity.signedPreKey.keyID,
                signedPreKeyRaw: identity.signedPreKey.rawRepresentation,
                signedPreKeySignature: identity.signedPreKey.signature,
                preKeys: identity.preKeys.map {
                    OMEMOIdentityData.PreKeyData(keyID: $0.keyID, keyRaw: $0.rawRepresentation)
                }
            )
        }
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

    /// Whether the bundle this connection last published lags behind the pre-keys this device can hand out, as when
    /// nothing was published yet or keys were used up or added since. A failed publish leaves the last published set in
    /// place.
    package var bundleNeedsPublish: Bool {
        state.withLock { state in
            guard let identity = state.ownIdentity else { return false }
            return state.publishedPreKeyIDs != Self.publishablePreKeyIDs(of: identity, used: state.usedPreKeyIDs)
        }
    }

    /// Publishes the bundle as the identity stands when the publish starts. Publishes never overlap: one asked for
    /// during another starts once it ends. Each runs in a task of its own, so a caller's cancellation fails no publish.
    package func republishBundle() async throws {
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

    /// Restores previously persisted sessions into the module's in-memory state. A session that fails to decode counts
    /// as no session.
    public func restoreSessions(_ entries: [StoredSessionEntry]) {
        let undecodable = state.withLock { state in
            var undecodable = 0
            for entry in entries {
                if let session = try? OMEMOSession(serialized: entry.sessionData, associatedData: entry.associatedData) {
                    state.sessions[SessionKey(jid: entry.jid, deviceID: entry.deviceID)] = session
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

    /// Exports a single session's state for persistent storage.
    public func exportSession(jid: BareJID, deviceID: UInt32) -> StoredSessionEntry? {
        state.withLock { state in
            let key = SessionKey(jid: jid, deviceID: deviceID)
            guard let session = state.sessions[key] else { return nil }
            return StoredSessionEntry(
                jid: jid, deviceID: deviceID,
                sessionData: session.serialized, associatedData: session.associatedData
            )
        }
    }

    /// Exports all sessions for persistent storage (e.g., on disconnect).
    public func allSessionEntries() -> [StoredSessionEntry] {
        state.withLock { state in
            state.sessions.map { key, session in
                StoredSessionEntry(
                    jid: key.jid, deviceID: key.deviceID,
                    sessionData: session.serialized, associatedData: session.associatedData
                )
            }
        }
    }

    /// Fetches device IDs for a JID. Cache hit is silent; pass `forceRefresh: true` to pull from PEP and emit
    /// `.omemoDeviceListReceived` (so trust store / UI observe it as they would a +notify).
    public func fetchDeviceList(
        for jid: BareJID, forceRefresh: Bool = false
    ) async throws -> [UInt32] {
        if !forceRefresh, let cached = state.withLock({ $0.deviceLists[jid] }) {
            return cached
        }
        let devices = try await fetchDeviceListFromPEP(jid)
        let context = state.withLock { state in
            state.deviceLists[jid] = devices
            return state.context
        }
        if forceRefresh {
            context?.emitEvent(.omemoDeviceListReceived(jid: jid, devices: devices))
        }
        return devices
    }

    /// Encrypts a 1:1 message's `content`, the elements it would carry in the clear, sent at `time` (XEP-0082).
    /// `recipientDeviceIDs`/`ownDeviceIDs` nil means "all known".
    public func encryptMessage(
        content: [XMLElement],
        time: String,
        to recipientJID: BareJID,
        recipientDeviceIDs: [UInt32]? = nil,
        ownDeviceIDs: [UInt32]? = nil
    ) async throws -> EncryptedMessageElements {
        let recipientDevices: [UInt32] = if let recipientDeviceIDs {
            recipientDeviceIDs
        } else {
            try await fetchDeviceList(for: recipientJID)
        }
        return try await encryptForDevices(
            content: content, time: time,
            peerDevices: recipientDevices.map { (jid: recipientJID, deviceID: $0) },
            ownDeviceIDs: ownDeviceIDs,
            conversation: recipientJID
        )
    }

    /// Encrypts a group message's `content`, sent at `time`. `roomJID` labels emitted `omemoRecipientsPartial` events for
    /// correlation.
    public func encryptGroupMessage(
        content: [XMLElement],
        time: String,
        roomJID: BareJID,
        recipients: [(jid: BareJID, deviceIDs: [UInt32])],
        ownDeviceIDs: [UInt32]? = nil
    ) async throws -> EncryptedMessageElements {
        let peerDevices = recipients.flatMap { r in r.deviceIDs.map { (jid: r.jid, deviceID: $0) } }
        return try await encryptForDevices(
            content: content, time: time,
            peerDevices: peerDevices,
            ownDeviceIDs: ownDeviceIDs,
            conversation: roomJID
        )
    }

    /// Shared encrypt pipeline. Throws `noUsableRecipientDevices` when every peer bundle was missing — empty-PEP-list
    /// and all-item-not-found are otherwise indistinguishable from a silent drop. `conversation`, the peer or the room,
    /// is the envelope's recipient and labels emitted `omemoRecipientsPartial` events.
    private func encryptForDevices(
        content: [XMLElement], time: String,
        peerDevices: [(jid: BareJID, deviceID: UInt32)],
        ownDeviceIDs: [UInt32]?,
        conversation: BareJID
    ) async throws -> EncryptedMessageElements {
        do {
            let identity = try requireOwnIdentity()
            let envelope = SCEEnvelope.build(content: content, time: time, to: conversation, from: identity.connectedJID.bareJID)
            let payload = try OMEMOPayload(encrypting: envelope, key: randomBytes(OMEMOPayload.keyLength))
            let peerEncryption = try await encryptKeysInParallel(
                keyMaterial: payload.keyMaterial, identity: identity, devices: peerDevices
            )
            var results = peerEncryption.results
            if results.isEmpty {
                // Surface the dropped peer devices before throwing so operators
                // see the same diagnostic in the worst case (every recipient
                // device unfetchable) as in partial-coverage cases. The throw
                // would otherwise hide the dropped set entirely.
                emitDroppedRecipientsEventIfNeeded(
                    conversation: conversation, dropped: peerEncryption.dropped
                )
                throw OMEMOModuleError.noUsableRecipientDevices
            }
            let ownEncryption = try await encryptKeyForOwnDevices(
                keyMaterial: payload.keyMaterial, identity: identity, ownDeviceIDs: ownDeviceIDs
            )
            results += ownEncryption.results
            let keys = results.map { (jid: $0.sessionKey.jid, key: $0.keyElement) }
            let droppedRecipients = peerEncryption.dropped + ownEncryption.dropped
            let elements = buildEncryptedElements(
                keys: keys, payload: Base64.encode(payload.ciphertext), senderDeviceID: identity.deviceID.value,
                droppedRecipients: droppedRecipients
            )
            emitDroppedRecipientsEventIfNeeded(conversation: conversation, dropped: droppedRecipients)
            return elements
        } catch {
            throw OMEMOModuleError.translatingCryptoFailure(error)
        }
    }

    private struct EncryptionResult {
        let keyElement: XMLElement
        let sessionKey: SessionKey
    }

    /// Encryption results plus the subset dropped because no bundle could be fetched (surfaced via `omemoRecipientsPartial`).
    private struct EncryptionBatch {
        var results: [EncryptionResult]
        var dropped: [DroppedOMEMORecipient]
    }

    /// Cap on concurrent per-recipient bundle fetches during encrypt. Without bounding, a peer with thousands of
    /// devices saturates SM ack windows (observed at 950+). 64 stays below SM-window pressure while amortizing TLS
    /// handshakes; chunked iteration still completes every device.
    private static let encryptConcurrencyCap = 64

    private func encryptKeysInParallel(
        keyMaterial: [UInt8], identity: OwnIdentity,
        devices: [(jid: BareJID, deviceID: UInt32)]
    ) async throws -> EncryptionBatch {
        assert(
            Set(devices.map { SessionKey(jid: $0.jid, deviceID: $0.deviceID) }).count == devices.count,
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
                                deviceID: device.deviceID, identity: identity
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

    private func encryptKeyForOwnDevices(
        keyMaterial: [UInt8], identity: OwnIdentity,
        ownDeviceIDs: [UInt32]?
    ) async throws -> EncryptionBatch {
        let ownJID = identity.connectedJID.bareJID
        let ownDevices: [UInt32] = if let ownDeviceIDs {
            ownDeviceIDs
        } else {
            try await fetchDeviceList(for: ownJID)
        }
        let filtered = ownDevices.filter { $0 != identity.deviceID.value }
        return try await encryptKeysInParallel(
            keyMaterial: keyMaterial, identity: identity,
            devices: filtered.map { (jid: ownJID, deviceID: $0) }
        )
    }

    private func emitDroppedRecipientsEventIfNeeded(
        conversation: BareJID, dropped: [DroppedOMEMORecipient]
    ) {
        guard !dropped.isEmpty else { return }
        let context = state.withLock { $0.context }
        context?.emitEvent(.omemoRecipientsPartial(conversation: conversation, droppedDevices: dropped))
    }

    private func buildEncryptedElements(
        keys: [(jid: BareJID, key: XMLElement)], payload: String,
        senderDeviceID: UInt32,
        droppedRecipients: [DroppedOMEMORecipient]
    ) -> EncryptedMessageElements {
        let encrypted = buildEncryptedElement(
            keys: keys, payload: payload, senderDeviceID: senderDeviceID
        )
        let encryption = XMLElement(
            name: "encryption",
            namespace: XMPPNamespaces.eme,
            attributes: ["namespace": XMPPNamespaces.omemo]
        )
        return EncryptedMessageElements(
            encrypted: encrypted,
            encryption: encryption,
            droppedRecipients: droppedRecipients
        )
    }

    // MARK: - Identity Generation

    /// The identity a fresh connect works with. Generates a new device only when none was configured. Returns `nil`
    /// when the configured keys could not be read, since replacing them would lose the device.
    private func connectIdentity() throws -> OwnIdentity? {
        let (installed, unavailable) = state.withLock { ($0.ownIdentity, $0.identityUnavailable) }
        if unavailable { return nil }
        if let installed { return installed }
        do {
            if let restored = try installPendingIdentity() { return restored }
        } catch {
            markIdentityUnavailable()
            log.warning("OMEMO identity could not be restored")
            log.debug("OMEMO identity could not be restored: \(error)")
            return nil
        }
        let generated = try generateOwnIdentity()
        state.withLock { $0.ownIdentity = generated }
        return generated
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
        return OwnIdentity(
            deviceID: OMEMODeviceID(value: data.deviceID),
            identityKeyPair: identityKeyPair,
            signedPreKey: signedPreKey,
            preKeys: preKeys,
            connectedJID: connectedJID
        )
    }

    private func generateOwnIdentity() throws -> OwnIdentity {
        let deviceID = OMEMODeviceID.random()
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

    // MARK: - Device List Management

    /// Returns `false` when the server's list could not be read. Nothing is then published or cached, since publishing
    /// over an unread list would drop the other devices from it.
    private func ensureOwnDeviceInList(
        _ deviceID: OMEMODeviceID
    ) async throws -> Bool {
        var devices: [UInt32]
        do {
            devices = try await fetchDeviceListFromPEP(nil)
        } catch let error as XMPPStanzaError where error.condition == .itemNotFound {
            devices = []
        } catch {
            log.warning("OMEMO own device list fetch failed; leaving the device list unchanged")
            log.debug("OMEMO own device list fetch failed: \(error)")
            return false
        }
        if !devices.contains(deviceID.value) {
            devices.append(deviceID.value)
            try await publishDeviceList(devices)
        }
        let finalDevices = devices
        state.withLock {
            if let ownJID = $0.context?.connectedJID()?.bareJID {
                $0.deviceLists[ownJID] = finalDevices
            }
        }
        return true
    }

    /// Retries adding this device to the server's list after the connect-time read failed, so a transient failure
    /// does not leave the device unadvertised for the whole session.
    private func retryOwnDeviceRegistration(_ deviceID: OMEMODeviceID) {
        let delays = registrationRetryDelays
        let task = Task { [weak self] in
            for delay in delays {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                if await (try? ensureOwnDeviceInList(deviceID)) == true { return }
            }
        }
        let previous = state.withLock { state in
            defer { state.registrationRetryTask = task }
            return state.registrationRetryTask
        }
        previous?.cancel()
    }

    private func fetchDeviceListFromPEP(
        _ jid: BareJID?
    ) async throws -> [UInt32] {
        let items = try await pepModule.retrieveItems(
            node: XMPPNamespaces.omemoDevices, from: jid
        )
        guard let item = items.first else { return [] }
        return parseDeviceList(item.payload)
    }

    private func publishDeviceList(
        _ devices: [UInt32]
    ) async throws {
        let payload = buildDeviceListElement(devices)
        try await pepModule.publishItem(
            node: XMPPNamespaces.omemoDevices,
            itemID: "current",
            payload: payload,
            options: pepPublishOptions(maxItems: "1")
        )
    }

    // MARK: - Bundle Management

    /// Pre-keys a contact used stay in the identity for decryption until the connection ends, but leave the bundle.
    private static func publishablePreKeyIDs(of identity: OwnIdentity, used: Set<UInt32>) -> Set<UInt32> {
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

    private func pruneStaleBundles(ownDeviceID: UInt32, ownDeviceList: [UInt32]) async throws -> [UInt32] {
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
            publishDeviceList: { [self] devices in try await publishDeviceList(devices) },
            retractBundle: { [self] deviceID in
                try await pepModule.retractItem(node: XMPPNamespaces.omemoBundles, itemID: "\(deviceID)")
            },
            cacheDeviceList: { [self] devices in
                let connectedJID = state.withLock { $0.context?.connectedJID()?.bareJID }
                if let connectedJID { state.withLock { $0.deviceLists[connectedJID] = devices } }
            }
        ))
        return try await maintenance.pruneStaleBundles(ownDeviceID: ownDeviceID, ownDeviceList: ownDeviceList)
    }

    private func fetchBundle(
        from jid: BareJID, deviceID: UInt32
    ) async throws -> OMEMOBundle {
        let items = try await pepModule.retrieveItems(
            node: XMPPNamespaces.omemoBundles, from: jid, itemID: "\(deviceID)"
        )
        guard let item = items.first,
              let bundle = parseBundleElement(
                  item.payload, deviceID: deviceID
              )
        else {
            throw OMEMOModuleError.bundleNotFound
        }
        return bundle
    }

    // MARK: - Message Handling

    private func handleDeviceListNotification(
        _ message: XMPPMessage
    ) {
        let context = state.withLock { $0.context }
        // A device list is published from its owner's bare JID (XEP-0163), so any other sender publishes nothing.
        guard let event = message.element.child(
            named: "event", namespace: XMPPNamespaces.pubsubEvent
        ), let itemsEl = event.child(named: "items"),
        itemsEl.attribute("node") == XMPPNamespaces.omemoDevices,
        let from = message.bareSender(orOwn: context?.connectedJID()?.bareJID), let item = itemsEl.child(named: "item"),
        let payload = item.children.compactMap({
            if case let .element(el) = $0 { return el }
            return nil
        }).first
        else { return }
        let devices = parseDeviceList(payload)
        state.withLock { $0.deviceLists[from] = devices }
        context?.emitEvent(
            .omemoDeviceListReceived(jid: from, devices: devices)
        )
    }

    // MARK: - Decryption

    func decryptKexKey(_ data: [UInt8], sessionKey: SessionKey) throws -> KeyTransport {
        let kex = try OMEMOKeyExchange(serialized: data)
        // A sender repeats its key exchange until it hears back (XEP-0384 §4.3), so the key exchange that started the
        // session here carries a message for that session. Any other key exchange replaces the session.
        if state.withLock({ $0.sessions[sessionKey]?.isStarted(by: kex.header) }) == true {
            do {
                return try decrypt(kex.message, through: sessionKey)
            } catch OMEMOCryptoError.hmacVerificationFailed {
                // A copy of a message read before, whose key is used up. It changes nothing.
                throw OMEMOModuleError.replayedKeyExchange
            }
        }
        let identity = try requireOwnIdentity()
        guard kex.signedPreKeyID == identity.signedPreKey.keyID else {
            throw OMEMOModuleError.invalidKeyData
        }
        // Checked before anything is assigned, so an existing session stays as it was.
        guard let preKey = identity.preKeys.first(where: { $0.keyID == kex.preKeyID }) else {
            throw OMEMOModuleError.unknownPreKey
        }
        let x3dhResult = try OMEMOX3DH.responderKeyAgreement(
            identityKeyPair: identity.identityKeyPair,
            signedPreKey: identity.signedPreKey,
            oneTimePreKey: preKey,
            peerIdentityKey: kex.identityKey,
            peerEphemeralKey: kex.ephemeralKey
        )
        var session = OMEMOSession(
            ratchet: OMEMODoubleRatchetSession(
                asResponderWithSharedSecret: x3dhResult.sharedSecret,
                ourSignedPreKeyPair: identity.signedPreKey.keyPair
            ),
            associatedData: x3dhResult.associatedData,
            start: .received(kex.header)
        )
        let keyMaterial = try session.decrypt(kex.message)
        let context = try installKeyExchangeSession(
            session,
            exchangeFingerprint: Self.keyExchangeFingerprint(sharedSecret: x3dhResult.sharedSecret, associatedData: x3dhResult.associatedData),
            keyExchange: kex.header, sessionKey: sessionKey, ownDeviceID: identity.deviceID.value
        )
        context?.emitEvent(.omemoSessionEstablished(
            jid: sessionKey.jid, deviceID: sessionKey.deviceID,
            identityKey: kex.identityKey, consumedPreKeyID: preKey.keyID
        ))
        // A new session is confirmed with an empty message (XEP-0384).
        return KeyTransport(keyMaterial: keyMaterial, needsEmptyReply: true)
    }

    /// Installs a session `keyExchange` built, replacing any earlier one with that device (XEP-0384 §5.6), once the trust
    /// guard admits it. A key exchange taken up once comes again only as a replay, whichever device or contact it
    /// claims.
    private func installKeyExchangeSession(
        _ session: OMEMOSession, exchangeFingerprint: [UInt8], keyExchange: OMEMOKeyExchangeHeader, sessionKey: SessionKey, ownDeviceID: UInt32
    ) throws -> ModuleContext? {
        try state.withLock { state in
            guard !state.acceptedKeyExchanges.contains(exchangeFingerprint) else {
                throw OMEMOModuleError.replayedKeyExchange
            }
            let preKey = OMEMOTrustGuard.PreKeyUse(
                id: keyExchange.preKeyID, ownDeviceID: ownDeviceID, isUsedByThisModule: state.usedPreKeyIDs.contains(keyExchange.preKeyID)
            )
            try state.trustGuard.admitKeyExchange(
                from: sessionKey, offeredKey: keyExchange.identityKey, replacing: Self.existingSession(state.sessions[sessionKey]), preKey: preKey
            ).check()
            state.acceptedKeyExchanges.insert(exchangeFingerprint)
            state.sessions[sessionKey] = session
            state.usedPreKeyIDs.insert(keyExchange.preKeyID)
            if let knownDevices = state.deviceLists[sessionKey.jid],
               !knownDevices.contains(sessionKey.deviceID) {
                log.warning("KEX from unannounced device \(sessionKey.deviceID)")
                log.debug("The unannounced device belongs to \(sessionKey.jid)")
            }
            return state.context
        }
    }

    /// Identifies a key exchange by what it derives rather than by its bytes, since one X25519 key has several encodings.
    private static func keyExchangeFingerprint(sharedSecret: [UInt8], associatedData: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Array("OMEMO key exchange".utf8) + sharedSecret + associatedData))
    }

    func decryptExistingSessionKey(
        _ data: [UInt8], sessionKey: SessionKey
    ) throws -> KeyTransport {
        try decrypt(OMEMOAuthenticatedMessage(serialized: data), through: sessionKey)
    }

    /// The session advances only when the message decrypts, under one lock, so a message or key exchange handled
    /// meanwhile is not undone. A session whose key contradicts the one held for the device, or cannot be read while one
    /// is held, decrypts nothing. A message numbered `heartbeatThreshold` or higher on the sender's current ratchet key
    /// asks for a heartbeat, once per key (XEP-0384).
    private func decrypt(_ ratchetMessage: OMEMOAuthenticatedMessage, through sessionKey: SessionKey) throws -> KeyTransport {
        let message = ratchetMessage.message
        return try state.withLock { state in
            guard var session = state.sessions[sessionKey] else {
                throw OMEMOModuleError.noSession
            }
            guard state.trustGuard.admitsDecryption(from: sessionKey, identityKey: session.peerIdentityKey) else {
                throw OMEMOModuleError.changedIdentityKey
            }
            let keyMaterial = try session.decrypt(ratchetMessage)
            state.sessions[sessionKey] = session
            let isHeartbeatDue = message.messageNumber >= Self.heartbeatThreshold && message.dhPublicKey == session.ratchet.dhRecvPublicKey
                && state.heartbeatChains.insert(message.dhPublicKey).inserted
            return KeyTransport(keyMaterial: keyMaterial, needsEmptyReply: isHeartbeatDue)
        }
    }

    // MARK: - Encryption

    private func encryptKeyForDevice(
        keyMaterial: [UInt8], jid: BareJID,
        deviceID: UInt32, identity: OwnIdentity
    ) async throws -> EncryptionResult {
        let sessionKey = SessionKey(jid: jid, deviceID: deviceID)
        let established = try await getOrEstablishSession(
            sessionKey: sessionKey, identity: identity
        )
        // Encrypts with the stored session under one lock, so what a message or key exchange changed in it meanwhile stays.
        let built = try state.withLock { state in
            var session = state.sessions[sessionKey] ?? established
            try state.trustGuard.admitSession(with: sessionKey, identityKey: session.peerIdentityKey).check()
            let built = try session.encryptKey(keyMaterial)
            state.sessions[sessionKey] = session
            return built
        }
        return EncryptionResult(
            keyElement: buildKeyElement(deviceID: deviceID, data: built.data, isKex: built.isKex), sessionKey: sessionKey
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
            from: sessionKey.jid, deviceID: sessionKey.deviceID
        )
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
        let x3dhResult = try OMEMOX3DH.initiatorKeyAgreement(
            identityKeyPair: identity.identityKeyPair,
            peerBundle: peerBundle
        )
        let keyExchange = OMEMOKeyExchangeHeader(
            preKeyID: selectedPreKey.id,
            signedPreKeyID: bundle.signedPreKeyID,
            identityKey: identity.identityKeyPair.publicKeyBytes,
            ephemeralKey: x3dhResult.ephemeralPublicKey
        )
        let session = try OMEMOSession(
            ratchet: OMEMODoubleRatchetSession(
                asInitiatorWithSharedSecret: x3dhResult.sharedSecret,
                peerSignedPreKey: bundle.signedPreKey
            ),
            associatedData: x3dhResult.associatedData,
            start: .sent(keyExchange, isConfirmed: false)
        )
        // A key exchange from the device can have started a session while the bundle was fetched. That session wins,
        // since the device already uses it, and the discarded bundle's key is never held.
        let (kept, context) = try state.withLock { state -> (OMEMOSession?, ModuleContext?) in
            if let kept = state.sessions[sessionKey] { return (kept, nil) }
            try state.trustGuard.admitSession(with: sessionKey, identityKey: bundle.identityKey).check()
            state.sessions[sessionKey] = session
            return (nil, state.context)
        }
        if let kept { return kept }
        context?.emitEvent(.omemoSessionEstablished(
            jid: sessionKey.jid, deviceID: sessionKey.deviceID,
            identityKey: bundle.identityKey, consumedPreKeyID: nil
        ))
        return session
    }

    private func randomBytes(_ count: Int) -> [UInt8] {
        (0 ..< count).map { _ in UInt8.random(in: 0 ... 255) }
    }
}

// MARK: - Public Types

public extension OMEMOModule {
    /// Elements to attach to an outgoing message for OMEMO encryption.
    struct EncryptedMessageElements: Sendable {
        /// `<encrypted xmlns='urn:xmpp:omemo:2'>` with header and payload.
        public let encrypted: XMLElement
        /// `<encryption xmlns='urn:xmpp:eme:0'>` (XEP-0380).
        public let encryption: XMLElement
        /// Devices skipped because no bundle was fetchable (`item-not-found` / `bundleNotFound`). Non-empty signals partial coverage.
        public let droppedRecipients: [DroppedOMEMORecipient]

        public init(
            encrypted: XMLElement,
            encryption: XMLElement,
            droppedRecipients: [DroppedOMEMORecipient] = []
        ) {
            self.encrypted = encrypted
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

        public struct PreKeyData: Sendable {
            public let keyID: UInt32
            /// X25519 private key raw (32 bytes).
            public let keyRaw: [UInt8]

            public init(keyID: UInt32, keyRaw: [UInt8]) {
                self.keyID = keyID
                self.keyRaw = keyRaw
            }
        }

        public init(
            deviceID: UInt32,
            identityKeyRaw: [UInt8],
            signedPreKeyID: UInt32,
            signedPreKeyRaw: [UInt8],
            signedPreKeySignature: [UInt8],
            preKeys: [PreKeyData]
        ) {
            self.deviceID = deviceID
            self.identityKeyRaw = identityKeyRaw
            self.signedPreKeyID = signedPreKeyID
            self.signedPreKeyRaw = signedPreKeyRaw
            self.signedPreKeySignature = signedPreKeySignature
            self.preKeys = preKeys
        }
    }

    /// Serializable session entry for persistent storage.
    struct StoredSessionEntry: Sendable {
        public let jid: BareJID
        public let deviceID: UInt32
        /// Serialized `OMEMODoubleRatchetSession` bytes.
        public let sessionData: [UInt8]
        /// X3DH associated data (64 bytes).
        public let associatedData: [UInt8]

        public init(jid: BareJID, deviceID: UInt32, sessionData: [UInt8], associatedData: [UInt8]) {
            self.jid = jid
            self.deviceID = deviceID
            self.sessionData = sessionData
            self.associatedData = associatedData
        }
    }
}

// MARK: - Identity Provider Protocol

/// Read-only access to an OMEMO identity source. Lets `OMEMOService` read `ownIdentityData` and `consumedPreKeyIDs()`
/// without holding a concrete module, so first-time persistence and pre-key upkeep can be exercised under unit tests.
package protocol OMEMOIdentityProviding: Sendable {
    var ownIdentityData: OMEMOModule.OMEMOIdentityData? { get }
    func consumedPreKeyIDs() -> Set<UInt32>
}

extension OMEMOModule: OMEMOIdentityProviding {}

/// What `OMEMOService` uses to keep the module's pre-keys and published bundle in step, as a protocol so unit tests can
/// drive that upkeep through a stub.
package protocol OMEMOPreKeyMaintaining: OMEMOIdentityProviding {
    var bundleNeedsPublish: Bool { get }
    func addPreKeys(_ preKeys: [OMEMOPreKey])
    func retirePreKeys(_ keyIDs: Set<UInt32>)
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
/// the emergency-retract path. Defense-in-depth alongside
/// `encryptKeyForOwnDevices`'s PEP-list intersect: leaving orphan rows in
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
    /// Every recipient device listed returned `item-not-found` (or equivalent)
    /// for its bundle. The message was not sent.
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

struct SessionKey: Hashable {
    let jid: BareJID
    let deviceID: UInt32
}

struct OwnIdentity {
    let deviceID: OMEMODeviceID
    let identityKeyPair: OMEMOIdentityKeyPair
    let signedPreKey: OMEMOSignedPreKey
    var preKeys: [OMEMOPreKey]
    let connectedJID: FullJID
}
