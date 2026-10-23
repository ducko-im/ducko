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
        case identity, signedPreKey, preKeys, consumePreKey, session, deleteSession, trust, insertTrust, markUntrusted, fillFingerprint, deleteTrust,
             seenDevices, replaceSeenDevices, purgeSeenDevices
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
                case .insertTrust:
                    try await readOnly.insertTrustIfAbsent(OMEMOTrust(
                        accountJID: account, peerJID: "bob@example.com", deviceID: 8, fingerprint: "cd", trustLevel: .undecided
                    ))
                case .markUntrusted:
                    try await readOnly.markTrust(.untrusted, accountJID: account, peerJID: "bob@example.com", deviceID: 7, fallbackFingerprint: "")
                case .fillFingerprint:
                    _ = try await readOnly.fillTrustFingerprint(accountJID: account, peerJID: "bob@example.com", deviceID: 8, fingerprint: "cd")
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

    @Test func `loadAllTrust returns every peer's rows of the account and none of another account`() async throws {
        let store = try makeStore()
        for (account, peer) in [("alice@example.com", "bob@example.com"), ("alice@example.com", "carol@example.com"), ("dave@example.com", "bob@example.com")] {
            try await store.saveTrust(OMEMOTrust(accountJID: account, peerJID: peer, deviceID: 1, fingerprint: "f1", trustLevel: .trusted))
        }

        let rows = try await store.loadAllTrust(for: "alice@example.com")

        #expect(Set(rows.map(\.peerJID)) == ["bob@example.com", "carol@example.com"])
        #expect(rows.allSatisfy { $0.accountJID == "alice@example.com" })
    }

    @Test func `insertTrustIfAbsent leaves an existing row as it is and creates a missing one`() async throws {
        let store = try makeStore()
        try await store.saveTrust(OMEMOTrust(accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: 1, fingerprint: "f1", trustLevel: .verified))

        for deviceID: UInt32 in [1, 2] {
            try await store.insertTrustIfAbsent(OMEMOTrust(
                accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: deviceID, fingerprint: "", trustLevel: .undecided
            ))
        }

        let rows = try await store.loadAllDevices(for: "bob@example.com", accountJID: "alice@example.com").sorted { $0.deviceID < $1.deviceID }
        #expect(rows.map(\.fingerprint) == ["f1", ""])
        #expect(rows.map(\.trustLevel) == [.verified, .undecided])
    }

    @Test(arguments: [OMEMOTrustLevel.untrusted, .trusted, .verified])
    func `markTrust sets the level, keeps a stored fingerprint, fills an empty one and creates a missing row with the fallback`(
        level: OMEMOTrustLevel
    ) async throws {
        let store = try makeStore()
        for (deviceID, fingerprint) in [(UInt32(1), "f1"), (2, "")] {
            try await store.saveTrust(OMEMOTrust(
                accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: deviceID, fingerprint: fingerprint, trustLevel: .trusted
            ))
        }

        for (deviceID, fallback) in [(UInt32(1), "other"), (2, "f2"), (3, "f3")] {
            try await store.markTrust(level, accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: deviceID, fallbackFingerprint: fallback)
        }

        let rows = try await store.loadAllDevices(for: "bob@example.com", accountJID: "alice@example.com").sorted { $0.deviceID < $1.deviceID }
        #expect(rows.map(\.fingerprint) == ["f1", "f2", "f3"])
        #expect(rows.map(\.trustLevel) == [level, level, level])
    }

    /// Duplicates come from two processes each creating the device's row, which one store's own writes cannot do.
    private static func insertDuplicates(_ rows: [(String, OMEMOTrustLevel)], into store: SwiftDataOMEMOStore) throws {
        let context = ModelContext(store.modelContainer)
        for (fingerprint, level) in rows {
            context.insert(OMEMOTrustRecord(
                id: UUID(), accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: 1, fingerprint: fingerprint,
                trustLevel: level.rawValue
            ))
        }
        try context.save()
    }

    @Test(arguments: [
        ([("", OMEMOTrustLevel.verified), ("f1", .trusted)], "f1", OMEMOTrustLevel.verified),
        ([("f1", .trusted), ("", .untrusted)], "f1", .untrusted),
        ([("f1", .verified), ("f2", .trusted)], "", .untrusted),
        ([("", .undecided), ("", .trusted)], "", .trusted),
        ([("f1", .trusted), ("f2", .trusted), ("f1", .trusted)], "", .untrusted)
    ])
    func `Duplicate rows of a device read as one, untrusted when any is or when their fingerprints differ`(
        rows: [(String, OMEMOTrustLevel)], fingerprint: String, level: OMEMOTrustLevel
    ) async throws {
        let store = try makeStore()
        try Self.insertDuplicates(rows, into: store)

        let devices = try await store.loadAllDevices(for: "bob@example.com", accountJID: "alice@example.com")
        let all = try await store.loadAllTrust(for: "alice@example.com")

        for read in [devices, all] {
            #expect(read.map(\.fingerprint) == [fingerprint])
            #expect(read.map(\.trustLevel) == [level])
        }
    }

    @Test func `A grant over duplicate rows that disagree is refused, and a distrust still applies`() async throws {
        let store = try makeStore()
        try Self.insertDuplicates([("f1", .undecided), ("f2", .undecided)], into: store)

        await #expect(throws: OMEMOStoreError.self) {
            try await store.markTrust(.trusted, accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: 1, fallbackFingerprint: "")
        }
        let afterGrant = try ModelContext(store.modelContainer).fetch(FetchDescriptor<OMEMOTrustRecord>()).map(\.trustLevel)
        try await store.markTrust(.untrusted, accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: 1, fallbackFingerprint: "")

        #expect(afterGrant == ["undecided", "undecided"])
        #expect(try ModelContext(store.modelContainer).fetch(FetchDescriptor<OMEMOTrustRecord>()).map(\.trustLevel) == ["untrusted", "untrusted"])
    }

    /// The empty row is filled with the fallback, so a fallback other than the stored fingerprint would leave the rows
    /// disagreeing.
    @Test(arguments: [
        ("", false, ["trusted ", "trusted f1"]),
        ("f1", false, ["trusted f1", "trusted f1"]),
        ("f2", true, ["undecided ", "undecided f1"])
    ])
    func `A grant over duplicate rows fills the empty one, refused when that would make them disagree`(
        fallback: String, isRefused: Bool, rows: [String]
    ) async throws {
        let store = try makeStore()
        try Self.insertDuplicates([("f1", .undecided), ("", .undecided)], into: store)

        var refused = false
        do {
            try await store.markTrust(.trusted, accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: 1, fallbackFingerprint: fallback)
        } catch OMEMOStoreError.conflictingFingerprints {
            refused = true
        }

        #expect(refused == isRefused)
        #expect(try ModelContext(store.modelContainer).fetch(FetchDescriptor<OMEMOTrustRecord>()).map { "\($0.trustLevel) \($0.fingerprint)" }.sorted() == rows)
    }

    @Test func `saveTrust changes every duplicate row of the device`() async throws {
        let store = try makeStore()
        try Self.insertDuplicates([("f1", .untrusted), ("", .untrusted)], into: store)

        try await store.saveTrust(OMEMOTrust(accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: 1, fingerprint: "f1", trustLevel: .trusted))

        let rows = try ModelContext(store.modelContainer).fetch(FetchDescriptor<OMEMOTrustRecord>()).map { "\($0.trustLevel) \($0.fingerprint)" }
        #expect(rows == ["trusted f1", "trusted f1"])
    }

    @Test func `A trust write changes every duplicate row of the device`() async throws {
        let store = try makeStore()
        try Self.insertDuplicates([("f1", .trusted), ("", .verified)], into: store)

        try await store.markTrust(.untrusted, accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: 1, fallbackFingerprint: "f1")
        let untrusted = try ModelContext(store.modelContainer).fetch(FetchDescriptor<OMEMOTrustRecord>()).map { "\($0.trustLevel) \($0.fingerprint)" }
        try await store.deleteTrust(accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: 1)

        #expect(untrusted == ["untrusted f1", "untrusted f1"])
        #expect(try ModelContext(store.modelContainer).fetch(FetchDescriptor<OMEMOTrustRecord>()).isEmpty)
    }

    @Test func `fillTrustFingerprint fills an empty fingerprint keeping the level, creates a missing row, and reports a differing one`() async throws {
        let store = try makeStore()
        try await store.saveTrust(OMEMOTrust(accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: 1, fingerprint: "", trustLevel: .untrusted))
        try await store.saveTrust(OMEMOTrust(accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: 3, fingerprint: "f3", trustLevel: .trusted))

        let filled = try await store.fillTrustFingerprint(accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: 1, fingerprint: "f1")
        let created = try await store.fillTrustFingerprint(accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: 2, fingerprint: "f2")
        let differing = try await store.fillTrustFingerprint(accountJID: "alice@example.com", peerJID: "bob@example.com", deviceID: 3, fingerprint: "new")

        #expect(filled == nil)
        #expect(created == nil)
        #expect(differing == "f3")
        let rows = try await store.loadAllDevices(for: "bob@example.com", accountJID: "alice@example.com").sorted { $0.deviceID < $1.deviceID }
        #expect(rows.map(\.fingerprint) == ["f1", "f2", "f3"])
        #expect(rows.map(\.trustLevel) == [.untrusted, .undecided, .trusted])
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
