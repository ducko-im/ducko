import Foundation

/// No-op OMEMO store used when no real store is provided (e.g., tests, CLI without persistence).
struct NoOpOMEMOStore: OMEMOStore {
    func loadIdentity(for _: String) async throws -> OMEMOStoredIdentity? {
        nil
    }

    func saveIdentity(_: OMEMOStoredIdentity) async throws {}
    func loadPreKeys(for _: String) async throws -> [OMEMOStoredPreKey] {
        []
    }

    func savePreKeys(_: [OMEMOStoredPreKey]) async throws {}
    func consumePreKey(id _: UInt32, accountJID _: String) async throws {}
    func loadSignedPreKey(for _: String) async throws -> OMEMOStoredSignedPreKey? {
        nil
    }

    func saveSignedPreKey(_: OMEMOStoredSignedPreKey) async throws {}
    func loadSessions(for _: String) async throws -> [OMEMOStoredSession] {
        []
    }

    func saveSession(_: OMEMOStoredSession) async throws {}
    func saveTrust(_: OMEMOTrust) async throws {}
    func insertTrustIfAbsent(_: OMEMOTrust) async throws {}
    func markTrust(_: OMEMOTrustLevel, accountJID _: String, peerJID _: String, deviceID _: UInt32, fallbackFingerprint _: String) async throws {}
    func fillTrustFingerprint(accountJID _: String, peerJID _: String, deviceID _: UInt32, fingerprint _: String) async throws -> String? {
        nil
    }

    func loadAllDevices(for _: String, accountJID _: String) async throws -> [OMEMOTrust] {
        []
    }

    func loadAllTrust(for _: String) async throws -> [OMEMOTrust] {
        []
    }

    func deleteTrust(accountJID _: String, peerJID _: String, deviceID _: UInt32) async throws {}

    func loadSeenDevices(for _: String) async throws -> [OMEMOStoredSeenDevice] {
        []
    }

    func upsertSeenDevices(_: [OMEMOStoredSeenDevice], for _: String) async throws {}
    func replaceSeenDevices(_: [OMEMOStoredSeenDevice], for _: String) async throws {}
    func purgeSeenDevices(for _: String) async throws {}
    func deleteSession(accountJID _: String, peerJID _: String, peerDeviceID _: UInt32) async throws {}
}
