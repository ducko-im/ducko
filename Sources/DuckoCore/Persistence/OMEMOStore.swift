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

// MARK: - Protocol

public protocol OMEMOStore: Sendable {
    // MARK: - Identity

    func loadIdentity(for accountJID: String) async throws -> OMEMOStoredIdentity?
    func saveIdentity(_ identity: OMEMOStoredIdentity) async throws

    // MARK: - Pre-Keys

    func loadPreKeys(for accountJID: String) async throws -> [OMEMOStoredPreKey]
    func savePreKeys(_ preKeys: [OMEMOStoredPreKey]) async throws
    func consumePreKey(id: UInt32, accountJID: String) async throws

    // MARK: - Signed Pre-Key

    func loadSignedPreKey(for accountJID: String) async throws -> OMEMOStoredSignedPreKey?
    func saveSignedPreKey(_ key: OMEMOStoredSignedPreKey) async throws

    // MARK: - Sessions

    func loadSessions(for accountJID: String) async throws -> [OMEMOStoredSession]
    func saveSession(_ session: OMEMOStoredSession) async throws

    // MARK: - Trust

    func saveTrust(_ trust: OMEMOTrust) async throws
    func loadTrust(accountJID: String, peerJID: String, deviceID: UInt32) async throws -> OMEMOTrust?
    func loadAllDevices(for peerJID: String, accountJID: String) async throws -> [OMEMOTrust]
    /// Deletes a specific trust row. Used by the emergency-retract orphan
    /// cleanup path; idempotent (no-op when the row is already absent).
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
