import DuckoTestSupport
import Foundation
import SwiftData
import Testing
@testable import DuckoCore
@testable import DuckoData

/// Round-trip tests for the SwiftData persistence side of the new
/// seen-device classification cache and the orphan trust/session delete
/// methods added for the emergency-retract path. Lives in DuckoDataTests
/// because the `@Model` lives in DuckoData and DuckoCoreTests cannot
/// import DuckoData (module boundary rule).
struct SwiftDataOMEMOStoreTests {
    private func makeStore() throws -> SwiftDataOMEMOStore {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        return SwiftDataOMEMOStore(modelContainer: container)
    }

    /// Every writer that changes a stored row, each run against a store that cannot save: a second container opens the
    /// store read-only, so its saves fail and leave their changes pending.
    enum Writer: String, CaseIterable, Sendable {
        case identity, signedPreKey, preKeys, consumePreKey, session, deleteSession, trust, deleteTrust, seenDevices, replaceSeenDevices,
             purgeSeenDevices
    }

    @Test(arguments: Writer.allCases)
    func `A writer that cannot save leaves the stored rows as they were`(writer: Writer) async throws {
        try await withTemporaryDirectory { dir in
            let account = "alice@example.com"
            let writable = try SwiftDataOMEMOStore(modelContainer: ModelContainerFactory.makeContainer(at: dir))
            try await writable.saveIdentity(OMEMOStoredIdentity(accountJID: account, deviceID: 1, identityKeyData: Data([1]), registrationID: 0))
            try await writable.saveSignedPreKey(OMEMOStoredSignedPreKey(
                accountJID: account, keyID: 1, keyData: Data([1]), signature: Data([1]), timestamp: Date(timeIntervalSince1970: 0)
            ))
            try await writable.savePreKeys([OMEMOStoredPreKey(accountJID: account, keyID: 1, keyData: Data([1]), isUsed: false)])
            try await writable.saveSession(Self.session(account, data: 1))
            try await writable.saveTrust(Self.trust(account, level: .trusted))
            try await writable.upsertSeenDevices([Self.seenDevice(account, streak: 0)], for: account)
            let readOnly = try SwiftDataOMEMOStore(modelContainer: ModelContainer(
                for: ModelContainerFactory.schema,
                configurations: [ModelConfiguration(url: dir.appendingPathComponent("default.store"), allowsSave: false)]
            ))
            let before = try await Self.snapshot(of: readOnly, account: account)

            await #expect(throws: (any Error).self) {
                switch writer {
                case .identity:
                    try await readOnly.saveIdentity(OMEMOStoredIdentity(accountJID: account, deviceID: 2, identityKeyData: Data([2, 2]), registrationID: 0))
                case .signedPreKey:
                    try await readOnly.saveSignedPreKey(OMEMOStoredSignedPreKey(
                        accountJID: account, keyID: 2, keyData: Data([2, 2]), signature: Data([2, 2]), timestamp: Date()
                    ))
                case .preKeys:
                    try await readOnly.savePreKeys([OMEMOStoredPreKey(accountJID: account, keyID: 2, keyData: Data([2, 2]), isUsed: false)])
                case .consumePreKey: try await readOnly.consumePreKey(id: 1, accountJID: account)
                case .session: try await readOnly.saveSession(Self.session(account, data: 2))
                case .deleteSession: try await readOnly.deleteSession(accountJID: account, peerJID: "bob@example.com", peerDeviceID: 7)
                case .trust: try await readOnly.saveTrust(Self.trust(account, level: .untrusted))
                case .deleteTrust: try await readOnly.deleteTrust(accountJID: account, peerJID: "bob@example.com", deviceID: 7)
                case .seenDevices: try await readOnly.upsertSeenDevices([Self.seenDevice(account, streak: 3)], for: account)
                case .replaceSeenDevices: try await readOnly.replaceSeenDevices([], for: account)
                case .purgeSeenDevices: try await readOnly.purgeSeenDevices(for: account)
                }
            }

            #expect(try await Self.snapshot(of: readOnly, account: account) == before)
        }
    }

    private static func session(_ account: String, data: UInt8) -> OMEMOStoredSession {
        // A different length for each version, since a printed `Data` shows only its size.
        OMEMOStoredSession(
            accountJID: account, peerJID: "bob@example.com", peerDeviceID: 7,
            sessionData: Data(repeating: data, count: Int(data)), associatedData: Data(repeating: data, count: Int(data))
        )
    }

    private static func trust(_ account: String, level: OMEMOTrustLevel) -> OMEMOTrust {
        OMEMOTrust(accountJID: account, peerJID: "bob@example.com", deviceID: 7, fingerprint: "ab", trustLevel: level)
    }

    private static func seenDevice(_ account: String, streak: Int) -> OMEMOStoredSeenDevice {
        OMEMOStoredSeenDevice(accountJID: account, deviceID: 7, classification: "healthy", staleStreak: streak, hasObservedHealthy: true)
    }

    /// What the store shows of every row the writers touch.
    private static func snapshot(of store: SwiftDataOMEMOStore, account: String) async throws -> String {
        let identity = try await store.loadIdentity(for: account)
        let signedPreKey = try await store.loadSignedPreKey(for: account)
        let preKeys = try await store.loadPreKeys(for: account)
        let sessions = try await store.loadSessions(for: account)
        let trust = try await store.loadAllDevices(for: "bob@example.com", accountJID: account)
        let seen = try await store.loadSeenDevices(for: account)
        return "\(String(describing: identity)) \(String(describing: signedPreKey)) \(preKeys) \(sessions) \(trust) \(seen)"
    }

    @Test
    func `upsert and load round-trip preserves every field`() async throws {
        let store = try makeStore()
        let accountJID = "alice@example.com"
        let row = OMEMOStoredSeenDevice(
            accountJID: accountJID,
            deviceID: 4242,
            classification: "stale",
            staleStreak: 2,
            hasObservedHealthy: true
        )
        try await store.upsertSeenDevices([row], for: accountJID)

        let loaded = try await store.loadSeenDevices(for: accountJID)
        let read = try #require(loaded.first)
        #expect(read.deviceID == 4242)
        #expect(read.classification == "stale")
        #expect(read.staleStreak == 2)
        #expect(read.hasObservedHealthy == true)
    }

    @Test
    func `upsert updates existing row in place`() async throws {
        let store = try makeStore()
        let accountJID = "alice@example.com"
        let original = OMEMOStoredSeenDevice(
            accountJID: accountJID, deviceID: 1,
            classification: "healthy", staleStreak: 0, hasObservedHealthy: true
        )
        let updated = OMEMOStoredSeenDevice(
            accountJID: accountJID, deviceID: 1,
            classification: "stale", staleStreak: 1, hasObservedHealthy: true
        )
        try await store.upsertSeenDevices([original], for: accountJID)
        try await store.upsertSeenDevices([updated], for: accountJID)

        let loaded = try await store.loadSeenDevices(for: accountJID)
        #expect(loaded.count == 1)
        #expect(loaded.first?.classification == "stale")
        #expect(loaded.first?.staleStreak == 1)
    }

    @Test
    func `replace deletes rows absent from the new set`() async throws {
        let store = try makeStore()
        let accountJID = "alice@example.com"
        try await store.upsertSeenDevices(
            [
                OMEMOStoredSeenDevice(accountJID: accountJID, deviceID: 1, classification: "healthy", staleStreak: 0, hasObservedHealthy: true),
                OMEMOStoredSeenDevice(accountJID: accountJID, deviceID: 2, classification: "stale", staleStreak: 1, hasObservedHealthy: true)
            ],
            for: accountJID
        )

        try await store.replaceSeenDevices(
            [OMEMOStoredSeenDevice(accountJID: accountJID, deviceID: 9, classification: "healthy", staleStreak: 0, hasObservedHealthy: true)],
            for: accountJID
        )

        let loaded = try await store.loadSeenDevices(for: accountJID)
        #expect(loaded.count == 1)
        #expect(loaded.first?.deviceID == 9)
    }

    @Test
    func `purge clears one account leaves others intact`() async throws {
        let store = try makeStore()
        let acct1 = "alice@example.com"
        let acct2 = "bob@example.com"

        try await store.upsertSeenDevices(
            [OMEMOStoredSeenDevice(accountJID: acct1, deviceID: 1, classification: "healthy", staleStreak: 0, hasObservedHealthy: true)],
            for: acct1
        )
        try await store.upsertSeenDevices(
            [OMEMOStoredSeenDevice(accountJID: acct2, deviceID: 1, classification: "healthy", staleStreak: 0, hasObservedHealthy: true)],
            for: acct2
        )

        try await store.purgeSeenDevices(for: acct1)

        #expect(try await store.loadSeenDevices(for: acct1).isEmpty)
        #expect(try await store.loadSeenDevices(for: acct2).count == 1)
    }

    @Test
    func `consumePreKey leaves every row of the key a used tombstone without key data`() async throws {
        let store = try makeStore()
        let accountJID = "alice@example.com"
        let keyData = Data(repeating: 0xD4, count: 32)
        // `savePreKeys` appends, so the same id can be stored twice.
        try await store.savePreKeys([1, 1, 2].map {
            OMEMOStoredPreKey(accountJID: accountJID, keyID: $0, keyData: keyData, isUsed: false)
        })

        try await store.consumePreKey(id: 1, accountJID: accountJID)

        let reloaded = try await SwiftDataOMEMOStore(modelContainer: store.modelContainer).loadPreKeys(for: accountJID)
        let consumed = reloaded.filter { $0.keyID == 1 }
        #expect(consumed.count == 2)
        #expect(consumed.allSatisfy { $0.isUsed && $0.keyData.isEmpty })
        #expect(reloaded.filter { $0.keyID == 2 }.map(\.keyData) == [keyData])
        #expect(reloaded.filter { $0.keyID == 2 }.allSatisfy { !$0.isUsed })
    }

    @Test
    func `deleteTrust removes only the targeted row`() async throws {
        let store = try makeStore()
        let accountJID = "alice@example.com"
        let peerJID = "bob@example.com"

        try await store.saveTrust(OMEMOTrust(
            accountJID: accountJID, peerJID: peerJID,
            deviceID: 1, fingerprint: "f1", trustLevel: .trusted
        ))
        try await store.saveTrust(OMEMOTrust(
            accountJID: accountJID, peerJID: peerJID,
            deviceID: 2, fingerprint: "f2", trustLevel: .trusted
        ))

        try await store.deleteTrust(accountJID: accountJID, peerJID: peerJID, deviceID: 1)

        let remaining = try await store.loadAllDevices(for: peerJID, accountJID: accountJID)
        #expect(remaining.count == 1)
        #expect(remaining.first?.deviceID == 2)
    }

    @Test
    func `deleteSession removes only the targeted row`() async throws {
        let store = try makeStore()
        let accountJID = "alice@example.com"
        let peerJID = "bob@example.com"

        try await store.saveSession(OMEMOStoredSession(
            accountJID: accountJID, peerJID: peerJID, peerDeviceID: 1,
            sessionData: Data([0x01]), associatedData: Data([0x02])
        ))
        try await store.saveSession(OMEMOStoredSession(
            accountJID: accountJID, peerJID: peerJID, peerDeviceID: 2,
            sessionData: Data([0x03]), associatedData: Data([0x04])
        ))

        try await store.deleteSession(accountJID: accountJID, peerJID: peerJID, peerDeviceID: 1)

        let remaining = try await store.loadSessions(for: accountJID)
        #expect(remaining.count == 1)
        #expect(remaining.first?.peerDeviceID == 2)
    }
}
