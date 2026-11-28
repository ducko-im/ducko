import CryptoKit
import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.omemo")

@MainActor @Observable
public final class OMEMOService {
    let omemoStore: any OMEMOStore
    private(set) weak var accountService: AccountService?
    private(set) weak var chatService: ChatService?
    /// Per-account seen-device classification cache (canonical home).
    ///
    /// Lives here (not on `OMEMOModule`) so it survives reconnects — modules are rebuilt per reconnect.
    /// Without that, the two-stale gate in `pruneStaleBundles` would always start empty and never auto-retract.
    /// Keyed by `UUID.uuidString` because `SeenDeviceClassificationProviding` takes opaque `String`.
    private var seenDeviceCacheByAccount: [String: [UInt32: SeenDeviceRecord]] = [:]
    /// True once persistent rows for an account have been loaded into memory. Cache miss before the sentinel → hit the store; after → purged or never persisted.
    private var seenDeviceLoadedAccounts: Set<String> = []
    /// In-flight load coalescing — two concurrent first-reads share one store round-trip. Store errors absorbed (protocol contract); failure → empty map.
    private var seenDevicePendingLoads: [String: Task<[UInt32: SeenDeviceRecord], Never>] = [:]
    /// Load-generation counter. Bumped on every `clearSeenDevicesAbsent` / `replaceSeenDevices` / `purgeSeenDeviceClassifications`.
    /// The first-load path captures the generation before awaiting the store; if it changed during the await,
    /// the loaded snapshot must NOT be merged — it would resurrect rows the explicit op deliberately removed.
    private var seenDeviceLoadGeneration: [String: UInt64] = [:]
    /// Maps the opaque accountID (`UUID.uuidString`) to the wire `accountJID` used by `OMEMOStore`.
    /// Captured at module-build time so provider calls don't traverse the weakly-held `accountService`.
    private var accountJIDsByAccountID: [String: String] = [:]
    /// In-flight flag for the emergency-retract path. Held across the entire publish/retract/cleanup phase
    /// (not just the closure await) so a second prune after a mid-retract module rebuild bails cleanly.
    private var emergencyRetractInFlightAccounts: Set<String> = []
    /// Accounts whose pre-key upkeep is running.
    private var preKeyMaintenanceRunning: Set<UUID> = []
    /// The used pre-key ids waiting for each account's next upkeep run.
    private var preKeyMaintenanceQueue: [UUID: Set<UInt32>] = [:]
    /// Each account's trust guard, kept for the life of the process so a used pre-key or a pinned key outlives the
    /// connection's module. Keyed by account JID, so a re-added account keeps its record.
    private var trustGuardsByAccountJID: [String: OMEMOTrustGuard] = [:]
    /// How far each account's encryption setup got on its current session. Only `receiveSetupEvent` sets it, so it
    /// follows the account's event order.
    var setupStates: [UUID: OMEMOSetupState] = [:]
    /// The accounts whose setup the user asked to try again, until that attempt has its outcome or the session ends.
    public internal(set) var retryingSetupAccounts: Set<UUID> = []
    /// The conversations, per account, whose setup notice the user dismissed, until the account's next failed attempt.
    var dismissedSetupProblems: [UUID: Set<String>] = [:]

    /// UI-supplied confirmation closure before the emergency-retract path publishes a singleton devicelist.
    /// Default `nil` preserves the pre-feature bail behavior. `@Sendable`; callers hop to `MainActor` inside.
    public var emergencyRetractConfirmation: (@Sendable (_ deviceCount: Int, _ ownDeviceID: UInt32) async -> Bool)?
    /// Whether the user trusts a device on first use, read at each decision so a change applies to the next send.
    let trustOnFirstUse: @MainActor () -> Bool

    public init(omemoStore: any OMEMOStore, trustOnFirstUse: @escaping @MainActor () -> Bool = { OMEMOPreferences.shared.trustOnFirstUse }) {
        self.omemoStore = omemoStore
        self.trustOnFirstUse = trustOnFirstUse
    }

    /// Test-only: pre-populates `accountID → accountJID` so provider methods work without driving `buildModule`.
    package func installAccountJIDForTesting(_ accountJID: String, accountID: String) async {
        accountJIDsByAccountID[accountID] = accountJID
    }

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
    }

    func setChatService(_ service: ChatService) {
        chatService = service
    }

    /// Drops the seen-device classification entry + persisted rows for `accountID`.
    func purgeSeenDeviceClassifications(accountID: UUID) {
        let key = accountID.uuidString
        let accountJID = accountJIDsByAccountID[key]
        seenDeviceCacheByAccount.removeValue(forKey: key)
        seenDeviceLoadedAccounts.remove(key)
        seenDevicePendingLoads[key]?.cancel()
        seenDevicePendingLoads.removeValue(forKey: key)
        seenDeviceLoadGeneration[key, default: 0] &+= 1
        accountJIDsByAccountID.removeValue(forKey: key)
        emergencyRetractInFlightAccounts.remove(key)
        if let accountJID {
            let store = omemoStore
            Task { try? await store.purgeSeenDevices(for: accountJID) }
        }
    }

    // MARK: - Module Building

    /// Creates a pre-configured OMEMOModule with persisted identity and sessions.
    func buildModule(for accountJID: BareJID, accountID: UUID, pepModule: PEPModule, mucModule: MUCModule? = nil) async -> OMEMOModule {
        let module = OMEMOModule(pepModule: pepModule, mucModule: mucModule)
        let jidString = accountJID.description

        let trustGuard = trustGuard(forAccountJID: jidString)
        module.configureTrustGuard(trustGuard)
        // Wire pruneStaleBundles' service-side dependencies. See `seenDeviceCacheByAccount` for the reconnect-survival rationale.
        let accountIDKey = accountID.uuidString
        accountJIDsByAccountID[accountIDKey] = jidString
        module.configureSeenDeviceClassificationProvider(self, accountID: accountIDKey)
        module.configureIdentityPersister(self, accountID: accountIDKey)
        module.configureEmergencyRetract(
            confirmation: emergencyRetractConfirmation,
            guard: self,
            orphanPurger: self
        )

        // Keys that cannot be read must never be replaced by a new device, so a failed load leaves encryption off for
        // this connection and the next connect tries again.
        do {
            let stamp = trustGuard.currentStamp()
            try await mergeStoredTrust(omemoStore.loadAllTrust(for: jidString), accountJID: jidString, loadedAfter: stamp)
            guard let identityData = try await loadStoredIdentity(accountJID: jidString) else { return module }
            let sessions = try await omemoStore.loadSessions(for: jidString)
            module.configureIdentity(identityData)
            module.restoreSessions(storedSessionEntries(sessions, accountJID: accountJID))
        } catch {
            module.markIdentityUnavailable()
            log.warning("OMEMO keys could not be loaded; encryption stays off until the next connect")
            log.debug("OMEMO keys could not be loaded: \(error)")
        }
        return module
    }

    /// The stored sessions as the module restores them, each in the version its row names.
    private func storedSessionEntries(_ sessions: [OMEMOStoredSession], accountJID: BareJID) -> [OMEMOModule.StoredSessionEntry] {
        sessions.map { session in
            OMEMOModule.StoredSessionEntry(
                jid: BareJID.parse(session.peerJID) ?? accountJID, deviceID: session.peerDeviceID, version: session.version,
                sessionData: Array(session.sessionData), associatedData: Array(session.associatedData)
            )
        }
    }

    /// The stored identity with its unused pre-keys and its signed pre-keys, the newest as current, or nil for a new
    /// installation. A pre-key counts as used when the store or the trust guard records it so. A signed pre-key that is
    /// missing is replaced for the same device, and stored before anything publishes it.
    private func loadStoredIdentity(accountJID: String) async throws -> OMEMOModule.OMEMOIdentityData? {
        guard let stored = try await omemoStore.loadIdentity(for: accountJID) else { return nil }
        let preKeys = try await omemoStore.loadPreKeys(for: accountJID)
        let consumed = trustGuard(forAccountJID: accountJID).consumedPreKeyIDs(ownDeviceID: stored.deviceID)
        let signedPreKeys = try await omemoStore.loadSignedPreKeys(for: accountJID)
        let signedPreKey = if let newest = signedPreKeys.first {
            newest
        } else {
            try await replaceSignedPreKey(identityKeyData: stored.identityKeyData, accountJID: accountJID)
        }
        return OMEMOModule.OMEMOIdentityData(
            deviceID: stored.deviceID,
            identityKeyRaw: Array(stored.identityKeyData),
            signedPreKeyID: signedPreKey.keyID,
            signedPreKeyRaw: Array(signedPreKey.keyData),
            signedPreKeySignature: Array(signedPreKey.signature),
            preKeys: preKeys.filter { !$0.isUsed && !consumed.contains($0.keyID) }.map {
                OMEMOModule.OMEMOIdentityData.PreKeyData(keyID: $0.keyID, keyRaw: Array($0.keyData))
            },
            retainedSignedPreKeys: signedPreKeys.dropFirst().map(\.identityData)
        )
    }

    private func replaceSignedPreKey(identityKeyData: Data, accountJID: String) async throws -> OMEMOStoredSignedPreKey {
        let keyID: UInt32 = 1
        let generated = try OMEMOPreKeyManager.generateSignedPreKeyData(keyID: keyID, identityKeyRaw: Array(identityKeyData))
        let signedPreKey = OMEMOStoredSignedPreKey(
            accountJID: accountJID, keyID: keyID,
            keyData: Data(generated.keyRaw), signature: Data(generated.signature), timestamp: Date()
        )
        try await omemoStore.saveSignedPreKey(signedPreKey)
        log.info("OMEMO signed pre-key was missing and has been replaced")
        return signedPreKey
    }

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case let .omemoDeviceListReceived(jid, devices, _):
            await seedUndecidedTrust(for: jid, devices: devices, accountID: accountID)
        case let .omemoEncryptedMessageReceived(message, outcome, roomAuthor):
            await handleEncryptedMessageReceived(message, outcome: outcome, roomAuthor: roomAuthor, accountID: accountID)
        case let .omemoSessionEstablished(jid, deviceID, version, identityKey, consumedPreKeyID):
            await handleSessionEstablished(
                jid: jid, deviceID: deviceID, version: version,
                identityKey: identityKey, accountID: accountID
            )
            await schedulePreKeyMaintenance(accountID: accountID, consumedPreKeyID: consumedPreKeyID)
        case .omemoSessionAdvanced:
            await saveSessions(accountID: accountID)
        case .connected:
            await handleConnected(accountID: accountID)
        case .streamResumed:
            await retrySetupOnResume(accountID: accountID)
            await schedulePreKeyMaintenance(accountID: accountID, consumedPreKeyID: nil)
        case .disconnected, .omemoSetupChanged:
            // `receiveSetupEvent` takes both in order.
            break
        case .authenticationFailed, .plainSignInRefused,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterUpdated,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived,
             .roomDestroyed, .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .jingleChecksumReceived,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoRecipientsPartial,
             .oobIQOfferReceived:
            break
        }
    }

    // MARK: - Encryption

    /// Encrypts a 1:1 message's `content`, the elements its envelope carries, and `legacyBody`, its body, for the devices
    /// that receive it as legacy OMEMO.
    func encryptMessage(
        content: [DuckoXMPP.XMLElement],
        legacyBody: String?,
        to jid: BareJID,
        trustedDeviceIDs: [UInt32],
        accountID: UUID
    ) async throws -> OMEMOModule.EncryptedMessageElements {
        guard !trustedDeviceIDs.isEmpty else {
            throw OMEMOServiceError.noTrustedRecipients
        }
        guard let client = accountService?.connectedClient(for: accountID) else {
            throw OMEMOServiceError.notConnected(accountID)
        }
        guard let omemoModule = await client.module(ofType: OMEMOModule.self) else {
            throw OMEMOServiceError.omemoNotAvailable
        }

        let ownDeviceIDs = await trustedOwnDeviceIDs(accountID: accountID)
        let elements = try await omemoModule.encryptMessage(
            content: content, legacyBody: legacyBody, time: Date().formatted(.iso8601), to: jid,
            recipientDeviceIDs: trustedDeviceIDs, ownDeviceIDs: ownDeviceIDs
        )

        await saveModuleSessions(module: omemoModule, accountID: accountID)

        return elements
    }

    /// The peer's stored trust rows, which the account's guard takes in, so a decision made in another process over the
    /// same store reaches the next send. A read that fails yields no rows.
    func loadAllDevicesMergingTrust(for peerJID: String, accountJID: String) async -> [OMEMOTrust] {
        let stamp = trustGuard(forAccountJID: accountJID).currentStamp()
        let rows = await (try? omemoStore.loadAllDevices(for: peerJID, accountJID: accountJID)) ?? []
        mergeStoredTrust(rows, accountJID: accountJID, loadedAfter: stamp)
        return rows
    }

    private func mergeStoredTrust(_ rows: [OMEMOTrust], accountJID: String, loadedAfter stamp: UInt64) {
        let stored = rows.compactMap { row in
            BareJID.parse(row.peerJID).map {
                OMEMOTrustGuard.StoredTrust(peer: $0, deviceID: row.deviceID, fingerprint: row.fingerprint, decision: row.trustLevel.storedDecision)
            }
        }
        trustGuard(forAccountJID: accountJID).merge(stored, loadedAfter: stamp)
    }

    func trustGuard(forAccountJID accountJID: String) -> OMEMOTrustGuard {
        if let existing = trustGuardsByAccountJID[accountJID] { return existing }
        let created = OMEMOTrustGuard()
        trustGuardsByAccountJID[accountJID] = created
        return created
    }

    // MARK: - Trust Management

    public func trustDevice(accountID: UUID, peerJID: String, deviceID: UInt32, fingerprint: String) async throws {
        try await setTrustLevel(.trusted, accountID: accountID, peerJID: peerJID, deviceID: deviceID, fingerprint: fingerprint)
    }

    /// Refuses the device at once, before the store is written, so a failed save still keeps it refused until the user
    /// trusts it again.
    public func untrustDevice(accountID: UUID, peerJID: String, deviceID: UInt32) async throws {
        guard let accountJID = accountJIDString(for: accountID), let peer = BareJID.parse(peerJID) else { return }
        let trustGuard = trustGuard(forAccountJID: accountJID)
        let decision = trustGuard.applyDistrust(peer: peer, deviceID: deviceID)
        try await omemoStore.markTrust(
            .untrusted, accountJID: accountJID, peerJID: peer.description, deviceID: deviceID,
            fallbackFingerprint: trustGuard.heldFingerprint(peer: peer, deviceID: deviceID)
        )
        trustGuard.distrustSaved(peer: peer, deviceID: deviceID, decision: decision)
    }

    /// Throws `noFingerprintToVerify` for an empty `fingerprint`, since a key the user never saw cannot have been compared.
    public func verifyDevice(accountID: UUID, peerJID: String, deviceID: UInt32, fingerprint: String) async throws {
        guard !fingerprint.isEmpty else { throw OMEMOServiceError.noFingerprintToVerify }
        try await setTrustLevel(.verified, accountID: accountID, peerJID: peerJID, deviceID: deviceID, fingerprint: fingerprint)
    }

    public func ownFingerprint(accountID: UUID) async -> String? {
        await ownDeviceInfo(accountID: accountID)?.fingerprint
    }

    /// The peer's stored devices with their trust, for display, each once whichever of its lists hold it: those on its
    /// device lists as last fetched or notified, as sends use, or every stored one when the lists cannot be read, as
    /// without a connection. For the account's own JID this device is included when it has a row.
    public func deviceInfoList(for peerJID: String, accountID: UUID) async -> [OMEMODeviceInfo] {
        guard let accountJID = accountJIDString(for: accountID), let peer = BareJID.parse(peerJID) else { return [] }
        let devices: [OMEMOTrust]
        do {
            devices = try await listedDevices(of: peer, accountID: accountID, accountJID: accountJID)
        } catch {
            log.debug("OMEMO device list of \(peer) could not be read; showing every stored device: \(error)")
            devices = await loadAllDevicesMergingTrust(for: peer.description, accountJID: accountJID)
        }
        let versions = await listedVersions(of: peer, accountID: accountID)
        return devices.map {
            OMEMODeviceInfo(
                peerJID: $0.peerJID, deviceID: $0.deviceID,
                fingerprint: $0.fingerprint, trustLevel: $0.trustLevel, versions: versions[$0.deviceID] ?? []
            )
        }
    }

    /// Returns own device info (device ID + fingerprint) for side-by-side verification.
    public func ownDeviceInfo(accountID: UUID) async -> OMEMODeviceInfo? {
        guard let accountJID = accountJIDString(for: accountID), let identity = try? await omemoStore.loadIdentity(for: accountJID), let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: identity.identityKeyData) else {
            return nil
        }
        let fingerprint = omemoFingerprint(of: privateKey.publicKey.rawRepresentation, format: .omemo2)
        var versions: Set<OMEMOWireFormat> = []
        if let ownJID = BareJID.parse(accountJID) {
            versions = await listedVersions(of: ownJID, accountID: accountID)[identity.deviceID] ?? []
        }
        return OMEMODeviceInfo(
            peerJID: accountJID, deviceID: identity.deviceID,
            fingerprint: fingerprint, trustLevel: .verified, versions: versions
        )
    }

    /// The versions whose list of `jid`, as the connected module last fetched or was notified of it, holds each device.
    /// None without a connection.
    private func listedVersions(of jid: BareJID, accountID: UUID) async -> [UInt32: Set<OMEMOWireFormat>] {
        await accountService?.connectedClient(for: accountID)?.module(ofType: OMEMOModule.self)?.listedVersions(of: jid) ?? [:]
    }

    // MARK: - Group Chat Encryption

    /// Encrypts a room message's `content` and `legacyBody` for `recipients`, each a member and their devices that
    /// `shouldEncrypt` resolved, and for the account's other trusted devices.
    func encryptGroupMessage(
        content: [DuckoXMPP.XMLElement],
        legacyBody: String?,
        roomJID: BareJID,
        recipients: [(jid: BareJID, deviceIDs: [UInt32])],
        accountID: UUID
    ) async throws -> OMEMOModule.EncryptedMessageElements {
        guard let client = accountService?.connectedClient(for: accountID) else {
            throw OMEMOServiceError.notConnected(accountID)
        }
        guard let omemoModule = await client.module(ofType: OMEMOModule.self) else {
            throw OMEMOServiceError.omemoNotAvailable
        }

        let ownDeviceIDs = await trustedOwnDeviceIDs(accountID: accountID)
        let elements = try await omemoModule.encryptGroupMessage(
            content: content, legacyBody: legacyBody, time: Date().formatted(.iso8601), roomJID: roomJID,
            recipients: recipients, ownDeviceIDs: ownDeviceIDs
        )
        await saveModuleSessions(module: omemoModule, accountID: accountID)
        return elements
    }

    // MARK: - Private Event Handlers

    /// Gives each of `jid`'s listed devices without a trust row an undecided one.
    func seedUndecidedTrust(for jid: BareJID, devices: [UInt32], accountID: UUID) async {
        guard let accountJID = accountJIDString(for: accountID) else { return }
        for deviceID in devices {
            let trust = OMEMOTrust(
                accountJID: accountJID, peerJID: jid.description,
                deviceID: deviceID, fingerprint: "", trustLevel: .undecided
            )
            try? await omemoStore.insertTrustIfAbsent(trust)
        }
    }

    private func handleSessionEstablished(
        jid: BareJID, deviceID: UInt32, version: OMEMOWireFormat,
        identityKey: [UInt8], accountID: UUID
    ) async {
        guard let client = accountService?.client(for: accountID),
              let omemoModule = await client.module(ofType: OMEMOModule.self), let entry = omemoModule.exportSession(jid: jid, deviceID: deviceID, version: version), let accountJID = accountJIDString(for: accountID) else { return }

        await saveSession(entry, accountJID: accountJID)

        // Another process over the same store can have pinned another key for the device.
        let stored = try? await omemoStore.fillTrustFingerprint(
            accountJID: accountJID, peerJID: jid.description, deviceID: deviceID, fingerprint: omemoFingerprint(of: identityKey, format: version)
        )
        if stored != nil {
            log.warning("Identity key changed for device \(deviceID)")
            log.debug("The changed identity key belongs to \(jid)")
        }
    }

    private func handleConnected(accountID: UUID) async {
        guard let client = accountService?.connectedClient(for: accountID) else { return }

        // Wait until initial presence + caps are on the wire so PEP publishes follow the server seeing
        // this resource's caps (XEP-0163 §3.3.2).
        await client.awaitInitialPresenceSent()

        await schedulePreKeyMaintenance(accountID: accountID, consumedPreKeyID: nil)
    }

    /// Stores a newly generated identity, then its keys, and returns whether the identity was stored. The keys are
    /// stored only after the identity is: without it they would be orphans whose ids the next new device reuses. The
    /// pre-keys and the signed pre-key are each tried even when the other failed.
    private func persistFirstTimeIdentity(_ identityData: OMEMOModule.OMEMOIdentityData, accountJID: String) async -> Bool {
        let stored = OMEMOStoredIdentity(
            accountJID: accountJID,
            deviceID: identityData.deviceID,
            identityKeyData: Data(identityData.identityKeyRaw),
            registrationID: 0
        )
        do {
            try await omemoStore.saveIdentity(stored)
        } catch {
            log.warning("Could not store the new OMEMO identity")
            log.debug("Could not store the new OMEMO identity: \(error)")
            return false
        }

        let preKeys = identityData.preKeys.map {
            OMEMOStoredPreKey(
                accountJID: accountJID, keyID: $0.keyID,
                keyData: Data($0.keyRaw), isUsed: false
            )
        }
        do {
            try await omemoStore.savePreKeys(preKeys)
        } catch {
            log.warning("Could not store the new OMEMO pre-keys")
            log.debug("Could not store the new OMEMO pre-keys: \(error)")
        }

        let spk = OMEMOStoredSignedPreKey(
            accountJID: accountJID,
            keyID: identityData.signedPreKeyID,
            keyData: Data(identityData.signedPreKeyRaw),
            signature: Data(identityData.signedPreKeySignature),
            timestamp: Date()
        )
        do {
            try await omemoStore.saveSignedPreKey(spk)
        } catch {
            log.warning("Could not store the new OMEMO signed pre-key")
            log.debug("Could not store the new OMEMO signed pre-key: \(error)")
        }
        return true
    }

    /// Runs pre-key upkeep for the account's current client. Runs coalesce: a trigger that arrives during a run is
    /// taken by one more run afterwards, so a burst of key exchanges never has two runs allocate pre-key ids at once.
    /// Each run looks the client up again, so a run waiting on an old client cannot swallow a resumed one's publish.
    private func schedulePreKeyMaintenance(accountID: UUID, consumedPreKeyID: UInt32?) async {
        preKeyMaintenanceQueue[accountID, default: []].formUnion(consumedPreKeyID.map { [$0] } ?? [])
        guard preKeyMaintenanceRunning.insert(accountID).inserted else { return }
        defer { preKeyMaintenanceRunning.remove(accountID) }
        while let consumed = preKeyMaintenanceQueue.removeValue(forKey: accountID) {
            guard let accountJID = accountJIDString(for: accountID) else { return }
            let client = accountService?.client(for: accountID)
            let module = await client?.module(ofType: OMEMOModule.self)
            await maintainPreKeys(
                accountJID: accountJID, module: module, consumedPreKeyIDs: consumed,
                awaitReady: { await client?.awaitInitialPresenceSent() }
            )
        }
    }

    /// Records used pre-keys, keeps the signed pre-keys in step with the store and rotates them, tops the pre-keys up
    /// when they run low, and republishes the bundle when it lags behind. Failures are logged, and the next trigger
    /// retries: the store and the module are read afresh each run.
    /// `awaitReady` holds the publish until the server has seen this resource's caps (XEP-0163 §3.3.2).
    package func maintainPreKeys(
        accountJID: String,
        module: (any OMEMOPreKeyMaintaining)?,
        consumedPreKeyIDs eventPreKeyIDs: Set<UInt32> = [],
        awaitReady: () async -> Void = {}
    ) async {
        // A brand-new device is left to first-time persistence until its identity is stored, or both would save its
        // pre-keys.
        let storedIdentity: OMEMOStoredIdentity
        let stored: [OMEMOStoredPreKey]
        do {
            guard let identity = try await omemoStore.loadIdentity(for: accountJID) else { return }
            storedIdentity = identity
            stored = try await omemoStore.loadPreKeys(for: accountJID)
        } catch {
            log.warning("Could not read the OMEMO pre-keys for upkeep")
            log.debug("Could not read the OMEMO pre-keys for upkeep: \(error)")
            return
        }

        // The event's ids and the guard's are recorded even when the module that used them is gone, since a new module
        // starts without them. An id whose save failed stays unused in the store, so the next run tries it again.
        let guardedIDs = trustGuard(forAccountJID: accountJID).consumedPreKeyIDs(ownDeviceID: storedIdentity.deviceID)
        var unusedIDs = Set(stored.filter { !$0.isUsed }.map(\.keyID))
        let consumed = eventPreKeyIDs.union(module?.consumedPreKeyIDs() ?? []).union(guardedIDs)
        for keyID in consumed where unusedIDs.contains(keyID) {
            do {
                try await omemoStore.consumePreKey(id: keyID, accountJID: accountJID)
                unusedIDs.remove(keyID)
            } catch {
                log.warning("Could not record a used OMEMO pre-key")
                log.debug("Could not record used OMEMO pre-key \(keyID): \(error)")
            }
        }

        guard let module, let identityData = module.ownIdentityData else { return }
        await maintainSignedPreKeys(accountJID: accountJID, module: module, identityData: identityData)
        // A module built while an earlier connection's run was still recording a key holds that key as unused.
        module.retirePreKeys(Set(stored.filter(\.isUsed).map(\.keyID)).union(eventPreKeyIDs).union(guardedIDs))
        if unusedIDs.count < OMEMOPreKeyManager.minimumPreKeyCount {
            // Past every id the store or the module has used, so no new key can take the id of an older one.
            let highestID = max(stored.map(\.keyID).max() ?? 0, identityData.preKeys.map(\.keyID).max() ?? 0)
            let newPreKeys = OMEMOPreKeyManager.generatePreKeys(
                startID: highestID + 1, count: OMEMOPreKeyManager.targetPreKeyCount - unusedIDs.count
            )
            do {
                try await omemoStore.savePreKeys(newPreKeys.map {
                    OMEMOStoredPreKey(accountJID: accountJID, keyID: $0.keyID, keyData: Data($0.rawRepresentation), isUsed: false)
                })
                module.addPreKeys(newPreKeys)
                log.info("Replenished pre-keys: \(newPreKeys.count) new")
            } catch {
                log.warning("Could not store new OMEMO pre-keys")
                log.debug("Could not store new OMEMO pre-keys: \(error)")
            }
        }

        guard module.bundleNeedsPublish else { return }
        await awaitReady()
        do {
            try await module.republishBundle()
        } catch {
            log.warning("Could not publish the OMEMO bundle")
            log.debug("Could not publish the OMEMO bundle: \(error)")
        }
    }

    func saveModuleSessions(module: OMEMOModule, accountID: UUID) async {
        guard let accountJID = accountJIDString(for: accountID) else { return }
        for entry in module.allSessionEntries() {
            await saveSession(entry, accountJID: accountJID)
        }
    }

    /// Saves a session the module holds without failing the caller, since the module keeps it and saves it again
    /// whenever its sessions are saved next.
    func saveSession(_ entry: OMEMOModule.StoredSessionEntry, accountJID: String) async {
        do {
            try await omemoStore.saveSession(OMEMOStoredSession(accountJID: accountJID, entry: entry))
        } catch {
            log.warning("An OMEMO session could not be saved")
            log.debug("The OMEMO session with \(entry.jid) device \(entry.deviceID) could not be saved: \(error)")
        }
    }

    /// Saves a Trust or Verify of the key the user compared, `fingerprint`. Throws `identityKeyMismatch` without saving
    /// when another key is held. A Trust without a fingerprint authorizes the device's first key rather than certifying
    /// one, so it keeps a fingerprint another process stored and otherwise stores the held one. It throws
    /// `conflictingFingerprints` without saving when the device's rows would then name different keys. The guard lifts
    /// a refusal only once the save succeeds.
    private func setTrustLevel(
        _ level: OMEMOTrustLevel, accountID: UUID,
        peerJID: String, deviceID: UInt32, fingerprint: String
    ) async throws {
        guard let accountJID = accountJIDString(for: accountID), let peer = BareJID.parse(peerJID) else { return }
        let trustGuard = trustGuard(forAccountJID: accountJID)
        guard let grant = trustGuard.prepareGrant(peer: peer, deviceID: deviceID, fingerprint: fingerprint) else {
            throw OMEMOServiceError.identityKeyMismatch
        }
        if fingerprint.isEmpty {
            do {
                try await omemoStore.markTrust(
                    level, accountJID: accountJID, peerJID: peer.description, deviceID: deviceID, fallbackFingerprint: grant.fingerprint
                )
            } catch OMEMOStoreError.conflictingFingerprints {
                throw OMEMOServiceError.conflictingFingerprints
            }
        } else {
            try await omemoStore.saveTrust(OMEMOTrust(
                accountJID: accountJID, peerJID: peer.description,
                deviceID: deviceID, fingerprint: grant.fingerprint, trustLevel: level
            ))
        }
        trustGuard.applyGrant(peer: peer, deviceID: deviceID, decision: grant.decision)
    }

    func accountJIDString(for accountID: UUID) -> String? {
        accountService?.accounts.first(where: { $0.id == accountID })?.jid.description
    }
}

// MARK: - SeenDeviceClassificationProviding

extension OMEMOService: SeenDeviceClassificationProviding {
    package func loadSeenDevices(accountID: String) async -> [UInt32: SeenDeviceRecord] {
        if seenDeviceLoadedAccounts.contains(accountID) {
            return seenDeviceCacheByAccount[accountID] ?? [:]
        }
        if let pending = seenDevicePendingLoads[accountID] {
            // Wait for the in-flight load to finish, then read the merged
            // cache — returning `pending.value` directly would hand back the
            // raw store snapshot and miss any `mergeSeenDevices` that landed
            // during the await window.
            _ = await pending.value
            return seenDeviceCacheByAccount[accountID] ?? [:]
        }
        guard let accountJID = accountJIDsByAccountID[accountID] else {
            return seenDeviceCacheByAccount[accountID] ?? [:]
        }

        let store = omemoStore
        let task = Task<[UInt32: SeenDeviceRecord], Never> {
            // Store throws are absorbed per protocol contract; an empty map
            // signals "load failed" — the caller's view of the cache stays
            // in-memory only until the next attempt.
            let rows = await (try? store.loadSeenDevices(for: accountJID)) ?? []
            var loaded: [UInt32: SeenDeviceRecord] = [:]
            loaded.reserveCapacity(rows.count)
            for row in rows {
                guard let classification = BundleClassification(rawValue: row.classification) else {
                    // Forward-compat: a future build may write a
                    // classification the running binary doesn't know yet.
                    // Drop the row instead of crashing.
                    log.debug("OMEMO seen-device classification unrecognized: \(row.classification)")
                    continue
                }
                loaded[row.deviceID] = SeenDeviceRecord(
                    deviceID: row.deviceID,
                    lastClassification: classification,
                    staleStreak: row.staleStreak,
                    hasObservedHealthy: row.hasObservedHealthy
                )
            }
            return loaded
        }
        let generationBeforeAwait = seenDeviceLoadGeneration[accountID, default: 0]
        seenDevicePendingLoads[accountID] = task
        let loaded = await task.value
        seenDevicePendingLoads.removeValue(forKey: accountID)
        // Generation check: a clear/replace/purge during the await deliberately removed rows. Re-merging the loaded
        // snapshot would resurrect deletions and re-open the bypass-defense. Bail with whatever the explicit op produced.
        guard seenDeviceLoadGeneration[accountID, default: 0] == generationBeforeAwait else {
            return seenDeviceCacheByAccount[accountID] ?? [:]
        }
        // Merge per-ID: concurrent `mergeSeenDevices` rows win (fresher); the loaded snapshot fills gaps.
        // Wholesale-discard would lose persisted rows for un-merged devices; a subsequent `clearSeenDevicesAbsent`
        // would then delete them from the store, re-opening the bypass.
        var current = seenDeviceCacheByAccount[accountID] ?? [:]
        for (deviceID, record) in loaded where current[deviceID] == nil {
            current[deviceID] = record
        }
        seenDeviceCacheByAccount[accountID] = current
        seenDeviceLoadedAccounts.insert(accountID)
        return current
    }

    package func mergeSeenDevices(_ updates: [UInt32: SeenDeviceRecord], accountID: String) async {
        guard !updates.isEmpty else { return }
        var current = seenDeviceCacheByAccount[accountID] ?? [:]
        for (deviceID, record) in updates {
            current[deviceID] = record
        }
        seenDeviceCacheByAccount[accountID] = current
        guard let accountJID = accountJIDsByAccountID[accountID] else { return }
        let rows = updates.values.map {
            OMEMOStoredSeenDevice(
                accountJID: accountJID,
                deviceID: $0.deviceID,
                classification: $0.lastClassification.rawValue,
                staleStreak: $0.staleStreak,
                hasObservedHealthy: $0.hasObservedHealthy
            )
        }
        try? await omemoStore.upsertSeenDevices(rows, for: accountJID)
    }

    package func clearSeenDevicesAbsent(from currentDeviceIDs: Set<UInt32>, accountID: String) async {
        var current = seenDeviceCacheByAccount[accountID] ?? [:]
        current = current.filter { currentDeviceIDs.contains($0.key) }
        seenDeviceCacheByAccount[accountID] = current
        // Bump the load generation so an in-flight first-load that resumes
        // after this clear does NOT re-merge the loaded snapshot and
        // resurrect records this call deliberately dropped.
        seenDeviceLoadGeneration[accountID, default: 0] &+= 1
        guard let accountJID = accountJIDsByAccountID[accountID] else { return }
        let rows = current.values.map {
            OMEMOStoredSeenDevice(
                accountJID: accountJID,
                deviceID: $0.deviceID,
                classification: $0.lastClassification.rawValue,
                staleStreak: $0.staleStreak,
                hasObservedHealthy: $0.hasObservedHealthy
            )
        }
        try? await omemoStore.replaceSeenDevices(rows, for: accountJID)
    }

    package func replaceSeenDevices(_ records: [UInt32: SeenDeviceRecord], accountID: String) async {
        seenDeviceCacheByAccount[accountID] = records
        seenDeviceLoadedAccounts.insert(accountID)
        // Bump generation — see `loadSeenDevices` for the race-guard semantics.
        seenDeviceLoadGeneration[accountID, default: 0] &+= 1
        guard let accountJID = accountJIDsByAccountID[accountID] else { return }
        let rows = records.values.map {
            OMEMOStoredSeenDevice(
                accountJID: accountJID,
                deviceID: $0.deviceID,
                classification: $0.lastClassification.rawValue,
                staleStreak: $0.staleStreak,
                hasObservedHealthy: $0.hasObservedHealthy
            )
        }
        try? await omemoStore.replaceSeenDevices(rows, for: accountJID)
    }
}

// MARK: - OMEMOIdentityPersisting

/// Runs inside the module's setup attempt rather than on an event task, so a requested disconnect's cancelled event
/// consumer cannot drop it.
extension OMEMOService: OMEMOIdentityPersisting {
    package func persistNewIdentity(_ data: OMEMOModule.OMEMOIdentityData, accountID: String) async -> Bool {
        guard let accountJID = accountJIDsByAccountID[accountID] else { return false }
        return await persistFirstTimeIdentity(data, accountJID: accountJID)
    }
}

// MARK: - EmergencyRetractGuarding

extension OMEMOService: EmergencyRetractGuarding {
    package func tryClaimInFlight(accountID: String) async -> Bool {
        guard !emergencyRetractInFlightAccounts.contains(accountID) else { return false }
        emergencyRetractInFlightAccounts.insert(accountID)
        return true
    }

    package func releaseInFlight(accountID: String) async {
        emergencyRetractInFlightAccounts.remove(accountID)
    }
}

// MARK: - OrphanDeviceRecordPurging

extension OMEMOService: OrphanDeviceRecordPurging {
    package func purgeOrphanDeviceRecords(deviceIDs: [UInt32], accountID: String) async throws {
        guard let accountJID = accountJIDsByAccountID[accountID] else { return }
        // Own-account own-device rows: peerJID == accountJID. Per-deviceID
        // failures are surfaced — the emergency-retract caller decides
        // whether to fail-loud (recommended) or swallow.
        for deviceID in deviceIDs {
            try await omemoStore.deleteTrust(
                accountJID: accountJID, peerJID: accountJID, deviceID: deviceID
            )
            try await omemoStore.deleteSession(
                accountJID: accountJID, peerJID: accountJID, peerDeviceID: deviceID, version: nil
            )
        }
    }
}

// MARK: - Errors

enum OMEMOServiceError: Error, LocalizedError {
    case notConnected(UUID)
    case omemoNotAvailable
    case noTrustedRecipients
    case identityKeyMismatch
    case conflictingFingerprints
    case noFingerprintToVerify
    case thisDeviceNotResettable
    case encryptionNotSetUp

    var errorDescription: String? {
        switch self {
        case .notConnected: notConnectedDescription
        case .omemoNotAvailable: "OMEMO module not available"
        case .noTrustedRecipients: "No trusted OMEMO recipients"
        case .identityKeyMismatch: "The fingerprint does not match the key in use for this device"
        case .conflictingFingerprints: "This device has more than one fingerprint, so it cannot be trusted"
        case .noFingerprintToVerify: "The device's fingerprint is not known yet, so it cannot be verified"
        case .thisDeviceNotResettable: "This device has no encryption session with itself to reset"
        case .encryptionNotSetUp: "This device's encryption setup is incomplete"
        }
    }
}

private extension OMEMOTrustLevel {
    /// An undecided row is no decision, so the guard never lets one lift a refusal.
    var storedDecision: OMEMOTrustGuard.StoredTrust.Decision {
        switch self {
        case .undecided: .undecided
        case .trusted, .verified: .granted
        case .untrusted: .untrusted
        }
    }
}
