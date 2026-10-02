import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let testAccountJID = BareJID(localPart: "alice", domainPart: "example.com")!

@MainActor
private func makeOMEMOService(store: MockOMEMOStore) -> OMEMOService {
    OMEMOService(omemoStore: store)
}

private func makeIdentityData(deviceID: UInt32) -> OMEMOModule.OMEMOIdentityData {
    OMEMOModule.OMEMOIdentityData(
        deviceID: deviceID,
        identityKeyRaw: Array(repeating: 0xA1, count: 32),
        signedPreKeyID: 7,
        signedPreKeyRaw: Array(repeating: 0xB2, count: 32),
        signedPreKeySignature: Array(repeating: 0xC3, count: 64),
        preKeys: [
            OMEMOModule.OMEMOIdentityData.PreKeyData(
                keyID: 1, keyRaw: Array(repeating: 0xD4, count: 32)
            )
        ]
    )
}

private struct StubOMEMOIdentityProvider: OMEMOIdentityProviding {
    let identity: OMEMOModule.OMEMOIdentityData?
    let consumed: Set<UInt32>

    var ownIdentityData: OMEMOModule.OMEMOIdentityData? {
        identity
    }

    func consumedPreKeyIDs() -> Set<UInt32> {
        consumed
    }
}

// MARK: - Tests

enum OMEMOServiceTests {
    struct HandleConnectedFirstTimePersistence {
        @Test
        @MainActor
        func `returns early when identity already persisted`() async {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description
            let identityData = makeIdentityData(deviceID: 4242)
            await store.seedFromIdentityData(identityData, accountJID: accountJID)

            let service = makeOMEMOService(store: store)
            let stub = StubOMEMOIdentityProvider(identity: identityData, consumed: [])

            await service.handleConnectedFirstTimePersistence(
                provider: stub,
                accountJID: accountJID,
                pollTimeout: .milliseconds(100)
            )

            #expect(await store.saveIdentityCalls == 0)
            #expect(await store.savePreKeysCalls == 0)
            #expect(await store.saveSignedPreKeyCalls == 0)
        }

        @Test
        @MainActor
        func `persists identity from provider when store empty`() async throws {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description
            let identityData = makeIdentityData(deviceID: 4242)
            let stub = StubOMEMOIdentityProvider(identity: identityData, consumed: [])
            let service = makeOMEMOService(store: store)

            await service.handleConnectedFirstTimePersistence(
                provider: stub,
                accountJID: accountJID,
                pollTimeout: .seconds(2)
            )

            #expect(await store.saveIdentityCalls == 1)
            #expect(await store.savePreKeysCalls == 1)
            #expect(await store.saveSignedPreKeyCalls == 1)

            let storedIdentity = try #require(await store.loadIdentity(for: accountJID))
            #expect(storedIdentity.deviceID == 4242)
            #expect(storedIdentity.identityKeyData == Data(identityData.identityKeyRaw))

            let storedPreKeys = try await store.loadPreKeys(for: accountJID)
            #expect(storedPreKeys.count == 1)
            #expect(storedPreKeys[0].keyID == 1)
            #expect(storedPreKeys[0].keyData == Data(identityData.preKeys[0].keyRaw))

            let storedSPK = try #require(await store.loadSignedPreKey(for: accountJID))
            #expect(storedSPK.keyID == identityData.signedPreKeyID)
            #expect(storedSPK.keyData == Data(identityData.signedPreKeyRaw))
            #expect(storedSPK.signature == Data(identityData.signedPreKeySignature))
        }

        @Test
        @MainActor
        func `marks consumed pre-keys as used`() async throws {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description

            // Pre-seed identity (so the persistence branch early-returns) plus
            // three fresh pre-keys to consume against.
            await store.seedFromIdentityData(makeIdentityData(deviceID: 4242), accountJID: accountJID)
            await store.seedPreKeys([2, 3].map {
                OMEMOStoredPreKey(
                    accountJID: accountJID, keyID: $0,
                    keyData: Data(Array(repeating: UInt8($0), count: 32)),
                    isUsed: false
                )
            })

            let service = makeOMEMOService(store: store)
            let stub = StubOMEMOIdentityProvider(
                identity: makeIdentityData(deviceID: 4242),
                consumed: [1, 3]
            )

            await service.handleConnectedFirstTimePersistence(
                provider: stub,
                accountJID: accountJID,
                pollTimeout: .milliseconds(100)
            )

            let preKeys = try await store.loadPreKeys(for: accountJID)
            let used = Set(preKeys.filter(\.isUsed).map(\.keyID))
            let unused = Set(preKeys.filter { !$0.isUsed }.map(\.keyID))
            #expect(used == [1, 3])
            #expect(unused == [2])
        }

        @Test
        @MainActor
        func `skips persistence when identity never readies`() async {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description
            let stub = StubOMEMOIdentityProvider(identity: nil, consumed: [])
            let service = makeOMEMOService(store: store)

            let start = ContinuousClock.now
            await service.handleConnectedFirstTimePersistence(
                provider: stub,
                accountJID: accountJID,
                pollTimeout: .milliseconds(100)
            )
            let elapsed = start.duration(to: ContinuousClock.now)

            #expect(await store.saveIdentityCalls == 0)
            #expect(await store.savePreKeysCalls == 0)
            #expect(await store.saveSignedPreKeyCalls == 0)
            // Polling exhausts at ~100 ms; allow generous slack for CI variance.
            #expect(elapsed < .milliseconds(500))
        }
    }

    struct FailedDecrypt {
        @Test
        @MainActor
        func `A message that could not be decrypted is kept as such, with no text of its own`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
            let service = makeOMEMOService(store: MockOMEMOStore())
            service.setChatService(chatService)
            let accountID = UUID()
            let peer = try #require(BareJID(localPart: "peer", domainPart: "example.com"))

            await service.handleEvent(
                .omemoEncryptedMessageReceived(from: .bare(peer), decryptedBody: nil, senderDeviceID: 0, stanzaID: "omemo-bad"),
                accountID: accountID
            )

            // Stored as text, the failure would be searched, quoted and copied as if the sender had written it.
            let message = try #require(await transcripts.messages.last)
            #expect(message.isUndecryptable)
            #expect(message.body.isEmpty)
            #expect(message.previewText == ChatMessage.undecryptableText)
        }
    }

    /// Locks the production `OMEMOService` conformance to
    /// `SeenDeviceClassificationProviding` — the per-device classification
    /// cache must persist across reads, stay isolated per account, lazy-load
    /// from the store on first read, and coalesce concurrent first-loads
    /// onto a single store call. The pruning unit tests in DuckoXMPP use a
    /// stub provider; these tests prove the real production wiring keeps
    /// its data correctly.
    struct SeenDeviceClassificationProvider {
        @Test
        @MainActor
        func `empty by default; merge round-trips per account`() async {
            let store = MockOMEMOStore()
            let service = makeOMEMOService(store: store)
            let acctA = UUID().uuidString
            let accountJID = testAccountJID.description
            await service.installAccountJIDForTesting(accountJID, accountID: acctA)

            let empty = await service.loadSeenDevices(accountID: acctA)
            #expect(empty.isEmpty)

            let record = SeenDeviceRecord(
                deviceID: 42, lastClassification: .healthy,
                staleStreak: 0, hasObservedHealthy: true
            )
            await service.mergeSeenDevices([42: record], accountID: acctA)
            let read = await service.loadSeenDevices(accountID: acctA)
            #expect(read[42] == record)
        }

        @Test
        @MainActor
        func `lazy-loads from store on first read; second read is in-memory`() async {
            let store = MockOMEMOStore()
            let acctA = UUID().uuidString
            let accountJID = testAccountJID.description
            await store.seedSeenDevices(
                [OMEMOStoredSeenDevice(
                    accountJID: accountJID, deviceID: 7,
                    classification: BundleClassification.healthy.rawValue,
                    staleStreak: 0, hasObservedHealthy: true
                )],
                for: accountJID
            )

            let service = makeOMEMOService(store: store)
            await service.installAccountJIDForTesting(accountJID, accountID: acctA)

            _ = await service.loadSeenDevices(accountID: acctA)
            #expect(await store.loadSeenDevicesCalls == 1)
            _ = await service.loadSeenDevices(accountID: acctA)
            // Second read hits the in-memory cache, not the store.
            #expect(await store.loadSeenDevicesCalls == 1)
        }

        @Test
        @MainActor
        func `unrecognized classification raw values are dropped`() async {
            let store = MockOMEMOStore()
            let acctA = UUID().uuidString
            let accountJID = testAccountJID.description
            await store.seedSeenDevices(
                [OMEMOStoredSeenDevice(
                    accountJID: accountJID, deviceID: 7,
                    classification: "future-unknown-value",
                    staleStreak: 1, hasObservedHealthy: true
                )],
                for: accountJID
            )

            let service = makeOMEMOService(store: store)
            await service.installAccountJIDForTesting(accountJID, accountID: acctA)

            let loaded = await service.loadSeenDevices(accountID: acctA)
            // Forward-compat: the unknown row is silently dropped at load time.
            #expect(loaded[7] == nil)
        }

        @Test
        @MainActor
        func `replaceSeenDevices replaces in-memory and store state`() async {
            let store = MockOMEMOStore()
            let acctA = UUID().uuidString
            let accountJID = testAccountJID.description
            let service = makeOMEMOService(store: store)
            await service.installAccountJIDForTesting(accountJID, accountID: acctA)
            await service.mergeSeenDevices(
                [
                    1: SeenDeviceRecord(deviceID: 1, lastClassification: .stale, staleStreak: 1, hasObservedHealthy: true),
                    2: SeenDeviceRecord(deviceID: 2, lastClassification: .healthy, staleStreak: 0, hasObservedHealthy: true)
                ],
                accountID: acctA
            )
            await service.replaceSeenDevices(
                [9: SeenDeviceRecord(deviceID: 9, lastClassification: .healthy, staleStreak: 0, hasObservedHealthy: true)],
                accountID: acctA
            )
            let read = await service.loadSeenDevices(accountID: acctA)
            #expect(read.count == 1)
            #expect(read[9]?.lastClassification == .healthy)
            #expect(read[1] == nil)
            #expect(read[2] == nil)
        }

        @Test
        @MainActor
        func `purgeSeenDeviceClassifications clears in-memory and pending state`() async {
            let store = MockOMEMOStore()
            let id = UUID()
            let acctA = id.uuidString
            let accountJID = testAccountJID.description
            let service = makeOMEMOService(store: store)
            await service.installAccountJIDForTesting(accountJID, accountID: acctA)

            await service.mergeSeenDevices(
                [42: SeenDeviceRecord(deviceID: 42, lastClassification: .healthy, staleStreak: 0, hasObservedHealthy: true)],
                accountID: acctA
            )
            #expect(await service.loadSeenDevices(accountID: acctA).count == 1)

            service.purgeSeenDeviceClassifications(accountID: id)
            // After purge, the accountJID mapping is gone so we re-install
            // it before re-reading; the cache is empty by contract.
            await service.installAccountJIDForTesting(accountJID, accountID: acctA)
            #expect(await service.loadSeenDevices(accountID: acctA).isEmpty)
        }

        @Test
        @MainActor
        func `purgeOrphanDeviceRecords deletes one trust and session per device`() async throws {
            let store = MockOMEMOStore()
            let acctA = UUID().uuidString
            let accountJID = testAccountJID.description
            let service = makeOMEMOService(store: store)
            await service.installAccountJIDForTesting(accountJID, accountID: acctA)

            try await service.purgeOrphanDeviceRecords(deviceIDs: [10, 20, 30], accountID: acctA)
            #expect(await store.deleteTrustCalls == 3)
            #expect(await store.deleteSessionCalls == 3)
        }
    }

    /// Pins `MockOMEMOStore`'s upsert behavior so future mock-only edits can't
    /// silently drift back to append-on-write.
    struct MockStoreSemantics {
        @Test
        @MainActor
        func `saveSession upserts by peer JID and device ID`() async throws {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description
            let peerJID = "peer@example.com"
            let deviceID: UInt32 = 42

            let original = OMEMOStoredSession(
                accountJID: accountJID, peerJID: peerJID, peerDeviceID: deviceID,
                sessionData: Data([0xAA]), associatedData: Data([0xBB])
            )
            let replacement = OMEMOStoredSession(
                accountJID: accountJID, peerJID: peerJID, peerDeviceID: deviceID,
                sessionData: Data([0xCC]), associatedData: Data([0xDD])
            )
            try await store.saveSession(original)
            try await store.saveSession(replacement)

            let sessions = try await store.loadSessions(for: accountJID)
            #expect(sessions.count == 1)
            #expect(sessions.first?.sessionData == Data([0xCC]))
            #expect(sessions.first?.associatedData == Data([0xDD]))
        }

        @Test
        @MainActor
        func `saveTrust upserts by peer JID and device ID`() async throws {
            let store = MockOMEMOStore()
            let accountJID = testAccountJID.description
            let peerJID = "peer@example.com"
            let deviceID: UInt32 = 42

            try await store.saveTrust(OMEMOTrust(
                accountJID: accountJID, peerJID: peerJID,
                deviceID: deviceID, fingerprint: "", trustLevel: .undecided
            ))
            try await store.saveTrust(OMEMOTrust(
                accountJID: accountJID, peerJID: peerJID,
                deviceID: deviceID, fingerprint: "abcd", trustLevel: .verified
            ))

            let devices = try await store.loadAllDevices(for: peerJID, accountJID: accountJID)
            #expect(devices.count == 1)
            #expect(devices.first?.fingerprint == "abcd")
            #expect(devices.first?.trustLevel == .verified)
        }
    }
}
