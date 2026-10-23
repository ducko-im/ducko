import DuckoCore
import Foundation
@testable import DuckoXMPP

/// In-memory mock of `OMEMOStore` for unit tests. The identity / pre-key /
/// signed-pre-key save methods bump per-surface counters so tests can assert
/// "no overwrite" / "exactly one write" without inspecting the persisted
/// bytes; `saveSession` and `saveTrust` deliberately do NOT bump counters —
/// they perform idempotent upserts (matching `SwiftDataOMEMOStore` semantics)
/// and tests assert via `loadSessions` / `loadAllDevices` round-trip instead.
/// Counter-bypassing seed helpers pre-populate the store without inflating the
/// counters.
actor MockOMEMOStore: OMEMOStore {
    private var identity: [String: OMEMOStoredIdentity] = [:]
    private var preKeys: [String: [OMEMOStoredPreKey]] = [:]
    private var signedPreKey: [String: OMEMOStoredSignedPreKey] = [:]
    private var sessions: [String: [OMEMOStoredSession]] = [:]
    private var trusts: [String: [OMEMOTrust]] = [:]
    private var seenDevices: [String: [UInt32: OMEMOStoredSeenDevice]] = [:]

    private(set) var saveIdentityCalls = 0
    private(set) var loadPreKeysCalls = 0
    private(set) var savePreKeysCalls = 0
    private(set) var saveSignedPreKeyCalls = 0
    private(set) var loadSeenDevicesCalls = 0
    private(set) var deleteTrustCalls = 0
    private(set) var deleteSessionCalls = 0

    /// Failure switches: each call named here throws instead of touching the store.
    enum FailingCall: Hashable {
        case loadIdentity, loadPreKeys, loadSignedPreKey, loadSessions, loadAllTrust, saveIdentity, savePreKeys, saveSignedPreKey, consumePreKey,
             saveTrust, markTrust,
             // Makes `markTrust` refuse a grant as a store does when a device's rows would disagree.
             markTrustConflict
    }

    struct InjectedFailure: Error {}

    private var failingCalls: Set<FailingCall> = []
    /// Runs once, at the next `saveTrust` or `markTrust` that does not fail, before it writes.
    private var beforeTrustWrite: (@Sendable () async -> Void)?

    func setBeforeTrustWrite(_ action: @escaping @Sendable () async -> Void) {
        beforeTrustWrite = action
    }

    private func runBeforeTrustWrite() async {
        let action = beforeTrustWrite
        beforeTrustWrite = nil
        await action?()
    }

    func setFailing(_ call: FailingCall, _ failing: Bool = true) {
        if failing {
            failingCalls.insert(call)
        } else {
            failingCalls.remove(call)
        }
    }

    private func failIfSwitched(_ call: FailingCall) throws {
        if failingCalls.contains(call) { throw InjectedFailure() }
    }

    func seedIdentity(_ identity: OMEMOStoredIdentity) {
        self.identity[identity.accountJID] = identity
    }

    func seedPreKeys(_ keys: [OMEMOStoredPreKey]) {
        for key in keys {
            preKeys[key.accountJID, default: []].append(key)
        }
    }

    func seedSignedPreKey(_ key: OMEMOStoredSignedPreKey) {
        signedPreKey[key.accountJID] = key
    }

    /// Seeds the store with rows derived from `identity` for `accountJID`,
    /// keeping the persisted bytes in lock-step with what an
    /// `OMEMOIdentityProviding` stub would advertise.
    func seedFromIdentityData(_ identity: OMEMOModule.OMEMOIdentityData, accountJID: String) {
        seedIdentity(OMEMOStoredIdentity(
            accountJID: accountJID, deviceID: identity.deviceID,
            identityKeyData: Data(identity.identityKeyRaw),
            registrationID: 0
        ))
        seedPreKeys(identity.preKeys.map {
            OMEMOStoredPreKey(
                accountJID: accountJID, keyID: $0.keyID,
                keyData: Data($0.keyRaw), isUsed: false
            )
        })
        seedSignedPreKey(OMEMOStoredSignedPreKey(
            accountJID: accountJID,
            keyID: identity.signedPreKeyID,
            keyData: Data(identity.signedPreKeyRaw),
            signature: Data(identity.signedPreKeySignature),
            timestamp: Date()
        ))
    }

    // MARK: - Identity

    func loadIdentity(for accountJID: String) async throws -> OMEMOStoredIdentity? {
        try failIfSwitched(.loadIdentity)
        return identity[accountJID]
    }

    func saveIdentity(_ identity: OMEMOStoredIdentity) async throws {
        saveIdentityCalls += 1
        try failIfSwitched(.saveIdentity)
        self.identity[identity.accountJID] = identity
    }

    // MARK: - Pre-Keys

    func loadPreKeys(for accountJID: String) async throws -> [OMEMOStoredPreKey] {
        loadPreKeysCalls += 1
        try failIfSwitched(.loadPreKeys)
        return preKeys[accountJID] ?? []
    }

    func savePreKeys(_ preKeys: [OMEMOStoredPreKey]) async throws {
        savePreKeysCalls += 1
        try failIfSwitched(.savePreKeys)
        for key in preKeys {
            self.preKeys[key.accountJID, default: []].append(key)
        }
    }

    func consumePreKey(id: UInt32, accountJID: String) async throws {
        try failIfSwitched(.consumePreKey)
        // Match production `SwiftDataOMEMOStore.consumePreKey` semantics: every row matching `(accountJID, keyID)`,
        // duplicates from `savePreKeys`'s append included, becomes a used tombstone without key data.
        preKeys[accountJID] = preKeys[accountJID]?.map { key in
            guard key.keyID == id else { return key }
            return OMEMOStoredPreKey(accountJID: accountJID, keyID: key.keyID, keyData: Data(), isUsed: true)
        }
    }

    // MARK: - Signed Pre-Key

    func loadSignedPreKey(for accountJID: String) async throws -> OMEMOStoredSignedPreKey? {
        try failIfSwitched(.loadSignedPreKey)
        return signedPreKey[accountJID]
    }

    func saveSignedPreKey(_ key: OMEMOStoredSignedPreKey) async throws {
        saveSignedPreKeyCalls += 1
        try failIfSwitched(.saveSignedPreKey)
        signedPreKey[key.accountJID] = key
    }

    // MARK: - Sessions

    func loadSessions(for accountJID: String) async throws -> [OMEMOStoredSession] {
        try failIfSwitched(.loadSessions)
        return sessions[accountJID] ?? []
    }

    func saveSession(_ session: OMEMOStoredSession) async throws {
        var rows = sessions[session.accountJID] ?? []
        if let index = rows.firstIndex(where: {
            $0.peerJID == session.peerJID && $0.peerDeviceID == session.peerDeviceID
        }) {
            rows[index] = session
        } else {
            rows.append(session)
        }
        sessions[session.accountJID] = rows
    }

    // MARK: - Trust

    func saveTrust(_ trust: OMEMOTrust) async throws {
        try failIfSwitched(.saveTrust)
        await runBeforeTrustWrite()
        upsertTrust(trust)
    }

    func insertTrustIfAbsent(_ trust: OMEMOTrust) async throws {
        guard trustRow(accountJID: trust.accountJID, peerJID: trust.peerJID, deviceID: trust.deviceID) == nil else { return }
        upsertTrust(trust)
    }

    func markTrust(_ level: OMEMOTrustLevel, accountJID: String, peerJID: String, deviceID: UInt32, fallbackFingerprint: String) async throws {
        try failIfSwitched(.markTrust)
        if level != .untrusted, failingCalls.contains(.markTrustConflict) { throw OMEMOStoreError.conflictingFingerprints }
        await runBeforeTrustWrite()
        let stored = trustRow(accountJID: accountJID, peerJID: peerJID, deviceID: deviceID)?.fingerprint ?? ""
        let fingerprint = stored.isEmpty ? fallbackFingerprint : stored
        upsertTrust(OMEMOTrust(accountJID: accountJID, peerJID: peerJID, deviceID: deviceID, fingerprint: fingerprint, trustLevel: level))
    }

    func fillTrustFingerprint(accountJID: String, peerJID: String, deviceID: UInt32, fingerprint: String) async throws -> String? {
        guard let existing = trustRow(accountJID: accountJID, peerJID: peerJID, deviceID: deviceID) else {
            upsertTrust(OMEMOTrust(accountJID: accountJID, peerJID: peerJID, deviceID: deviceID, fingerprint: fingerprint, trustLevel: .undecided))
            return nil
        }
        guard existing.fingerprint.isEmpty else { return existing.fingerprint == fingerprint ? nil : existing.fingerprint }
        upsertTrust(OMEMOTrust(accountJID: accountJID, peerJID: peerJID, deviceID: deviceID, fingerprint: fingerprint, trustLevel: existing.trustLevel))
        return nil
    }

    private func trustRow(accountJID: String, peerJID: String, deviceID: UInt32) -> OMEMOTrust? {
        trusts[accountJID]?.first { $0.peerJID == peerJID && $0.deviceID == deviceID }
    }

    private func upsertTrust(_ trust: OMEMOTrust) {
        var rows = trusts[trust.accountJID] ?? []
        if let index = rows.firstIndex(where: {
            $0.peerJID == trust.peerJID && $0.deviceID == trust.deviceID
        }) {
            rows[index] = trust
        } else {
            rows.append(trust)
        }
        trusts[trust.accountJID] = rows
    }

    func loadAllDevices(for peerJID: String, accountJID: String) async throws -> [OMEMOTrust] {
        trusts[accountJID]?.filter { $0.peerJID == peerJID } ?? []
    }

    func loadAllTrust(for accountJID: String) async throws -> [OMEMOTrust] {
        try failIfSwitched(.loadAllTrust)
        return trusts[accountJID] ?? []
    }

    func deleteTrust(accountJID: String, peerJID: String, deviceID: UInt32) async throws {
        deleteTrustCalls += 1
        guard var rows = trusts[accountJID] else { return }
        rows.removeAll { $0.peerJID == peerJID && $0.deviceID == deviceID }
        trusts[accountJID] = rows
    }

    // MARK: - Seen Devices

    func loadSeenDevices(for accountJID: String) async throws -> [OMEMOStoredSeenDevice] {
        loadSeenDevicesCalls += 1
        return Array(seenDevices[accountJID]?.values ?? [:].values)
    }

    func upsertSeenDevices(_ devices: [OMEMOStoredSeenDevice], for accountJID: String) async throws {
        var current = seenDevices[accountJID] ?? [:]
        for device in devices {
            current[device.deviceID] = device
        }
        seenDevices[accountJID] = current
    }

    func replaceSeenDevices(_ devices: [OMEMOStoredSeenDevice], for accountJID: String) async throws {
        var replacement: [UInt32: OMEMOStoredSeenDevice] = [:]
        replacement.reserveCapacity(devices.count)
        for device in devices {
            replacement[device.deviceID] = device
        }
        seenDevices[accountJID] = replacement
    }

    func purgeSeenDevices(for accountJID: String) async throws {
        seenDevices.removeValue(forKey: accountJID)
    }

    // MARK: - Session Deletion

    func deleteSession(accountJID: String, peerJID: String, peerDeviceID: UInt32) async throws {
        deleteSessionCalls += 1
        guard var rows = sessions[accountJID] else { return }
        rows.removeAll { $0.peerJID == peerJID && $0.peerDeviceID == peerDeviceID }
        sessions[accountJID] = rows
    }

    // MARK: - Test Probes

    func seedSeenDevices(_ devices: [OMEMOStoredSeenDevice], for accountJID: String) {
        var current = seenDevices[accountJID] ?? [:]
        for device in devices {
            current[device.deviceID] = device
        }
        seenDevices[accountJID] = current
    }
}
