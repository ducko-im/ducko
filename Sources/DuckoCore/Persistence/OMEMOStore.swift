import Foundation

// MARK: - Domain Types

public struct OMEMOStoredIdentity: Sendable {
    public let accountJID: String
    public let deviceID: UInt32
    public let identityKeyData: Data
    public let registrationID: UInt32

    public init(accountJID: String, deviceID: UInt32, identityKeyData: Data, registrationID: UInt32) {
        self.accountJID = accountJID
        self.deviceID = deviceID
        self.identityKeyData = identityKeyData
        self.registrationID = registrationID
    }
}

public struct OMEMOStoredPreKey: Sendable {
    public let accountJID: String
    public let keyID: UInt32
    public let keyData: Data
    public let isUsed: Bool

    public init(accountJID: String, keyID: UInt32, keyData: Data, isUsed: Bool) {
        self.accountJID = accountJID
        self.keyID = keyID
        self.keyData = keyData
        self.isUsed = isUsed
    }
}

public struct OMEMOStoredSignedPreKey: Sendable {
    public let accountJID: String
    public let keyID: UInt32
    public let keyData: Data
    public let signature: Data
    public let timestamp: Date

    public init(accountJID: String, keyID: UInt32, keyData: Data, signature: Data, timestamp: Date) {
        self.accountJID = accountJID
        self.keyID = keyID
        self.keyData = keyData
        self.signature = signature
        self.timestamp = timestamp
    }
}

public struct OMEMOStoredSession: Sendable {
    public let accountJID: String
    public let peerJID: String
    public let peerDeviceID: UInt32
    public let sessionData: Data
    public let associatedData: Data

    public init(accountJID: String, peerJID: String, peerDeviceID: UInt32, sessionData: Data, associatedData: Data) {
        self.accountJID = accountJID
        self.peerJID = peerJID
        self.peerDeviceID = peerDeviceID
        self.sessionData = sessionData
        self.associatedData = associatedData
    }
}

public struct OMEMOTrust: Sendable {
    public let accountJID: String
    public let peerJID: String
    public let deviceID: UInt32
    public let fingerprint: String
    public let trustLevel: OMEMOTrustLevel

    public init(accountJID: String, peerJID: String, deviceID: UInt32, fingerprint: String, trustLevel: OMEMOTrustLevel) {
        self.accountJID = accountJID
        self.peerJID = peerJID
        self.deviceID = deviceID
        self.fingerprint = fingerprint
        self.trustLevel = trustLevel
    }
}

public struct OMEMOStoredSeenDevice: Sendable {
    public let accountJID: String
    public let deviceID: UInt32
    /// `BundleClassification` raw value (`"stale"` / `"healthy"` /
    /// `"transient"`). Stored as the raw string so DuckoCore does not need
    /// to import DuckoXMPP just to model the persistence row.
    public let classification: String
    public let staleStreak: Int
    public let hasObservedHealthy: Bool

    public init(
        accountJID: String,
        deviceID: UInt32,
        classification: String,
        staleStreak: Int,
        hasObservedHealthy: Bool
    ) {
        self.accountJID = accountJID
        self.deviceID = deviceID
        self.classification = classification
        self.staleStreak = staleStreak
        self.hasObservedHealthy = hasObservedHealthy
    }
}

public enum OMEMOTrustLevel: String, Sendable, Codable {
    case undecided
    case trusted
    case untrusted
    case verified

    /// Whether this trust level allows encrypting messages to the device.
    public var isTrustedForEncryption: Bool {
        self == .trusted || self == .verified
    }

    /// The level a device is treated as: an undecided one counts as trusted while Trust On First Use is on.
    public func effective(trustOnFirstUse: Bool) -> OMEMOTrustLevel {
        self == .undecided && trustOnFirstUse ? .trusted : self
    }

    /// Whether this trust level allows encrypting, respecting the TOFU preference.
    public func isTrustedForEncryption(trustOnFirstUse: Bool) -> Bool {
        effective(trustOnFirstUse: trustOnFirstUse).isTrustedForEncryption
    }
}

/// Why a store refused a trust write.
public enum OMEMOStoreError: Error {
    /// The device's duplicate rows would name different fingerprints, so a grant would certify a key nobody compared.
    case conflictingFingerprints
}

public extension OMEMOTrust {
    /// Whether one device's rows name different keys. An empty fingerprint names no key.
    static func fingerprintsConflict(_ fingerprints: some Sequence<String>) -> Bool {
        Set(fingerprints.filter { !$0.isEmpty }).count > 1
    }
}

public extension [OMEMOTrust] {
    /// One row per device. The app and the CLI each write the store through their own container, so two can each create
    /// a row for one device. Duplicates combine so that no decision weakens: untrusted when any row is, or when rows
    /// name different fingerprints, else the strongest grant with the one fingerprint any of them holds.
    func collapsingDuplicateDevices() -> [OMEMOTrust] {
        var order: [OMEMOTrust.Device] = []
        var rowsByDevice: [OMEMOTrust.Device: [OMEMOTrust]] = [:]
        for row in self {
            if rowsByDevice[row.device] == nil {
                order.append(row.device)
            }
            rowsByDevice[row.device, default: []].append(row)
        }
        return order.compactMap { rowsByDevice[$0].map(OMEMOTrust.init(collapsing:)) }
    }
}

private extension OMEMOTrust {
    struct Device: Hashable {
        let accountJID: String
        let peerJID: String
        let deviceID: UInt32

        /// Spelled out so Periphery sees the fields read; it misses reads by the synthesized conformance.
        func hash(into hasher: inout Hasher) {
            hasher.combine(accountJID)
            hasher.combine(peerJID)
            hasher.combine(deviceID)
        }
    }

    var device: Device {
        Device(accountJID: accountJID, peerJID: peerJID, deviceID: deviceID)
    }

    /// `rows` are one device's, at least one.
    init(collapsing rows: [OMEMOTrust]) {
        let isConflicting = OMEMOTrust.fingerprintsConflict(rows.map(\.fingerprint))
        let level: OMEMOTrustLevel = if isConflicting || rows.contains(where: { $0.trustLevel == .untrusted }) {
            .untrusted
        } else {
            rows.map(\.trustLevel).max { $0.grantRank < $1.grantRank } ?? .undecided
        }
        self.init(
            accountJID: rows[0].accountJID, peerJID: rows[0].peerJID, deviceID: rows[0].deviceID,
            fingerprint: isConflicting ? "" : rows.first { !$0.fingerprint.isEmpty }?.fingerprint ?? "", trustLevel: level
        )
    }
}

private extension OMEMOTrustLevel {
    var grantRank: Int {
        switch self {
        case .untrusted, .undecided: 0
        case .trusted: 1
        case .verified: 2
        }
    }
}

// MARK: - Protocol

public protocol OMEMOStore: Sendable {
    // MARK: - Identity

    func loadIdentity(for accountJID: String) async throws -> OMEMOStoredIdentity?
    func saveIdentity(_ identity: OMEMOStoredIdentity) async throws

    // MARK: - Pre-Keys

    func loadPreKeys(for accountJID: String) async throws -> [OMEMOStoredPreKey]
    func savePreKeys(_ preKeys: [OMEMOStoredPreKey]) async throws
    /// Marks every stored row of the pre-key used and erases its private key data (XEP-0384). The rows stay, so new
    /// pre-keys are numbered past them.
    func consumePreKey(id: UInt32, accountJID: String) async throws

    // MARK: - Signed Pre-Key

    func loadSignedPreKey(for accountJID: String) async throws -> OMEMOStoredSignedPreKey?
    func saveSignedPreKey(_ key: OMEMOStoredSignedPreKey) async throws

    // MARK: - Sessions

    func loadSessions(for accountJID: String) async throws -> [OMEMOStoredSession]
    func saveSession(_ session: OMEMOStoredSession) async throws

    // MARK: - Trust

    func saveTrust(_ trust: OMEMOTrust) async throws
    func insertTrustIfAbsent(_ trust: OMEMOTrust) async throws
    /// Sets the device's trust level, keeping the fingerprint a row holds. An empty or missing fingerprint becomes
    /// `fallbackFingerprint`, and a missing row is created. Any level but untrusted throws `conflictingFingerprints`,
    /// writing nothing, when the device's rows would then hold different fingerprints.
    func markTrust(_ level: OMEMOTrustLevel, accountJID: String, peerJID: String, deviceID: UInt32, fallbackFingerprint: String) async throws
    /// Fills the fingerprint of a row that has none, keeping its trust level, or creates an undecided row. Returns the
    /// stored fingerprint when it differs from `fingerprint`, which stays as it was.
    func fillTrustFingerprint(accountJID: String, peerJID: String, deviceID: UInt32, fingerprint: String) async throws -> String?
    /// Collapses duplicate rows of a device (`collapsingDuplicateDevices`).
    func loadAllDevices(for peerJID: String, accountJID: String) async throws -> [OMEMOTrust]
    /// Every trust row of the account, whichever peer it names, with duplicate rows of a device collapsed.
    func loadAllTrust(for accountJID: String) async throws -> [OMEMOTrust]
    /// Deletes every trust row of the device. Used by the emergency-retract orphan
    /// cleanup path; idempotent (no-op when none exists).
    func deleteTrust(accountJID: String, peerJID: String, deviceID: UInt32) async throws

    // MARK: - Seen Devices

    func loadSeenDevices(for accountJID: String) async throws -> [OMEMOStoredSeenDevice]

    /// Per-row upsert by `(accountJID, deviceID)`. Rows not in `devices` are
    /// left untouched — used for delta merges during normal prune cycles.
    func upsertSeenDevices(_ devices: [OMEMOStoredSeenDevice], for accountJID: String) async throws

    /// Replaces every row for `accountJID` with `devices`: deletes any
    /// account-scoped row whose deviceID is not in the new set. Used by the
    /// shrink-detect path (`clearSeenDevicesAbsent`) and the emergency-retract
    /// baseline.
    func replaceSeenDevices(_ devices: [OMEMOStoredSeenDevice], for accountJID: String) async throws

    /// Deletes every seen-device row for `accountJID`. Called from
    /// `OMEMOService.purgeSeenDeviceClassifications` during account deletion.
    func purgeSeenDevices(for accountJID: String) async throws

    // MARK: - Session Deletion

    /// Deletes a specific session row. Used by the emergency-retract orphan
    /// cleanup path; idempotent.
    func deleteSession(accountJID: String, peerJID: String, peerDeviceID: UInt32) async throws
}
