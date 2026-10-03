import CryptoKit
import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.omemo")

private func omemoFingerprint(from identityKey: some Sequence<UInt8>) -> String {
    identityKey.map { String(format: "%02x", $0) }.joined()
}

@MainActor @Observable
public final class OMEMOService {
    private let omemoStore: any OMEMOStore
    private weak var accountService: AccountService?
    private weak var chatService: ChatService?
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

    /// UI-supplied confirmation closure before the emergency-retract path publishes a singleton devicelist.
    /// Default `nil` preserves the pre-feature bail behavior. `@Sendable`; callers hop to `MainActor` inside.
    public var emergencyRetractConfirmation: (@Sendable (_ deviceCount: Int, _ ownDeviceID: UInt32) async -> Bool)?

    public init(omemoStore: any OMEMOStore) {
        self.omemoStore = omemoStore
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

    /// Drops the seen-device classification entry + persisted rows for `accountID`. Called by `AccountService.deleteAccount`.
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
    func buildModule(for accountJID: BareJID, accountID: UUID, pepModule: PEPModule) async -> OMEMOModule {
        let module = OMEMOModule(pepModule: pepModule)
        let jidString = accountJID.description

        wireIdentityKeyValidator(on: module, accountJID: jidString)
        // Wire pruneStaleBundles' service-side dependencies. See `seenDeviceCacheByAccount` for the reconnect-survival rationale.
        let accountIDKey = accountID.uuidString
        accountJIDsByAccountID[accountIDKey] = jidString
        module.configureSeenDeviceClassificationProvider(self, accountID: accountIDKey)
        module.configureEmergencyRetract(
            confirmation: emergencyRetractConfirmation,
            guard: self,
            orphanPurger: self
        )

        // Restore persisted identity
        if let stored = try? await omemoStore.loadIdentity(for: jidString) {
            let preKeys = await (try? omemoStore.loadPreKeys(for: jidString)) ?? []
            let signedPreKey = try? await omemoStore.loadSignedPreKey(for: jidString)

            let preKeyData = preKeys.filter { !$0.isUsed }.map {
                OMEMOModule.OMEMOIdentityData.PreKeyData(
                    keyID: $0.keyID, keyRaw: Array($0.keyData)
                )
            }

            if let spk = signedPreKey {
                let identityData = OMEMOModule.OMEMOIdentityData(
                    deviceID: stored.deviceID,
                    identityKeyRaw: Array(stored.identityKeyData),
                    signedPreKeyID: spk.keyID,
                    signedPreKeyRaw: Array(spk.keyData),
                    signedPreKeySignature: Array(spk.signature),
                    preKeys: preKeyData
                )
                module.configureIdentity(identityData)
            }
        }

        // Restore persisted sessions
        if let sessions = try? await omemoStore.loadSessions(for: jidString) {
            let entries = sessions.map {
                OMEMOModule.StoredSessionEntry(
                    jid: BareJID.parse($0.peerJID) ?? accountJID,
                    deviceID: $0.peerDeviceID,
                    sessionData: Array($0.sessionData),
                    associatedData: Array($0.associatedData)
                )
            }
            module.restoreSessions(entries)
        }

        return module
    }

    // MARK: - Event Handling

    func handleEvent(_ event: XMPPEvent, accountID: UUID) async {
        switch event {
        case let .omemoDeviceListReceived(jid, devices):
            await handleDeviceListReceived(jid: jid, devices: devices, accountID: accountID)
        case let .omemoEncryptedMessageReceived(from, decryptedBody, _, stanzaID):
            await handleEncryptedMessageReceived(from: from, decryptedBody: decryptedBody, stanzaID: stanzaID, accountID: accountID)
        case let .omemoSessionEstablished(jid, deviceID, identityKey):
            await handleSessionEstablished(
                jid: jid, deviceID: deviceID,
                identityKey: identityKey, accountID: accountID
            )
        case .omemoSessionAdvanced:
            if let client = accountService?.connectedClient(for: accountID),
               let omemoModule = await client.module(ofType: OMEMOModule.self) {
                await saveModuleSessions(module: omemoModule, accountID: accountID)
            }
        case .connected:
            await handleConnected(accountID: accountID)
        case .disconnected:
            break
        case .streamResumed, .authenticationFailed,
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
             .oobIQOfferReceived, .serviceOutageReceived:
            break
        }
    }

    // MARK: - Encryption

    /// Resolution from `shouldEncrypt`. Names describe what the *local trust store* says, not the peer's actual state
    /// (the peer's devicelist may not have been received yet). Callers fail-closed on the three "don't encrypt" cases
    /// when the conversation has encryption enabled.
    public enum EncryptionResolution: Sendable {
        /// Encryption authorized; encrypt to these recipient device IDs.
        case proceed(trustedDeviceIDs: [UInt32])
        /// Conversation has encryption disabled by the user; plaintext is
        /// intentional.
        case userDisabled
        /// Local trust store has no devices for this peer. Possible causes:
        /// `+notify` not received yet, peer has no OMEMO, fresh install.
        case noLocalDevicesForPeer
        /// Local trust store has peer devices but none are trusted.
        case noTrustedDevicesForPeer
        /// Service not wired (tests only; production wires at app start). Distinct from `.proceed` so callers throw `omemoServiceUnavailable` without a nil check.
        case serviceUnavailable
    }

    /// Resolves encryption for a 1:1 send. Callers treat `.noLocalDevicesForPeer` / `.noTrustedDevicesForPeer` as throw conditions when the conversation has encryption enabled.
    func shouldEncrypt(jid: BareJID, accountID: UUID, conversationEncryptionEnabled: Bool) async -> EncryptionResolution {
        guard conversationEncryptionEnabled else { return .userDisabled }
        guard let accountJID = accountJIDString(for: accountID) else {
            return .noLocalDevicesForPeer
        }
        let allDevices = await (try? omemoStore.loadAllDevices(for: jid.description, accountJID: accountJID)) ?? []
        if allDevices.isEmpty {
            return .noLocalDevicesForPeer
        }
        let tofu = OMEMOPreferences.shared.trustOnFirstUse
        let trusted = allDevices.filter { $0.trustLevel.isTrustedForEncryption(trustOnFirstUse: tofu) }.map(\.deviceID)
        if trusted.isEmpty {
            return .noTrustedDevicesForPeer
        }
        return .proceed(trustedDeviceIDs: trusted)
    }

    func encryptMessage(
        body: String,
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
            plaintext: body, to: jid,
            recipientDeviceIDs: trustedDeviceIDs, ownDeviceIDs: ownDeviceIDs
        )

        await saveModuleSessions(module: omemoModule, accountID: accountID)

        return elements
    }

    private func trustedDeviceIDs(for jid: BareJID, accountID: UUID) async -> [UInt32] {
        guard let accountJID = accountJIDString(for: accountID) else { return [] }
        let allDevices = await (try? omemoStore.loadAllDevices(for: jid.description, accountJID: accountJID)) ?? []
        let tofu = OMEMOPreferences.shared.trustOnFirstUse
        return allDevices.filter { $0.trustLevel.isTrustedForEncryption(trustOnFirstUse: tofu) }.map(\.deviceID)
    }

    private func trustedOwnDeviceIDs(accountID: UUID) async -> [UInt32] {
        guard let ownJID = accountService?.accounts.first(where: { $0.id == accountID })?.jid else { return [] }
        guard let accountJID = accountJIDString(for: accountID) else { return [] }
        // Own devices always use TOFU semantics — refusing to encrypt to your
        // own undecided devices breaks multi-device message sync.
        let allDevices = await (try? omemoStore.loadAllDevices(for: ownJID.description, accountJID: accountJID)) ?? []
        return allDevices.filter { $0.trustLevel.isTrustedForEncryption(trustOnFirstUse: true) }.map(\.deviceID)
    }

    // MARK: - Trust Management

    public func trustDevice(accountID: UUID, peerJID: String, deviceID: UInt32, fingerprint: String) async throws {
        try await setTrustLevel(.trusted, accountID: accountID, peerJID: peerJID, deviceID: deviceID, fingerprint: fingerprint)
    }

    public func untrustDevice(accountID: UUID, peerJID: String, deviceID: UInt32) async throws {
        guard let accountJID = accountJIDString(for: accountID) else { return }
        guard let existing = try await omemoStore.loadTrust(accountJID: accountJID, peerJID: peerJID, deviceID: deviceID) else { return }
        try await setTrustLevel(.untrusted, accountID: accountID, peerJID: peerJID, deviceID: deviceID, fingerprint: existing.fingerprint)
    }

    public func verifyDevice(accountID: UUID, peerJID: String, deviceID: UInt32, fingerprint: String) async throws {
        try await setTrustLevel(.verified, accountID: accountID, peerJID: peerJID, deviceID: deviceID, fingerprint: fingerprint)
    }

    public func ownFingerprint(accountID: UUID) async -> String? {
        await ownDeviceInfo(accountID: accountID)?.fingerprint
    }

    /// Returns device info for all known devices of a peer, suitable for UI display.
    public func deviceInfoList(for peerJID: String, accountID: UUID) async -> [OMEMODeviceInfo] {
        guard let accountJID = accountJIDString(for: accountID) else { return [] }
        let devices = await (try? omemoStore.loadAllDevices(for: peerJID, accountJID: accountJID)) ?? []
        return devices.map {
            OMEMODeviceInfo(
                peerJID: $0.peerJID, deviceID: $0.deviceID,
                fingerprint: $0.fingerprint, trustLevel: $0.trustLevel
            )
        }
    }

    /// Returns own device info (device ID + fingerprint) for side-by-side verification.
    public func ownDeviceInfo(accountID: UUID) async -> OMEMODeviceInfo? {
        guard let accountJID = accountJIDString(for: accountID) else { return nil }
        guard let identity = try? await omemoStore.loadIdentity(for: accountJID) else { return nil }
        guard let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: identity.identityKeyData) else {
            return nil
        }
        let fingerprint = omemoFingerprint(from: privateKey.publicKey.rawRepresentation)
        return OMEMODeviceInfo(
            peerJID: accountJID, deviceID: identity.deviceID,
            fingerprint: fingerprint, trustLevel: .verified
        )
    }

    // MARK: - Group Chat Encryption

    /// Encrypts a message for all members of a group chat room.
    func encryptGroupMessage(
        body: String,
        roomJID: BareJID,
        memberJIDs: [BareJID],
        accountID: UUID
    ) async throws -> OMEMOModule.EncryptedMessageElements {
        guard let client = accountService?.connectedClient(for: accountID) else {
            throw OMEMOServiceError.notConnected(accountID)
        }
        guard let omemoModule = await client.module(ofType: OMEMOModule.self) else {
            throw OMEMOServiceError.omemoNotAvailable
        }

        let recipients = await buildGroupRecipients(memberJIDs: memberJIDs, accountID: accountID)
        guard !recipients.isEmpty else {
            throw OMEMOServiceError.noTrustedRecipients
        }

        let ownDeviceIDs = await trustedOwnDeviceIDs(accountID: accountID)
        let elements = try await omemoModule.encryptGroupMessage(
            plaintext: body, roomJID: roomJID,
            recipients: recipients, ownDeviceIDs: ownDeviceIDs
        )
        await saveModuleSessions(module: omemoModule, accountID: accountID)
        return elements
    }

    private func buildGroupRecipients(
        memberJIDs: [BareJID],
        accountID: UUID
    ) async -> [(jid: BareJID, deviceIDs: [UInt32])] {
        // Exclude own JID — encryptGroupMessage encrypts for own devices separately
        let ownJID = accountService?.accounts.first(where: { $0.id == accountID })?.jid
        let filtered = memberJIDs.filter { $0 != ownJID }
        return await withTaskGroup(of: (BareJID, [UInt32]).self) { group in
            for jid in filtered {
                group.addTask {
                    let deviceIDs = await self.trustedDeviceIDs(for: jid, accountID: accountID)
                    return (jid, deviceIDs)
                }
            }
            var recipients: [(jid: BareJID, deviceIDs: [UInt32])] = []
            for await (jid, deviceIDs) in group where !deviceIDs.isEmpty {
                recipients.append((jid: jid, deviceIDs: deviceIDs))
            }
            return recipients
        }
    }

    // MARK: - Private Event Handlers

    private func handleDeviceListReceived(jid: BareJID, devices: [UInt32], accountID: UUID) async {
        guard let accountJID = accountJIDString(for: accountID) else { return }
        let existing = await (try? omemoStore.loadAllDevices(for: jid.description, accountJID: accountJID)) ?? []
        let knownDeviceIDs = Set(existing.map(\.deviceID))
        for deviceID in devices where !knownDeviceIDs.contains(deviceID) {
            let trust = OMEMOTrust(
                accountJID: accountJID, peerJID: jid.description,
                deviceID: deviceID, fingerprint: "", trustLevel: .undecided
            )
            try? await omemoStore.saveTrust(trust)
        }
    }

    private func handleEncryptedMessageReceived(from: JID, decryptedBody: String?, stanzaID: String?, accountID: UUID) async {
        let senderJID = from.bareJID
        guard let chatService else { return }

        // Capture the arrival tick now, before the first await, so the resource lock learned below advances in
        // arrival order even if this handler interleaves with another inbound's handler on the MainActor.
        let lockSequence = chatService.nextLockSequence()

        // Determine if this is our own message echoed back (carbon/MAM)
        let ownJID = accountService?.accounts.first(where: { $0.id == accountID })?.jid
        let isOutgoing = ownJID != nil && senderJID == ownJID
        let peerJID = isOutgoing ? (from.bareJID) : senderJID

        let conversation: Conversation
        do {
            conversation = try await chatService.openConversation(for: peerJID, accountID: accountID)
        } catch {
            log.warning("Failed to open conversation for OMEMO message from \(senderJID): \(error)")
            return
        }

        let message = ChatMessage(
            id: UUID(),
            conversationID: conversation.id,
            serverID: stanzaID,
            fromJID: peerJID.description,
            body: decryptedBody ?? "",
            timestamp: Date(),
            isOutgoing: isOutgoing,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            isEncrypted: true,
            isUndecryptable: decryptedBody == nil
        )

        // RFC 6121 §5.1 resource lock — learn the peer's resource from the live encrypted inbound, mirroring
        // the plaintext path in ChatService. Own-message echoes (carbon/MAM) still persist below but must not
        // move the lock (gated on `!isOutgoing`), and a nil body is a failed/unauthenticated decrypt that must
        // not steer routing (gated on `decryptedBody != nil`).
        if !isOutgoing, decryptedBody != nil {
            chatService.learnResourceLock(from: from, accountID: accountID, sequence: lockSequence)
        }
        await chatService.persistEncryptedMessage(message, in: conversation, accountID: accountID)
        // Only a message from the contact that this device could read counts. An echo of the user's own message says
        // nothing about the contact, and a failed decrypt is no ground for encrypting the reply.
        if !isOutgoing, decryptedBody != nil {
            await chatService.enableEncryptionForContact(in: conversation.id, accountID: accountID)
        }

        // Persist session state after decryption (ratchet may have advanced)
        if let client = accountService?.connectedClient(for: accountID),
           let omemoModule = await client.module(ofType: OMEMOModule.self) {
            await saveModuleSessions(module: omemoModule, accountID: accountID)
        }
    }

    private func handleSessionEstablished(
        jid: BareJID, deviceID: UInt32,
        identityKey: [UInt8], accountID: UUID
    ) async {
        guard let client = accountService?.connectedClient(for: accountID),
              let omemoModule = await client.module(ofType: OMEMOModule.self)
        else { return }

        guard let entry = omemoModule.exportSession(jid: jid, deviceID: deviceID) else { return }
        guard let accountJID = accountJIDString(for: accountID) else { return }

        let session = OMEMOStoredSession(
            accountJID: accountJID, peerJID: jid.description,
            peerDeviceID: deviceID,
            sessionData: Data(entry.sessionData),
            associatedData: Data(entry.associatedData)
        )
        try? await omemoStore.saveSession(session)

        let fingerprint = omemoFingerprint(from: identityKey)
        let existing = try? await omemoStore.loadTrust(
            accountJID: accountJID, peerJID: jid.description, deviceID: deviceID
        )
        if let existing, existing.fingerprint.isEmpty {
            // Fill placeholder fingerprint
            let updated = OMEMOTrust(
                accountJID: accountJID, peerJID: jid.description,
                deviceID: deviceID, fingerprint: fingerprint,
                trustLevel: existing.trustLevel
            )
            try? await omemoStore.saveTrust(updated)
        } else if let existing, !existing.fingerprint.isEmpty, existing.fingerprint != fingerprint {
            log.warning("Identity key changed for \(jid) device \(deviceID)")
        } else if existing == nil {
            // New device — create undecided trust record with fingerprint
            let trust = OMEMOTrust(
                accountJID: accountJID, peerJID: jid.description,
                deviceID: deviceID, fingerprint: fingerprint,
                trustLevel: .undecided
            )
            try? await omemoStore.saveTrust(trust)
        }
    }

    private func handleConnected(accountID: UUID) async {
        guard let client = accountService?.connectedClient(for: accountID),
              let omemoModule = await client.module(ofType: OMEMOModule.self)
        else { return }
        guard let accountJID = accountJIDString(for: accountID) else { return }

        // Wait until initial presence + caps are on the wire so PEP publishes follow the server seeing
        // this resource's caps (XEP-0163 §3.3.2). The identity poll below composes after this gate.
        await client.awaitInitialPresenceSent()

        await handleConnectedFirstTimePersistence(
            provider: omemoModule,
            accountJID: accountJID
        )

        await replenishPreKeysIfNeeded(accountJID: accountJID, module: omemoModule)
    }

    /// First-time identity persistence + consumed-pre-key sync. Extracted so tests can drive the polling/persistence
    /// branches via a stub `OMEMOIdentityProviding` and a short `pollTimeout` (bypassing the 5s real wait).
    package func handleConnectedFirstTimePersistence(
        provider: any OMEMOIdentityProviding,
        accountJID: String,
        pollTimeout: Duration = .seconds(5)
    ) async {
        // First-time persistence only: if an identity is already stored, the
        // module will restore it on handleConnect and there's nothing to do
        // here. Skip both the readiness poll and the persistence writes.
        let existingIdentity = try? await omemoStore.loadIdentity(for: accountJID)
        if existingIdentity == nil {
            // `.connected` is yielded before `OMEMOModule.handleConnect` runs,
            // so `ownIdentityData` may still be `nil` on first-time generation.
            // Poll up to `pollTimeout` (default ~5 s — two IQ round-trips:
            // publish device list + bundle). Capture the identity inside the
            // closure to avoid a re-read race with `handleDisconnect` nil'ing
            // `ownIdentity`.
            var captured: OMEMOModule.OMEMOIdentityData?
            _ = await pollUntil(
                {
                    if let data = provider.ownIdentityData {
                        captured = data
                        return true
                    }
                    return false
                },
                timeout: pollTimeout,
                interval: .milliseconds(50)
            )
            if let identityData = captured {
                let stored = OMEMOStoredIdentity(
                    accountJID: accountJID,
                    deviceID: identityData.deviceID,
                    identityKeyData: Data(identityData.identityKeyRaw),
                    registrationID: 0
                )
                try? await omemoStore.saveIdentity(stored)

                let preKeys = identityData.preKeys.map {
                    OMEMOStoredPreKey(
                        accountJID: accountJID, keyID: $0.keyID,
                        keyData: Data($0.keyRaw), isUsed: false
                    )
                }
                try? await omemoStore.savePreKeys(preKeys)

                let spk = OMEMOStoredSignedPreKey(
                    accountJID: accountJID,
                    keyID: identityData.signedPreKeyID,
                    keyData: Data(identityData.signedPreKeyRaw),
                    signature: Data(identityData.signedPreKeySignature),
                    timestamp: Date()
                )
                try? await omemoStore.saveSignedPreKey(spk)
            } else {
                log.warning("OMEMO identity not ready after \(pollTimeout) wait; skipping first-time persistence")
            }
        }

        // Mark consumed pre-keys
        let consumed = provider.consumedPreKeyIDs()
        for keyID in consumed {
            try? await omemoStore.consumePreKey(id: keyID, accountJID: accountJID)
        }
    }

    private func saveModuleSessions(module: OMEMOModule, accountID: UUID) async {
        guard let accountJID = accountJIDString(for: accountID) else { return }
        let entries = module.allSessionEntries()
        for entry in entries {
            let session = OMEMOStoredSession(
                accountJID: accountJID, peerJID: entry.jid.description,
                peerDeviceID: entry.deviceID,
                sessionData: Data(entry.sessionData),
                associatedData: Data(entry.associatedData)
            )
            try? await omemoStore.saveSession(session)
        }
    }

    private func wireIdentityKeyValidator(on module: OMEMOModule, accountJID: String) {
        let store = omemoStore
        module.setIdentityKeyValidator { peerJID, deviceID, identityKey in
            let existing = try await store.loadTrust(
                accountJID: accountJID, peerJID: peerJID.description,
                deviceID: deviceID
            )
            if let existing {
                if existing.trustLevel == .untrusted {
                    throw OMEMOServiceError.identityKeyUntrusted
                }
                if !existing.fingerprint.isEmpty {
                    let fingerprint = omemoFingerprint(from: identityKey)
                    if existing.fingerprint != fingerprint {
                        throw OMEMOServiceError.identityKeyMismatch
                    }
                }
            }
            // No trust record or empty fingerprint — allow (TOFU);
            // fingerprint stored on session-established event
        }
    }

    private func replenishPreKeysIfNeeded(accountJID: String, module: OMEMOModule) async {
        let preKeys = await (try? omemoStore.loadPreKeys(for: accountJID)) ?? []
        let available = preKeys.filter { !$0.isUsed }
        guard available.count < OMEMOPreKeyManager.minimumPreKeyCount else { return }

        guard let identityData = module.ownIdentityData else { return }
        let maxExistingID = preKeys.map(\.keyID).max() ?? 0
        let startID = maxExistingID + 1
        let count = OMEMOPreKeyManager.targetPreKeyCount - available.count

        let newPreKeys = OMEMOPreKeyManager.generatePreKeys(startID: startID, count: count)
        let storedPreKeys = newPreKeys.map {
            OMEMOStoredPreKey(
                accountJID: accountJID, keyID: $0.keyID,
                keyData: Data($0.rawRepresentation), isUsed: false
            )
        }
        try? await omemoStore.savePreKeys(storedPreKeys)

        // Republish bundle with updated pre-keys
        let allPreKeys = await (try? omemoStore.loadPreKeys(for: accountJID))?.filter { !$0.isUsed } ?? []
        let updatedIdentity = OMEMOModule.OMEMOIdentityData(
            deviceID: identityData.deviceID,
            identityKeyRaw: identityData.identityKeyRaw,
            signedPreKeyID: identityData.signedPreKeyID,
            signedPreKeyRaw: identityData.signedPreKeyRaw,
            signedPreKeySignature: identityData.signedPreKeySignature,
            preKeys: allPreKeys.map {
                OMEMOModule.OMEMOIdentityData.PreKeyData(keyID: $0.keyID, keyRaw: Array($0.keyData))
            }
        )
        module.configureIdentity(updatedIdentity)
        log.info("Replenished pre-keys: \(count) new, \(allPreKeys.count) total available")
    }

    private func setTrustLevel(
        _ level: OMEMOTrustLevel, accountID: UUID,
        peerJID: String, deviceID: UInt32, fingerprint: String
    ) async throws {
        guard let accountJID = accountJIDString(for: accountID) else { return }
        let trust = OMEMOTrust(
            accountJID: accountJID, peerJID: peerJID,
            deviceID: deviceID, fingerprint: fingerprint, trustLevel: level
        )
        try await omemoStore.saveTrust(trust)
    }

    private func accountJIDString(for accountID: UUID) -> String? {
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
                accountJID: accountJID, peerJID: accountJID, peerDeviceID: deviceID
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
    case identityKeyUntrusted

    var errorDescription: String? {
        switch self {
        case .notConnected: notConnectedDescription
        case .omemoNotAvailable: "OMEMO module not available"
        case .noTrustedRecipients: "No trusted OMEMO recipients"
        case .identityKeyMismatch: "OMEMO identity key mismatch"
        case .identityKeyUntrusted: "OMEMO identity key not trusted"
        }
    }
}
