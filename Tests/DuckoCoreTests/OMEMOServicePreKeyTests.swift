import DuckoTestSupport
import Foundation
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let accountJID = BareJID(localPart: "alice", domainPart: "example.com")!

private func storedPreKeys(_ ids: some Sequence<UInt32>, isUsed: Bool = false) -> [OMEMOStoredPreKey] {
    ids.map { OMEMOStoredPreKey(accountJID: accountJID.description, keyID: $0, keyData: Data(repeating: 0xD4, count: 32), isUsed: isUsed) }
}

/// A responder session in the stored encoding, or, with `isRatchetOnly`, its ratchet alone as the earlier encoding stored it.
private func storedSessionData(isRatchetOnly: Bool = false) throws -> [UInt8] {
    let ratchet = try OMEMODoubleRatchetSession(
        asResponderWithSharedSecret: Array(repeating: 1, count: 32),
        ourSignedPreKeyPair: OMEMOSignedPreKey(keyID: 1, identityKey: OMEMOIdentityKeyPair()).keyPair
    )
    let keyExchange = OMEMOKeyExchangeHeader(
        preKeyID: 1, signedPreKeyID: 1, identityKey: Array(repeating: 0xAB, count: 32), ephemeralKey: Array(repeating: 0xEE, count: 32)
    )
    return isRatchetOnly
        ? ratchet.serialize()
        : OMEMOSession(ratchet: ratchet, associatedData: Array(repeating: 0, count: 64), start: .received(keyExchange)).serialized
}

/// Records the IQs a module driven without a client sends, answering each with an empty result.
private final class IQRecorder: Sendable {
    private let sent = OSAllocatedUnfairLock<[DuckoXMPP.XMLElement]>(initialState: [])

    var context: ModuleContext {
        ModuleContext(
            sendStanza: { _, onAccepted in onAccepted?() },
            sendIQ: { [sent] iq, _ in
                sent.withLock { $0.append(iq.element) }
                return nil
            },
            emitEvent: { _ in },
            generateID: { "id" },
            connectedJID: { FullJID.parse("alice@example.com/res") },
            domain: "example.com"
        )
    }

    var iqs: [String] {
        sent.withLock { $0.map(\.xmlString) }
    }
}

extension OMEMOServiceTests {
    @MainActor
    struct PreKeyMaintenance {
        private let store = MockOMEMOStore()
        private let service: OMEMOService

        init() {
            self.service = OMEMOService(omemoStore: store)
        }

        private func seedStoredIdentity(preKeyIDs: [UInt32]) async {
            await store.seedFromIdentityData(makeIdentityData(preKeyIDs: preKeyIDs), accountJID: accountJID.description)
        }

        @Test func `marks consumed pre-keys as used`() async throws {
            await seedStoredIdentity(preKeyIDs: [1, 2, 3])

            await service.maintainPreKeys(accountJID: accountJID.description, module: StubPreKeyModule(identity: nil, consumed: [1, 3]))

            let preKeys = try await store.loadPreKeys(for: accountJID.description)
            #expect(Set(preKeys.filter(\.isUsed).map(\.keyID)) == [1, 3])
            #expect(Set(preKeys.filter { !$0.isUsed }.map(\.keyID)) == [2])
            let usedKeysErased = preKeys.filter(\.isUsed).allSatisfy(\.keyData.isEmpty)
            #expect(usedKeysErased)
        }

        @Test func `A key exchange's pre-key is recorded as used and the pre-keys are topped up past every id in use`() async throws {
            await seedStoredIdentity(preKeyIDs: Array(1 ... 5))
            await store.seedPreKeys(storedPreKeys([40], isUsed: true))
            let module = StubPreKeyModule(identity: makeIdentityData(preKeyIDs: [1, 2, 3, 4, 5, 60]))

            await service.maintainPreKeys(accountJID: accountJID.description, module: module, consumedPreKeyIDs: [2])

            let preKeys = try await store.loadPreKeys(for: accountJID.description)
            #expect(preKeys.first { $0.keyID == 2 }?.isUsed == true)
            let added = try #require(module.added.first)
            #expect(added.count == OMEMOPreKeyManager.targetPreKeyCount - 4)
            #expect(added.min() == 61)
            #expect(preKeys.count { !$0.isUsed } == OMEMOPreKeyManager.targetPreKeyCount)
            #expect(module.publishAttempts == 1)
        }

        @Test func `A failed publish is tried again at the next run, with nothing new used up`() async {
            await seedStoredIdentity(preKeyIDs: Array(1 ... 30))
            let module = StubPreKeyModule(identity: makeIdentityData(preKeyIDs: Array(1 ... 30)))
            module.setPublishFails(true)
            await service.maintainPreKeys(accountJID: accountJID.description, module: module)
            #expect(module.publishAttempts == 1)

            module.setPublishFails(false)
            await service.maintainPreKeys(accountJID: accountJID.description, module: module)

            #expect(module.publishAttempts == 2)
            #expect(!module.bundleNeedsPublish)
        }

        @Test func `A device whose identity is not stored yet is left to first-time persistence`() async {
            let module = StubPreKeyModule(identity: makeIdentityData(preKeyIDs: [1]))

            await service.maintainPreKeys(accountJID: accountJID.description, module: module)

            #expect(await store.savePreKeysCalls == 0)
            #expect(module.added.isEmpty)
            #expect(module.publishAttempts == 0)
        }

        @Test func `Pre-keys used up elsewhere are retired from the module, and its own used ones are not`() async throws {
            await seedStoredIdentity(preKeyIDs: Array(1 ... 30))
            try await store.consumePreKey(id: 5, accountJID: accountJID.description)
            let module = StubPreKeyModule(identity: makeIdentityData(preKeyIDs: Array(1 ... 30)), consumed: [9])

            await service.maintainPreKeys(accountJID: accountJID.description, module: module, consumedPreKeyIDs: [12])

            #expect(module.retired == [5, 12])
            #expect(module.publishAttempts == 1)
        }

        @Test func `Pre-keys that could not be stored are not handed out, and the next run tops up again`() async throws {
            await seedStoredIdentity(preKeyIDs: [1])
            let module = StubPreKeyModule(identity: makeIdentityData(preKeyIDs: [1]))
            await store.setFailing(.savePreKeys)

            await service.maintainPreKeys(accountJID: accountJID.description, module: module)
            #expect(module.added.isEmpty)

            await store.setFailing(.savePreKeys, false)
            await service.maintainPreKeys(accountJID: accountJID.description, module: module)

            #expect(module.added.count == 1)
            #expect(try await store.loadPreKeys(for: accountJID.description).count { !$0.isUsed } == OMEMOPreKeyManager.targetPreKeyCount)
        }
    }

    @MainActor
    struct BuildModule {
        private let store = MockOMEMOStore()
        private let service: OMEMOService

        init() {
            self.service = OMEMOService(omemoStore: store)
        }

        /// A module built from the store, with its identity installed as an established session installs it.
        private func buildInstalledModule(recorder: IQRecorder) async -> OMEMOModule {
            let pepModule = PEPModule()
            pepModule.setUp(recorder.context)
            let module = await service.buildModule(for: accountJID, accountID: UUID(), pepModule: pepModule)
            module.setUp(recorder.context)
            module.handleSessionEstablished(resumed: true)
            return module
        }

        @Test(arguments: [MockOMEMOStore.FailingCall.loadIdentity, .loadPreKeys, .loadSignedPreKey, .loadSessions])
        func `Keys that cannot be read never make a new device`(failing: MockOMEMOStore.FailingCall) async throws {
            await store.seedFromIdentityData(makeIdentityData(preKeyIDs: [1]), accountJID: accountJID.description)
            await store.setFailing(failing)
            let recorder = IQRecorder()

            let module = await buildInstalledModule(recorder: recorder)
            try await module.handleConnect()

            #expect(module.ownIdentityData == nil)
            #expect(recorder.iqs.isEmpty)
        }

        @Test func `A missing signed pre-key is replaced for the stored device and stored before it is published`() async throws {
            await store.seedIdentity(OMEMOStoredIdentity(
                accountJID: accountJID.description, deviceID: 4242, identityKeyData: Data(repeating: 0xA1, count: 32), registrationID: 0
            ))
            await store.seedPreKeys(storedPreKeys(1 ... 30))
            let recorder = IQRecorder()

            let module = await buildInstalledModule(recorder: recorder)
            // Armed: nothing was published yet, and the replacement is stored already.
            #expect(recorder.iqs.isEmpty)
            let signedPreKey = try #require(await store.loadSignedPreKey(for: accountJID.description))
            await service.maintainPreKeys(accountJID: accountJID.description, module: module)

            #expect(module.ownIdentityData?.deviceID == 4242)
            let publish = try #require(recorder.iqs.first { $0.contains("<publish") })
            #expect(publish.contains("<publish node=\"\(XMPPNamespaces.omemoBundles)\"><item id=\"4242\">"))
            #expect(publish.contains("<spk id=\"\(signedPreKey.keyID)\">"))
            #expect(publish.contains(Base64.encode(Array(signedPreKey.signature))))
        }

        @Test func `A replacement signed pre-key that cannot be stored is never published`() async throws {
            await store.seedIdentity(OMEMOStoredIdentity(
                accountJID: accountJID.description, deviceID: 4242, identityKeyData: Data(repeating: 0xA1, count: 32), registrationID: 0
            ))
            await store.seedPreKeys(storedPreKeys(1 ... 30))
            await store.setFailing(.saveSignedPreKey)
            let recorder = IQRecorder()

            let module = await buildInstalledModule(recorder: recorder)
            try await module.handleConnect()

            #expect(module.ownIdentityData == nil)
            #expect(recorder.iqs.isEmpty)
        }

        @Test func `A stored session that cannot be decoded, as one in the earlier encoding, is skipped and the others are restored`() async throws {
            await store.seedFromIdentityData(makeIdentityData(preKeyIDs: [1]), accountJID: accountJID.description)
            let rows = try [(UInt32(1), Data([0xFF])), (2, Data(storedSessionData(isRatchetOnly: true))), (3, Data(storedSessionData()))]
            for (deviceID, data) in rows {
                try await store.saveSession(OMEMOStoredSession(
                    accountJID: accountJID.description, peerJID: "peer@example.com", peerDeviceID: deviceID,
                    sessionData: data, associatedData: Data(repeating: 0, count: 64)
                ))
            }

            let module = await buildInstalledModule(recorder: IQRecorder())

            let peer = try #require(BareJID.parse("peer@example.com"))
            #expect(module.exportSession(jid: peer, deviceID: 3) != nil)
            #expect(module.exportSession(jid: peer, deviceID: 2) == nil)
            #expect(module.exportSession(jid: peer, deviceID: 1) == nil)
            #expect(module.ownIdentityData != nil)
        }
    }

    /// Upkeep follows the events that change which pre-keys are in use: a contact's key exchange and a resumed stream.
    @MainActor
    struct Triggers {
        private let omemoStore = MockOMEMOStore()
        private let service: OMEMOService

        init() {
            self.service = OMEMOService(omemoStore: omemoStore)
        }

        @Test func `A contact's key exchange records the pre-key it used`() async throws {
            await omemoStore.seedFromIdentityData(makeIdentityData(preKeyIDs: [1, 2, 3]), accountJID: testJIDString)
            let accounts = makeAccountService(store: MockPersistenceStore())
            service.setAccountService(accounts)
            let accountID = try await accounts.createAccount(jidString: testJIDString, requireTLS: false)
            let peer = try #require(BareJID.parse("peer@example.com"))

            await service.handleEvent(
                .omemoSessionEstablished(jid: peer, deviceID: 7, identityKey: Array(repeating: 0xAB, count: 32), consumedPreKeyID: 2),
                accountID: accountID
            )

            let preKeys = try await omemoStore.loadPreKeys(for: testJIDString)
            #expect(preKeys.filter(\.isUsed).map(\.keyID) == [2])
        }

        @Test func `A resumed stream runs upkeep`() async throws {
            await omemoStore.seedFromIdentityData(makeIdentityData(preKeyIDs: [1]), accountJID: testJIDString)
            let accounts = makeAccountService(store: MockPersistenceStore())
            service.setAccountService(accounts)
            let accountID = try await accounts.createAccount(jidString: testJIDString, requireTLS: false)
            let resumedJID = try #require(FullJID.parse("\(testJIDString)/res"))

            await service.handleEvent(.streamResumed(resumedJID), accountID: accountID)

            #expect(await omemoStore.loadPreKeysCalls == 1)
        }
    }

    @MainActor
    struct SavesWhileConnecting {
        /// The client stays in its handshake, so the account counts as connecting, as it does while the server replays
        /// stanzas after a resume.
        @Test func `A session and its trust row are saved while the account is still connecting`() async throws {
            let store = MockPersistenceStore()
            let omemoStore = MockOMEMOStore()
            let transport = MockTransport()
            let peer = try #require(BareJID.parse("peer@example.com"))
            let omemoModule = OMEMOModule(pepModule: PEPModule())
            try omemoModule.restoreSessions([OMEMOModule.StoredSessionEntry(
                jid: peer, deviceID: 7, sessionData: storedSessionData(), associatedData: Array(repeating: 0, count: 64)
            )])
            let accounts = makeAccountService(
                store: store, clientFactory: MockXMPPClientFactory(transport: transport, modules: [omemoModule])
            )
            let service = OMEMOService(omemoStore: omemoStore)
            service.setAccountService(accounts)
            let accountID = try await accounts.createAccount(jidString: testJIDString, requireTLS: false)
            let connection = Task { try await accounts.connect(accountID: accountID, password: "secret") }
            try await eventually { accounts.client(for: accountID) != nil }
            try #require(accounts.connectedClient(for: accountID) == nil)

            await service.handleEvent(
                .omemoSessionEstablished(jid: peer, deviceID: 7, identityKey: Array(repeating: 0xAB, count: 32), consumedPreKeyID: nil),
                accountID: accountID
            )

            #expect(try await omemoStore.loadSessions(for: testJIDString).map(\.peerDeviceID) == [7])
            let trust = try await omemoStore.loadTrust(accountJID: testJIDString, peerJID: peer.description, deviceID: 7)
            #expect(trust?.fingerprint == String(repeating: "ab", count: 32))
            await accounts.disconnect(accountID: accountID)
            _ = await connection.result
        }
    }
}
