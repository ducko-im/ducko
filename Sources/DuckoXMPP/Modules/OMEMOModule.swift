// Split candidate.
// swiftlint:disable file_length
import CryptoKit
import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.omemo")

/// XEP-0384 fallback body attached to OMEMO-encrypted messages for clients that can't decrypt them.
/// `package` so DuckoCore can detect an OMEMO archive on the MAM ingest path by body comparison.
package let omemoFallbackBody = "This message is OMEMO encrypted"

/// Implements XEP-0384 OMEMO Encryption and XEP-0380 Explicit Message Encryption.
///
/// Manages device lists, bundles, session establishment (X3DH), and
/// per-message encryption/decryption (Double Ratchet + AES-256-CBC).
/// Uses PEPModule for all PubSub operations.
public final class OMEMOModule: XMPPModule, Sendable { // swiftlint:disable:this type_body_length
    // MARK: - State

    private struct SessionEntry {
        var session: OMEMODoubleRatchetSession
        var associatedData: [UInt8]
    }

    private struct State {
        var context: ModuleContext?
        var deviceLists: [BareJID: [UInt32]] = [:]
        var ownIdentity: OwnIdentity?
        var pendingIdentity: OMEMOIdentityData?
        var sessions: [SessionKey: SessionEntry] = [:]
        var usedPreKeyIDs: Set<UInt32> = []
        var identityKeyValidator: (@Sendable (BareJID, UInt32, [UInt8]) async throws -> Void)?
        /// See `OMEMOService.seenDeviceCacheByAccount` for the cache-survival rationale and the opaque-`accountID` contract.
        var seenDeviceClassificationProvider: (any SeenDeviceClassificationProviding)?
        var seenDeviceClassificationAccountID: String?
        var emergencyRetractGuard: (any EmergencyRetractGuarding)?
        var emergencyRetractConfirmation: EmergencyRetractConfirmation?
        var orphanDeviceRecordPurger: (any OrphanDeviceRecordPurging)?
        var registrationRetryTask: Task<Void, Never>?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let pepModule: PEPModule
    private let registrationRetryDelays: [Duration]

    /// PEP node name prefix for OMEMO bundle nodes (XEP-0384). A device's
    /// bundle is published at `bundleNodePrefix + "<deviceID>"`.
    public static let bundleNodePrefix = "\(XMPPNamespaces.omemo):bundles:"

    public var features: [String] {
        [XMPPNamespaces.omemo, XMPPNamespaces.eme]
    }

    public convenience init(pepModule: PEPModule) {
        self.init(pepModule: pepModule, registrationRetryDelays: [.seconds(10), .seconds(60), .seconds(300)])
    }

    init(pepModule: PEPModule, registrationRetryDelays: [Duration]) {
        self.pepModule = pepModule
        self.registrationRetryDelays = registrationRetryDelays
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    // MARK: - XMPPModule

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    public func handleConnect() async throws {
        let identity: OwnIdentity
        let ownListKnown: Bool
        do {
            if let pending = state.withLock({ $0.pendingIdentity }) {
                identity = try restoreIdentity(from: pending)
                state.withLock {
                    $0.pendingIdentity = nil
                    $0.ownIdentity = identity
                }
            } else {
                identity = try generateOwnIdentity()
                state.withLock { $0.ownIdentity = identity }
            }
            ownListKnown = try await ensureOwnDeviceInList(identity.deviceID)
            try await publishOwnBundle(identity)
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
            $0.deviceLists.removeAll()
            $0.sessions.removeAll()
            $0.usedPreKeyIDs.removeAll()
            $0.identityKeyValidator = nil
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

    /// Pre-configures identity data to be used on next `handleConnect()` instead of generating fresh.
    public func configureIdentity(_ data: OMEMOIdentityData) {
        state.withLock { $0.pendingIdentity = data }
    }

    /// Verifies the peer's identity key during session establishment (before X3DH key agreement).
    /// Receives `(peerJID, deviceID, identityKey)`; throw to reject.
    public func setIdentityKeyValidator(
        _ validator: (@Sendable (BareJID, UInt32, [UInt8]) async throws -> Void)?
    ) {
        state.withLock { $0.identityKeyValidator = validator }
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

    /// Restores previously persisted sessions into the module's in-memory state.
    public func restoreSessions(_ entries: [StoredSessionEntry]) {
        state.withLock { state in
            for entry in entries {
                let key = SessionKey(jid: entry.jid, deviceID: entry.deviceID)
                if let session = try? OMEMODoubleRatchetSession(serialized: entry.sessionData) {
                    state.sessions[key] = SessionEntry(
                        session: session, associatedData: entry.associatedData
                    )
                }
            }
        }
    }

    /// Exports a single session's state for persistent storage.
    public func exportSession(jid: BareJID, deviceID: UInt32) -> StoredSessionEntry? {
        state.withLock { state in
            let key = SessionKey(jid: jid, deviceID: deviceID)
            guard let entry = state.sessions[key] else { return nil }
            return StoredSessionEntry(
                jid: jid, deviceID: deviceID,
                sessionData: entry.session.serialize(), associatedData: entry.associatedData
            )
        }
    }

    /// Exports all sessions for persistent storage (e.g., on disconnect).
    public func allSessionEntries() -> [StoredSessionEntry] {
        state.withLock { state in
            state.sessions.map { key, entry in
                StoredSessionEntry(
                    jid: key.jid, deviceID: key.deviceID,
                    sessionData: entry.session.serialize(), associatedData: entry.associatedData
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

    /// Encrypts a 1:1 message. `recipientDeviceIDs`/`ownDeviceIDs` nil means "all known".
    public func encryptMessage(
        plaintext: String,
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
            plaintext: plaintext,
            peerDevices: recipientDevices.map { (jid: recipientJID, deviceID: $0) },
            ownDeviceIDs: ownDeviceIDs,
            conversation: recipientJID
        )
    }

    /// Encrypts a group message. `roomJID` labels emitted `omemoRecipientsPartial` events for correlation.
    public func encryptGroupMessage(
        plaintext: String,
        roomJID: BareJID,
        recipients: [(jid: BareJID, deviceIDs: [UInt32])],
        ownDeviceIDs: [UInt32]? = nil
    ) async throws -> EncryptedMessageElements {
        let peerDevices = recipients.flatMap { r in r.deviceIDs.map { (jid: r.jid, deviceID: $0) } }
        return try await encryptForDevices(
            plaintext: plaintext,
            peerDevices: peerDevices,
            ownDeviceIDs: ownDeviceIDs,
            conversation: roomJID
        )
    }

    /// Shared encrypt pipeline. Throws `noUsableRecipientDevices` when every peer bundle was missing — empty-PEP-list
    /// and all-item-not-found are otherwise indistinguishable from a silent drop. `conversation` labels emitted
    /// `omemoRecipientsPartial` events (peer or room JID).
    private func encryptForDevices(
        plaintext: String,
        peerDevices: [(jid: BareJID, deviceID: UInt32)],
        ownDeviceIDs: [UInt32]?,
        conversation: BareJID
    ) async throws -> EncryptedMessageElements {
        do {
            let identity = try requireOwnIdentity()
            let contentKey = randomBytes(32)
            let sceBytes = buildSCEEnvelope(body: plaintext)
            let payload = try encryptPayload(sceBytes, contentKey: contentKey)
            let peerEncryption = try await encryptKeysInParallel(
                contentKey: contentKey, identity: identity, devices: peerDevices
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
                contentKey: contentKey, identity: identity, ownDeviceIDs: ownDeviceIDs
            )
            results += ownEncryption.results
            applySessionUpdates(results)
            let keys = results.map(\.keyElement)
            let droppedRecipients = peerEncryption.dropped + ownEncryption.dropped
            let elements = buildEncryptedElements(
                keys: keys, payload: payload, senderDeviceID: identity.deviceID.value,
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
        let updatedEntry: SessionEntry
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
        contentKey: [UInt8], identity: OwnIdentity,
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
                                contentKey: contentKey, jid: device.jid,
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
        contentKey: [UInt8], identity: OwnIdentity,
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
            contentKey: contentKey, identity: identity,
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

    private func applySessionUpdates(_ results: [EncryptionResult]) {
        let updates = results.map { ($0.sessionKey, $0.updatedEntry) }
        state.withLock { state in
            for (key, entry) in updates {
                state.sessions[key] = entry
            }
        }
    }

    private func buildEncryptedElements(
        keys: [XMLElement], payload: String,
        senderDeviceID: UInt32,
        droppedRecipients: [DroppedOMEMORecipient]
    ) -> EncryptedMessageElements {
        let encrypted = buildEncryptedElement(
            keys: keys, payload: payload, senderDeviceID: senderDeviceID
        )
        let encryption = XMLElement(
            name: "encryption",
            namespace: XMPPNamespaces.eme,
            attributes: ["namespace": XMPPNamespaces.omemo, "name": "OMEMO"]
        )
        return EncryptedMessageElements(
            encrypted: encrypted,
            encryption: encryption,
            fallbackBody: omemoFallbackBody,
            droppedRecipients: droppedRecipients
        )
    }

    // MARK: - Identity Generation

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

    private func requireOwnIdentity() throws -> OwnIdentity {
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
            options: pepPublishOptions(maxItems: 1)
        )
    }

    // MARK: - Bundle Management

    /// Item ID used for both publishing and retracting OMEMO bundles. Single
    /// constant so the publish and retract sites cannot drift to different
    /// IDs (a wrong itemID is a silent no-op on most PEP servers).
    private static let bundleItemID = "current"

    private func publishOwnBundle(
        _ identity: OwnIdentity
    ) async throws {
        let bundle = OMEMOPreKeyManager.buildBundle(
            deviceID: identity.deviceID,
            identityKeyPair: identity.identityKeyPair,
            signedPreKey: identity.signedPreKey,
            preKeys: identity.preKeys
        )
        let payload = buildBundleElement(bundle)
        let node = bundleNodeName(identity.deviceID.value)
        try await pepModule.publishItem(
            node: node, itemID: Self.bundleItemID,
            payload: payload, options: pepPublishOptions()
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
                try await pepModule.retrieveItems(node: bundleNodeName(deviceID), from: nil, maxItems: 1).first?.payload
            },
            isValidBundle: { [self] payload, deviceID in parseBundleElement(payload, deviceID: deviceID) != nil },
            publishDeviceList: { [self] devices in try await publishDeviceList(devices) },
            retractBundle: { [self] deviceID in
                try await pepModule.retractItem(node: bundleNodeName(deviceID), itemID: Self.bundleItemID)
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
        let node = bundleNodeName(deviceID)
        let items = try await pepModule.retrieveItems(
            node: node, from: jid
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
        guard let event = message.element.child(
            named: "event", namespace: XMPPNamespaces.pubsubEvent
        ) else { return }
        guard let itemsEl = event.child(named: "items"),
              itemsEl.attribute("node") == XMPPNamespaces.omemoDevices
        else { return }
        guard let from = message.from?.bareJID else { return }
        guard let item = itemsEl.child(named: "item"),
              let payload = item.children.compactMap({
                  if case let .element(el) = $0 { return el }
                  return nil
              }).first
        else { return }
        let devices = parseDeviceList(payload)
        let context = state.withLock {
            $0.deviceLists[from] = devices
            return $0.context
        }
        context?.emitEvent(
            .omemoDeviceListReceived(jid: from, devices: devices)
        )
    }

    private func handleEncryptedMessage(_ message: XMPPMessage) {
        guard let encrypted = message.element.child(
            named: "encrypted", namespace: XMPPNamespaces.omemo
        ) else { return }
        guard let from = message.from else { return }

        // Extract XEP-0359 stanza-id for dedup and marker correlation
        let stanzaID = message.element
            .child(named: "stanza-id", namespace: XMPPNamespaces.stanzaID)?
            .attribute("id")

        do {
            let result = try decryptIncomingMessage(
                encrypted, from: from
            )
            let context = state.withLock { $0.context }

            // XEP-0308: Encrypted correction
            if let replace = message.element.child(named: "replace", namespace: XMPPNamespaces.messageCorrect),
               let originalID = replace.attribute("id"),
               let body = result.body {
                context?.emitEvent(.messageCorrected(originalID: originalID, newBody: body, from: from))
                context?.emitEvent(.omemoSessionAdvanced(jid: from.bareJID, deviceID: result.senderDeviceID))
                return
            }

            // XEP-0424: Encrypted retraction
            if let retract = message.element.child(named: "retract", namespace: XMPPNamespaces.messageRetract),
               let originalID = retract.attribute("id") {
                context?.emitEvent(.messageRetracted(originalID: originalID, from: from))
                context?.emitEvent(.omemoSessionAdvanced(jid: from.bareJID, deviceID: result.senderDeviceID))
                return
            }

            // A message that carries only key material has nothing to show, but it still moved the ratchet.
            guard let body = result.body else {
                context?.emitEvent(.omemoSessionAdvanced(jid: from.bareJID, deviceID: result.senderDeviceID))
                return
            }

            // Regular encrypted message
            context?.emitEvent(.omemoEncryptedMessageReceived(
                from: from,
                decryptedBody: body,
                senderDeviceID: result.senderDeviceID,
                stanzaID: stanzaID
            ))
        } catch OMEMOModuleError.notForThisDevice {
            // Not addressed to us — ignore silently
        } catch {
            log.warning("OMEMO decryption failed: \(error)")
            let context = state.withLock { $0.context }
            context?.emitEvent(.omemoEncryptedMessageReceived(
                from: from, decryptedBody: nil, senderDeviceID: 0,
                stanzaID: stanzaID
            ))
        }
    }

    // MARK: - Decryption

    private func decryptIncomingMessage(
        _ encrypted: XMLElement, from: JID
    ) throws -> DecryptionResult {
        let header = try parseHeader(encrypted)
        let ownDeviceID = state.withLock {
            $0.ownIdentity?.deviceID.value
        }
        guard let ownDeviceID else {
            throw OMEMOModuleError.notSetUp
        }
        guard let keyElement = findKeyElement(
            header.element, rid: ownDeviceID
        ) else {
            throw OMEMOModuleError.notForThisDevice
        }
        let isKex = keyElement.attribute("kex") == "true"
        guard let keyText = keyElement.textContent,
              let keyData = Base64.decode(keyText)
        else {
            throw OMEMOModuleError.invalidKeyData
        }
        let senderJID = from.bareJID
        let sessionKey = SessionKey(
            jid: senderJID, deviceID: header.sid
        )
        let contentKey: [UInt8] = if isKex {
            try decryptKexKey(
                keyData, sessionKey: sessionKey, header: header
            )
        } else {
            try decryptExistingSessionKey(
                keyData, sessionKey: sessionKey
            )
        }
        let body = try decryptPayload(encrypted, contentKey: contentKey)
        return DecryptionResult(
            body: body, senderDeviceID: header.sid
        )
    }

    private func decryptKexKey(
        _ data: [UInt8], sessionKey: SessionKey,
        header: ParsedHeader
    ) throws -> [UInt8] {
        let kex = try deserializeKeyExchange(data)
        let identity = try requireOwnIdentity()
        guard kex.signedPreKeyID == identity.signedPreKey.keyID else {
            throw OMEMOModuleError.invalidKeyData
        }
        let preKey = identity.preKeys.first {
            $0.keyID == kex.preKeyID
        }
        let x3dhResult = try OMEMOX3DH.responderKeyAgreement(
            identityKeyPair: identity.identityKeyPair,
            signedPreKey: identity.signedPreKey,
            oneTimePreKey: preKey,
            peerIdentityKey: kex.identityKey,
            peerEphemeralKey: kex.ephemeralKey
        )
        var session = OMEMODoubleRatchetSession(
            asResponderWithSharedSecret: x3dhResult.sharedSecret,
            ourSignedPreKeyPair: identity.signedPreKey.keyPair
        )
        let plaintext = try session.decrypt(
            message: kex.ratchetMessage,
            associatedData: x3dhResult.associatedData
        )
        let updatedSession = session
        let ad = x3dhResult.associatedData
        let consumedPreKeyID = preKey?.keyID
        let context = state.withLock {
            $0.sessions[sessionKey] = SessionEntry(
                session: updatedSession, associatedData: ad
            )
            if let consumedPreKeyID {
                $0.usedPreKeyIDs.insert(consumedPreKeyID)
            }
            if let knownDevices = $0.deviceLists[sessionKey.jid],
               !knownDevices.contains(header.sid) {
                log.warning("KEX from unannounced device \(header.sid) for \(sessionKey.jid)")
            }
            return $0.context
        }
        context?.emitEvent(.omemoSessionEstablished(
            jid: sessionKey.jid, deviceID: sessionKey.deviceID,
            identityKey: kex.identityKey
        ))
        return plaintext
    }

    private func decryptExistingSessionKey(
        _ data: [UInt8], sessionKey: SessionKey
    ) throws -> [UInt8] {
        let ratchetMessage = try deserializeRatchetMessage(data)
        guard var entry = state.withLock({ $0.sessions[sessionKey] }) else {
            throw OMEMOModuleError.noSession
        }
        let plaintext = try entry.session.decrypt(
            message: ratchetMessage, associatedData: entry.associatedData
        )
        let updatedEntry = entry
        state.withLock { $0.sessions[sessionKey] = updatedEntry }
        return plaintext
    }

    private func decryptPayload(
        _ encrypted: XMLElement, contentKey: [UInt8]
    ) throws -> String? {
        guard let payloadEl = encrypted.child(named: "payload"),
              let payloadText = payloadEl.textContent,
              let payloadData = Base64.decode(payloadText)
        else {
            return nil // Key transport message — no payload
        }
        guard payloadData.count > 16 else {
            throw OMEMOModuleError.invalidPayload
        }
        let ciphertext = Array(payloadData.dropLast(16))
        let hmac = Array(payloadData.suffix(16))
        let payload = OMEMOEncryptedPayload(
            ciphertext: ciphertext, truncatedHMAC: hmac
        )
        let sceBytes = try OMEMOMessageCrypto.decrypt(
            payload: payload, messageKey: contentKey,
            associatedData: []
        )
        return parseSCEBody(sceBytes)
    }

    // MARK: - Encryption

    private func encryptPayload(
        _ plaintext: [UInt8], contentKey: [UInt8]
    ) throws -> String {
        let encrypted = try OMEMOMessageCrypto.encrypt(
            plaintext: plaintext, messageKey: contentKey,
            associatedData: []
        )
        let combined = encrypted.ciphertext + encrypted.truncatedHMAC
        return Base64.encode(combined)
    }

    private func encryptKeyForDevice(
        contentKey: [UInt8], jid: BareJID,
        deviceID: UInt32, identity: OwnIdentity
    ) async throws -> EncryptionResult {
        let sessionKey = SessionKey(jid: jid, deviceID: deviceID)
        let result = try await getOrEstablishSession(
            sessionKey: sessionKey, identity: identity
        )
        var mutableSession = result.session
        let ratchetMessage = try mutableSession.encrypt(
            plaintext: contentKey, associatedData: result.ad
        )
        let updatedEntry = SessionEntry(
            session: mutableSession, associatedData: result.ad
        )
        let serialized: [UInt8]
        let isKex: Bool
        if let kexInfo = result.kexInfo {
            serialized = serializeKeyExchange(
                ratchetMessage: ratchetMessage,
                identity: identity, kexInfo: kexInfo
            )
            isKex = true
        } else {
            serialized = serializeRatchetMessage(ratchetMessage)
            isKex = false
        }
        let keyElement = buildKeyElement(
            deviceID: deviceID, data: serialized, isKex: isKex
        )
        return EncryptionResult(
            keyElement: keyElement, sessionKey: sessionKey,
            updatedEntry: updatedEntry
        )
    }

    // MARK: - Session Management

    private func getOrEstablishSession(
        sessionKey: SessionKey, identity: OwnIdentity
    ) async throws -> SessionResult {
        if let existing = state.withLock({ $0.sessions[sessionKey] }) {
            return SessionResult(
                session: existing.session, ad: existing.associatedData, kexInfo: nil
            )
        }
        return try await establishSession(
            sessionKey: sessionKey, identity: identity
        )
    }

    private func establishSession(
        sessionKey: SessionKey, identity: OwnIdentity
    ) async throws -> SessionResult {
        let bundle = try await fetchBundle(
            from: sessionKey.jid, deviceID: sessionKey.deviceID
        )
        let validator = state.withLock { $0.identityKeyValidator }
        if let validator {
            try await validator(
                sessionKey.jid, sessionKey.deviceID, bundle.identityKey
            )
        }
        let selectedPreKey = bundle.preKeys.randomElement()
        let peerBundle = OMEMOX3DHPeerBundle(
            identityKey: bundle.identityKey,
            signedPreKey: bundle.signedPreKey,
            signedPreKeySignature: bundle.signedPreKeySignature,
            oneTimePreKey: selectedPreKey?.publicKey
        )
        let x3dhResult = try OMEMOX3DH.initiatorKeyAgreement(
            identityKeyPair: identity.identityKeyPair,
            peerBundle: peerBundle
        )
        let session = try OMEMODoubleRatchetSession(
            asInitiatorWithSharedSecret: x3dhResult.sharedSecret,
            peerSignedPreKey: bundle.signedPreKey
        )
        let context = state.withLock {
            $0.sessions[sessionKey] = SessionEntry(
                session: session, associatedData: x3dhResult.associatedData
            )
            return $0.context
        }
        context?.emitEvent(.omemoSessionEstablished(
            jid: sessionKey.jid, deviceID: sessionKey.deviceID,
            identityKey: bundle.identityKey
        ))
        return SessionResult(
            session: session,
            ad: x3dhResult.associatedData,
            kexInfo: InitiatorKexInfo(
                ephemeralPublicKey: x3dhResult.ephemeralPublicKey,
                peerSignedPreKeyID: bundle.signedPreKeyID,
                peerPreKeyID: selectedPreKey?.id
            )
        )
    }

    // MARK: - SCE Envelope (XEP-0420)

    func buildSCEEnvelope(body: String) -> [UInt8] {
        var content = XMLElement(
            name: "content", namespace: XMPPNamespaces.sce
        )
        var payload = XMLElement(name: "payload")
        var bodyEl = XMLElement(
            name: "body", namespace: "jabber:client"
        )
        bodyEl.addText(body)
        payload.addChild(bodyEl)
        content.addChild(payload)
        var rpad = XMLElement(name: "rpad")
        rpad.addText(randomPadding())
        content.addChild(rpad)
        return Array(content.xmlString.utf8)
    }

    func parseSCEBody(_ data: [UInt8]) -> String? {
        let xml = String(decoding: data, as: UTF8.self)
        // Extract body text from known SCE envelope structure.
        // The envelope is produced by buildSCEEnvelope, so the format
        // is deterministic: <content><payload><body>TEXT</body>...
        guard let bodyStart = xml.range(of: "<body"),
              let contentStart = xml.range(
                  of: ">", range: bodyStart.upperBound ..< xml.endIndex
              ),
              let bodyEnd = xml.range(
                  of: "</body>",
                  range: contentStart.upperBound ..< xml.endIndex
              )
        else {
            // Not an SCE envelope — return raw text
            return xml.isEmpty ? nil : xml
        }
        let raw = xml[contentStart.upperBound ..< bodyEnd.lowerBound]
        return unescapeXMLEntities(String(raw))
    }

    private func unescapeXMLEntities(_ text: String) -> String {
        guard text.firstIndex(of: "&" as Character) != nil else {
            return text
        }
        var result: [Character] = []
        result.reserveCapacity(text.count)
        var rest = text[...]
        while let idx = rest.firstIndex(of: "&" as Character) {
            result.append(contentsOf: rest[rest.startIndex ..< idx])
            let tail = rest[idx...]
            let (replacement, advance) = matchEntity(tail)
            result.append(replacement)
            rest = rest[rest.index(idx, offsetBy: advance)...]
        }
        result.append(contentsOf: rest)
        return String(result)
    }

    private func matchEntity(
        _ tail: Substring
    ) -> (Character, Int) {
        if tail.hasPrefix("&amp;") { return ("&", 5) }
        if tail.hasPrefix("&lt;") { return ("<", 4) }
        if tail.hasPrefix("&gt;") { return (">", 4) }
        if tail.hasPrefix("&apos;") { return ("'", 6) }
        if tail.hasPrefix("&quot;") { return ("\"", 6) }
        return ("&", 1)
    }

    // MARK: - XML Parsing

    func parseDeviceList(
        _ element: XMLElement
    ) -> [UInt32] {
        element.children(named: "device").compactMap { device in
            guard let idStr = device.attribute("id"),
                  let id = UInt32(idStr)
            else { return nil }
            return id
        }
    }

    func parseBundleElement(
        _ element: XMLElement, deviceID: UInt32
    ) -> OMEMOBundle? {
        guard let spkEl = element.child(named: "signedPreKeyPublic"),
              let spkText = spkEl.textContent,
              let spkBytes = Base64.decode(spkText),
              let spkIDStr = spkEl.attribute("signedPreKeyId"),
              let spkID = UInt32(spkIDStr)
        else { return nil }
        guard let sigEl = element.child(named: "signedPreKeySignature"),
              let sigText = sigEl.textContent,
              let sigBytes = Base64.decode(sigText)
        else { return nil }
        guard let ikEl = element.child(named: "identityKey"),
              let ikText = ikEl.textContent,
              let ikBytes = Base64.decode(ikText)
        else { return nil }
        guard let prekeysEl = element.child(named: "prekeys")
        else { return nil }
        let preKeys = parsePreKeys(prekeysEl)
        return OMEMOBundle(
            deviceID: OMEMODeviceID(value: deviceID),
            identityKey: ikBytes,
            signedPreKeyID: spkID,
            signedPreKey: spkBytes,
            signedPreKeySignature: sigBytes,
            preKeys: preKeys
        )
    }

    private func parsePreKeys(
        _ element: XMLElement
    ) -> [OMEMOBundle.PreKeyPublic] {
        element.children(named: "preKeyPublic").compactMap { pk in
            guard let idStr = pk.attribute("preKeyId"),
                  let id = UInt32(idStr),
                  let text = pk.textContent,
                  let bytes = Base64.decode(text)
            else { return nil }
            return OMEMOBundle.PreKeyPublic(id: id, publicKey: bytes)
        }
    }

    private func parseHeader(
        _ encrypted: XMLElement
    ) throws -> ParsedHeader {
        guard let header = encrypted.child(named: "header"),
              let sidStr = header.attribute("sid"),
              let sid = UInt32(sidStr)
        else {
            throw OMEMOModuleError.invalidHeader
        }
        return ParsedHeader(element: header, sid: sid)
    }

    private func findKeyElement(
        _ header: XMLElement, rid: UInt32
    ) -> XMLElement? {
        let ridStr = "\(rid)"
        return header.children(named: "key").first {
            $0.attribute("rid") == ridStr
        }
    }

    // MARK: - XML Building

    private func buildDeviceListElement(
        _ devices: [UInt32]
    ) -> XMLElement {
        var list = XMLElement(
            name: "list", namespace: XMPPNamespaces.omemo
        )
        for id in devices {
            let device = XMLElement(
                name: "device", attributes: ["id": "\(id)"]
            )
            list.addChild(device)
        }
        return list
    }

    func buildBundleElement(
        _ bundle: OMEMOBundle
    ) -> XMLElement {
        var bundleEl = XMLElement(
            name: "bundle", namespace: XMPPNamespaces.omemo
        )
        var spk = XMLElement(
            name: "signedPreKeyPublic",
            attributes: ["signedPreKeyId": "\(bundle.signedPreKeyID)"]
        )
        spk.addText(Base64.encode(bundle.signedPreKey))
        bundleEl.addChild(spk)
        var sig = XMLElement(name: "signedPreKeySignature")
        sig.addText(Base64.encode(bundle.signedPreKeySignature))
        bundleEl.addChild(sig)
        var ik = XMLElement(name: "identityKey")
        ik.addText(Base64.encode(bundle.identityKey))
        bundleEl.addChild(ik)
        var prekeys = XMLElement(name: "prekeys")
        for pk in bundle.preKeys {
            var pkEl = XMLElement(
                name: "preKeyPublic",
                attributes: ["preKeyId": "\(pk.id)"]
            )
            pkEl.addText(Base64.encode(pk.publicKey))
            prekeys.addChild(pkEl)
        }
        bundleEl.addChild(prekeys)
        return bundleEl
    }

    func buildEncryptedElement(
        keys: [XMLElement], payload: String,
        senderDeviceID: UInt32
    ) -> XMLElement {
        var encrypted = XMLElement(
            name: "encrypted", namespace: XMPPNamespaces.omemo
        )
        var header = XMLElement(
            name: "header",
            attributes: ["sid": "\(senderDeviceID)"]
        )
        for key in keys {
            header.addChild(key)
        }
        encrypted.addChild(header)
        var payloadEl = XMLElement(name: "payload")
        payloadEl.addText(payload)
        encrypted.addChild(payloadEl)
        return encrypted
    }

    private func buildKeyElement(
        deviceID: UInt32, data: [UInt8], isKex: Bool
    ) -> XMLElement {
        var attrs = ["rid": "\(deviceID)"]
        if isKex { attrs["kex"] = "true" }
        var key = XMLElement(name: "key", attributes: attrs)
        key.addText(Base64.encode(data))
        return key
    }

    // MARK: - Key Wire Format

    private func serializeKeyExchange(
        ratchetMessage: OMEMORatchetMessage,
        identity: OwnIdentity, kexInfo: InitiatorKexInfo
    ) -> [UInt8] {
        var result: [UInt8] = []
        appendBigEndian(kexInfo.peerSignedPreKeyID, to: &result)
        let pkID = kexInfo.peerPreKeyID ?? 0xFFFF_FFFF
        appendBigEndian(pkID, to: &result)
        result.append(
            contentsOf: identity.identityKeyPair.publicKeyBytes
        )
        result.append(contentsOf: kexInfo.ephemeralPublicKey)
        result.append(
            contentsOf: serializeRatchetMessage(ratchetMessage)
        )
        return result
    }

    func serializeRatchetMessage(
        _ message: OMEMORatchetMessage
    ) -> [UInt8] {
        var result = message.header.encode()
        result.append(contentsOf: message.payload.ciphertext)
        result.append(contentsOf: message.payload.truncatedHMAC)
        return result
    }

    private func deserializeKeyExchange(
        _ data: [UInt8]
    ) throws -> KeyExchangeData {
        // 4 (spkID) + 4 (pkID) + 32 (identity) + 32 (ephemeral) = 72
        guard data.count >= 72 + 40 + 16 else {
            throw OMEMOModuleError.invalidKeyData
        }
        let spkID = readBigEndian(data, offset: 0)
        let pkID = readBigEndian(data, offset: 4)
        let identityKey = Array(data[8 ..< 40])
        let ephemeralKey = Array(data[40 ..< 72])
        let ratchetMessage = try deserializeRatchetMessage(
            Array(data[72...])
        )
        return KeyExchangeData(
            signedPreKeyID: spkID,
            preKeyID: pkID == 0xFFFF_FFFF ? nil : pkID,
            identityKey: identityKey,
            ephemeralKey: ephemeralKey,
            ratchetMessage: ratchetMessage
        )
    }

    func deserializeRatchetMessage(
        _ data: [UInt8]
    ) throws -> OMEMORatchetMessage {
        // 32 (DH key) + 4 (prev count) + 4 (msg number) + N (ciphertext) + 16 (HMAC)
        guard data.count >= 40 + 16 else {
            throw OMEMOModuleError.invalidKeyData
        }
        let dhPublicKey = Array(data[0 ..< 32])
        let prevCount = readLittleEndian(data, offset: 32)
        let msgNumber = readLittleEndian(data, offset: 36)
        let ciphertext = Array(data[40 ..< data.count - 16])
        let hmac = Array(data[data.count - 16 ..< data.count])
        let header = OMEMORatchetHeader(
            dhPublicKey: dhPublicKey,
            previousChainCount: prevCount,
            messageNumber: msgNumber
        )
        let payload = OMEMOEncryptedPayload(
            ciphertext: ciphertext, truncatedHMAC: hmac
        )
        return OMEMORatchetMessage(header: header, payload: payload)
    }

    // MARK: - Publish Options

    private func pepPublishOptions(
        maxItems: Int? = nil
    ) -> [DataFormField] {
        var fields = [
            DataFormField.pubsubPublishOptionsHeader,
            DataFormField(variable: "pubsub#persist_items", values: ["true"]),
            DataFormField(variable: "pubsub#access_model", values: ["open"])
        ]
        if let maxItems {
            fields.append(
                DataFormField(variable: "pubsub#max_items", values: ["\(maxItems)"])
            )
        }
        return fields
    }

    private func bundleNodeName(
        _ deviceID: UInt32
    ) -> String {
        "\(Self.bundleNodePrefix)\(deviceID)"
    }

    private func randomBytes(_ count: Int) -> [UInt8] {
        (0 ..< count).map { _ in UInt8.random(in: 0 ... 255) }
    }

    private func randomPadding() -> String {
        let length = Int.random(in: 1 ... 200)
        let bytes = (0 ..< length).map { _ in
            UInt8.random(in: 0x20 ... 0x7E)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func appendBigEndian(
        _ value: UInt32, to buffer: inout [UInt8]
    ) {
        buffer.append(UInt8(value >> 24 & 0xFF))
        buffer.append(UInt8(value >> 16 & 0xFF))
        buffer.append(UInt8(value >> 8 & 0xFF))
        buffer.append(UInt8(value & 0xFF))
    }

    func readBigEndian(
        _ data: [UInt8], offset: Int
    ) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    func readLittleEndian(
        _ data: [UInt8], offset: Int
    ) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
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
        /// Fallback body for non-OMEMO clients.
        public let fallbackBody: String
        /// Devices skipped because no bundle was fetchable (`item-not-found` / `bundleNotFound`). Non-empty signals partial coverage.
        public let droppedRecipients: [DroppedOMEMORecipient]

        public init(
            encrypted: XMLElement,
            encryption: XMLElement,
            fallbackBody: String,
            droppedRecipients: [DroppedOMEMORecipient] = []
        ) {
            self.encrypted = encrypted
            self.encryption = encryption
            self.fallbackBody = fallbackBody
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

/// Read-only access to an OMEMO identity source. Lets `OMEMOService` consume
/// the surfaces it needs from `OMEMOModule` (`ownIdentityData`,
/// `consumedPreKeyIDs()`) without holding a concrete module reference, so the
/// connect-time first-time-persistence path can be exercised under unit tests.
package protocol OMEMOIdentityProviding: Sendable {
    var ownIdentityData: OMEMOModule.OMEMOIdentityData? { get }
    func consumedPreKeyIDs() -> Set<UInt32>
}

extension OMEMOModule: OMEMOIdentityProviding {}

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

private struct SessionKey: Hashable {
    let jid: BareJID
    let deviceID: UInt32
}

private struct OwnIdentity {
    let deviceID: OMEMODeviceID
    let identityKeyPair: OMEMOIdentityKeyPair
    let signedPreKey: OMEMOSignedPreKey
    let preKeys: [OMEMOPreKey]
    let connectedJID: FullJID
}

private struct SessionResult {
    let session: OMEMODoubleRatchetSession
    let ad: [UInt8]
    /// Key exchange info for new sessions (nil for existing).
    let kexInfo: InitiatorKexInfo?
}

private struct InitiatorKexInfo {
    let ephemeralPublicKey: [UInt8]
    let peerSignedPreKeyID: UInt32
    let peerPreKeyID: UInt32?
}

private struct ParsedHeader {
    let element: XMLElement
    let sid: UInt32
}

private struct DecryptionResult {
    let body: String?
    let senderDeviceID: UInt32
}

private struct KeyExchangeData {
    let signedPreKeyID: UInt32
    let preKeyID: UInt32?
    let identityKey: [UInt8]
    let ephemeralKey: [UInt8]
    let ratchetMessage: OMEMORatchetMessage
}
