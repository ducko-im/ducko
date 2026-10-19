import DuckoCore
import Foundation
import SwiftData

@ModelActor
public actor SwiftDataOMEMOStore: OMEMOStore {
    // MARK: - Identity

    public func loadIdentity(for accountJID: String) throws -> OMEMOStoredIdentity? {
        var descriptor = FetchDescriptor<OMEMOIdentityRecord>(
            predicate: #Predicate { $0.accountJID == accountJID }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        return OMEMOStoredIdentity(
            accountJID: record.accountJID,
            deviceID: UInt32(record.deviceID),
            identityKeyData: record.identityKeyData,
            registrationID: UInt32(record.registrationID)
        )
    }

    public func saveIdentity(_ identity: OMEMOStoredIdentity) throws {
        try write {
            let accountJID = identity.accountJID
            var descriptor = FetchDescriptor<OMEMOIdentityRecord>(
                predicate: #Predicate { $0.accountJID == accountJID }
            )
            descriptor.fetchLimit = 1

            if let existing = try modelContext.fetch(descriptor).first {
                existing.deviceID = Int64(identity.deviceID)
                existing.identityKeyData = identity.identityKeyData
                existing.registrationID = Int64(identity.registrationID)
            } else {
                let record = OMEMOIdentityRecord(
                    id: UUID(),
                    accountJID: identity.accountJID,
                    deviceID: Int64(identity.deviceID),
                    identityKeyData: identity.identityKeyData,
                    registrationID: Int64(identity.registrationID)
                )
                modelContext.insert(record)
            }
        }
    }

    // MARK: - Pre-Keys

    public func loadPreKeys(for accountJID: String) throws -> [OMEMOStoredPreKey] {
        let descriptor = FetchDescriptor<OMEMOPreKeyRecord>(
            predicate: #Predicate { $0.accountJID == accountJID }
        )
        return try modelContext.fetch(descriptor).map {
            OMEMOStoredPreKey(
                accountJID: $0.accountJID,
                keyID: UInt32($0.keyID),
                keyData: $0.keyData,
                isUsed: $0.isUsed
            )
        }
    }

    public func savePreKeys(_ preKeys: [OMEMOStoredPreKey]) throws {
        try write {
            for preKey in preKeys {
                let record = OMEMOPreKeyRecord(
                    id: UUID(),
                    accountJID: preKey.accountJID,
                    keyID: Int64(preKey.keyID),
                    keyData: preKey.keyData,
                    isUsed: preKey.isUsed
                )
                modelContext.insert(record)
            }
        }
    }

    public func consumePreKey(id: UInt32, accountJID: String) throws {
        try write {
            let keyID = Int64(id)
            let descriptor = FetchDescriptor<OMEMOPreKeyRecord>(
                predicate: #Predicate { $0.accountJID == accountJID && $0.keyID == keyID }
            )
            let records = try modelContext.fetch(descriptor)
            guard !records.isEmpty else { return }
            for record in records {
                record.isUsed = true
                record.keyData = Data()
            }
        }
    }

    /// Runs a writer's changes and saves them. Changes left pending by anything that throws, the save included, would
    /// still show to later fetches and ride along with the next save, so they are rolled back.
    private func write(_ changes: () throws -> Void) throws {
        do {
            try changes()
            if modelContext.hasChanges {
                try modelContext.save()
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    // MARK: - Signed Pre-Key

    public func loadSignedPreKey(for accountJID: String) throws -> OMEMOStoredSignedPreKey? {
        var descriptor = FetchDescriptor<OMEMOSignedPreKeyRecord>(
            predicate: #Predicate { $0.accountJID == accountJID }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        return OMEMOStoredSignedPreKey(
            accountJID: record.accountJID,
            keyID: UInt32(record.keyID),
            keyData: record.keyData,
            signature: record.signature,
            timestamp: record.timestamp
        )
    }

    public func saveSignedPreKey(_ key: OMEMOStoredSignedPreKey) throws {
        try write {
            let accountJID = key.accountJID
            var descriptor = FetchDescriptor<OMEMOSignedPreKeyRecord>(
                predicate: #Predicate { $0.accountJID == accountJID }
            )
            descriptor.fetchLimit = 1

            if let existing = try modelContext.fetch(descriptor).first {
                existing.keyID = Int64(key.keyID)
                existing.keyData = key.keyData
                existing.signature = key.signature
                existing.timestamp = key.timestamp
            } else {
                let record = OMEMOSignedPreKeyRecord(
                    id: UUID(),
                    accountJID: key.accountJID,
                    keyID: Int64(key.keyID),
                    keyData: key.keyData,
                    signature: key.signature,
                    timestamp: key.timestamp
                )
                modelContext.insert(record)
            }
        }
    }

    // MARK: - Sessions

    public func loadSessions(for accountJID: String) throws -> [OMEMOStoredSession] {
        let descriptor = FetchDescriptor<OMEMOSessionRecord>(
            predicate: #Predicate { $0.accountJID == accountJID }
        )
        return try modelContext.fetch(descriptor).map {
            OMEMOStoredSession(
                accountJID: $0.accountJID,
                peerJID: $0.peerJID,
                peerDeviceID: UInt32($0.peerDeviceID),
                sessionData: $0.sessionData,
                associatedData: $0.associatedData
            )
        }
    }

    public func saveSession(_ session: OMEMOStoredSession) throws {
        try write {
            let accountJID = session.accountJID
            let peerJID = session.peerJID
            let peerDeviceID = Int64(session.peerDeviceID)
            var descriptor = FetchDescriptor<OMEMOSessionRecord>(
                predicate: #Predicate {
                    $0.accountJID == accountJID && $0.peerJID == peerJID && $0.peerDeviceID == peerDeviceID
                }
            )
            descriptor.fetchLimit = 1

            if let existing = try modelContext.fetch(descriptor).first {
                existing.sessionData = session.sessionData
                existing.associatedData = session.associatedData
                existing.updatedAt = Date()
            } else {
                let record = OMEMOSessionRecord(
                    id: UUID(),
                    accountJID: session.accountJID,
                    peerJID: session.peerJID,
                    peerDeviceID: peerDeviceID,
                    sessionData: session.sessionData,
                    associatedData: session.associatedData
                )
                modelContext.insert(record)
            }
        }
    }

    // MARK: - Trust

    public func saveTrust(_ trust: OMEMOTrust) throws {
        try write {
            let accountJID = trust.accountJID
            let peerJID = trust.peerJID
            let deviceID = Int64(trust.deviceID)
            var descriptor = FetchDescriptor<OMEMOTrustRecord>(
                predicate: #Predicate {
                    $0.accountJID == accountJID && $0.peerJID == peerJID && $0.deviceID == deviceID
                }
            )
            descriptor.fetchLimit = 1

            if let existing = try modelContext.fetch(descriptor).first {
                existing.fingerprint = trust.fingerprint
                existing.trustLevel = trust.trustLevel.rawValue
            } else {
                let record = OMEMOTrustRecord(
                    id: UUID(),
                    accountJID: trust.accountJID,
                    peerJID: trust.peerJID,
                    deviceID: deviceID,
                    fingerprint: trust.fingerprint,
                    trustLevel: trust.trustLevel.rawValue
                )
                modelContext.insert(record)
            }
        }
    }

    public func loadTrust(accountJID: String, peerJID: String, deviceID: UInt32) throws -> OMEMOTrust? {
        let deviceIDInt = Int64(deviceID)
        var descriptor = FetchDescriptor<OMEMOTrustRecord>(
            predicate: #Predicate {
                $0.accountJID == accountJID && $0.peerJID == peerJID && $0.deviceID == deviceIDInt
            }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return nil }
        return OMEMOTrust(
            accountJID: record.accountJID,
            peerJID: record.peerJID,
            deviceID: UInt32(record.deviceID),
            fingerprint: record.fingerprint,
            trustLevel: OMEMOTrustLevel(rawValue: record.trustLevel) ?? .undecided
        )
    }

    public func loadAllDevices(for peerJID: String, accountJID: String) throws -> [OMEMOTrust] {
        let descriptor = FetchDescriptor<OMEMOTrustRecord>(
            predicate: #Predicate { $0.accountJID == accountJID && $0.peerJID == peerJID }
        )
        return try modelContext.fetch(descriptor).map {
            OMEMOTrust(
                accountJID: $0.accountJID,
                peerJID: $0.peerJID,
                deviceID: UInt32($0.deviceID),
                fingerprint: $0.fingerprint,
                trustLevel: OMEMOTrustLevel(rawValue: $0.trustLevel) ?? .undecided
            )
        }
    }

    public func deleteTrust(accountJID: String, peerJID: String, deviceID: UInt32) throws {
        try write {
            let deviceIDInt = Int64(deviceID)
            var descriptor = FetchDescriptor<OMEMOTrustRecord>(
                predicate: #Predicate {
                    $0.accountJID == accountJID && $0.peerJID == peerJID && $0.deviceID == deviceIDInt
                }
            )
            descriptor.fetchLimit = 1
            if let record = try modelContext.fetch(descriptor).first {
                modelContext.delete(record)
            }
        }
    }

    // MARK: - Seen Devices

    public func loadSeenDevices(for accountJID: String) throws -> [OMEMOStoredSeenDevice] {
        let descriptor = FetchDescriptor<OMEMOSeenDeviceRecord>(
            predicate: #Predicate { $0.accountJID == accountJID }
        )
        return try modelContext.fetch(descriptor).map {
            OMEMOStoredSeenDevice(
                accountJID: $0.accountJID,
                deviceID: UInt32($0.deviceID),
                classification: $0.classification,
                staleStreak: $0.staleStreak,
                hasObservedHealthy: $0.hasObservedHealthy
            )
        }
    }

    public func upsertSeenDevices(_ devices: [OMEMOStoredSeenDevice], for accountJID: String) throws {
        try write {
            try upsertSeenDeviceRows(devices, for: accountJID)
        }
    }

    public func replaceSeenDevices(_ devices: [OMEMOStoredSeenDevice], for accountJID: String) throws {
        try write {
            let keepIDs = Set(devices.map { Int64($0.deviceID) })
            let descriptor = FetchDescriptor<OMEMOSeenDeviceRecord>(
                predicate: #Predicate { $0.accountJID == accountJID }
            )
            for existing in try modelContext.fetch(descriptor) where !keepIDs.contains(existing.deviceID) {
                modelContext.delete(existing)
            }
            // "replace = delete absent + upsert present" — reuse the upsert path so row state is shared.
            try upsertSeenDeviceRows(devices, for: accountJID)
        }
    }

    private func upsertSeenDeviceRows(_ devices: [OMEMOStoredSeenDevice], for accountJID: String) throws {
        for device in devices {
            let deviceIDInt = Int64(device.deviceID)
            var descriptor = FetchDescriptor<OMEMOSeenDeviceRecord>(
                predicate: #Predicate {
                    $0.accountJID == accountJID && $0.deviceID == deviceIDInt
                }
            )
            descriptor.fetchLimit = 1
            if let existing = try modelContext.fetch(descriptor).first {
                existing.classification = device.classification
                existing.staleStreak = device.staleStreak
                existing.hasObservedHealthy = device.hasObservedHealthy
            } else {
                let record = OMEMOSeenDeviceRecord(
                    id: UUID(),
                    accountJID: device.accountJID,
                    deviceID: deviceIDInt,
                    classification: device.classification,
                    staleStreak: device.staleStreak,
                    hasObservedHealthy: device.hasObservedHealthy
                )
                modelContext.insert(record)
            }
        }
    }

    public func purgeSeenDevices(for accountJID: String) throws {
        try write {
            let descriptor = FetchDescriptor<OMEMOSeenDeviceRecord>(
                predicate: #Predicate { $0.accountJID == accountJID }
            )
            for record in try modelContext.fetch(descriptor) {
                modelContext.delete(record)
            }
        }
    }

    // MARK: - Session Deletion

    public func deleteSession(accountJID: String, peerJID: String, peerDeviceID: UInt32) throws {
        try write {
            let peerDeviceIDInt = Int64(peerDeviceID)
            var descriptor = FetchDescriptor<OMEMOSessionRecord>(
                predicate: #Predicate {
                    $0.accountJID == accountJID && $0.peerJID == peerJID && $0.peerDeviceID == peerDeviceIDInt
                }
            )
            descriptor.fetchLimit = 1
            if let record = try modelContext.fetch(descriptor).first {
                modelContext.delete(record)
            }
        }
    }
}
