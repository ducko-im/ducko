import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let peer = BareJID(localPart: "peer", domainPart: "example.com")!
private let keyA = [UInt8](repeating: 0xAA, count: 32)
private let fingerprintA = omemoFingerprint(of: keyA)
private let fingerprintB = omemoFingerprint(of: [UInt8](repeating: 0xBB, count: 32))

/// One process's service over a store, as the app and the CLI each run one, with an account for the test JID.
@MainActor
private struct ServiceProcess {
    let service: OMEMOService
    /// Held here, since the service holds it weakly.
    let accounts: AccountService

    var accountID: UUID {
        accounts.accounts[0].id
    }

    init(store: MockOMEMOStore) async throws {
        self.service = OMEMOService(omemoStore: store)
        self.accounts = makeAccountService(store: MockPersistenceStore())
        service.setAccountService(accounts)
        _ = try await accounts.createAccount(jidString: testJIDString, requireTLS: false)
    }

    func trust(fingerprint: String = fingerprintA) async throws {
        try await service.trustDevice(accountID: accountID, peerJID: peer.description, deviceID: 1, fingerprint: fingerprint)
    }

    func untrust() async throws {
        try await service.untrustDevice(accountID: accountID, peerJID: peer.description, deviceID: 1)
    }
}

extension OMEMOServiceTests {
    /// The account's trust guard follows the user's decisions: a distrust at once, and a grant once saved. It takes in
    /// those made by another process over the same store by the next send, and keeps the pre-keys that key exchanges used.
    @MainActor
    struct TrustDecisions {
        private let store = MockOMEMOStore()
        private let process: ServiceProcess

        init() async throws {
            self.process = try await ServiceProcess(store: store)
        }

        private var service: OMEMOService {
            process.service
        }

        private var accountID: UUID {
            process.accountID
        }

        private var trustGuard: OMEMOTrustGuard {
            service.trustGuard(forAccountJID: testJIDString)
        }

        /// What the guard says of a session with the peer's device 1 under key A.
        private var verdict: OMEMOTrustGuard.Verdict {
            trustGuard.admitSession(with: SessionKey(jid: peer, deviceID: 1), identityKey: keyA)
        }

        private func seedTrust(fingerprint: String, level: OMEMOTrustLevel) async throws {
            try await store.saveTrust(OMEMOTrust(
                accountJID: testJIDString, peerJID: peer.description, deviceID: 1, fingerprint: fingerprint, trustLevel: level
            ))
        }

        private func storedTrust(deviceID: UInt32 = 1) async throws -> OMEMOTrust? {
            try await store.loadAllDevices(for: peer.description, accountJID: testJIDString).first { $0.deviceID == deviceID }
        }

        /// Resolves a send to the peer, which merges the peer's stored rows into the guard.
        private func prepareSend() async {
            _ = await service.shouldEncrypt(jid: peer, accountID: accountID, conversationEncryptionEnabled: true)
        }

        private func untrust() async throws {
            try await process.untrust()
        }

        private func trust(fingerprint: String = fingerprintA) async throws {
            try await process.trust(fingerprint: fingerprint)
        }

        /// Merges the peer's rows at the store's next trust write, while it is under way.
        private func prepareSendDuringNextTrustWrite() async {
            let service = service
            let accountID = accountID
            await store.setBeforeTrustWrite { @MainActor in
                _ = await service.shouldEncrypt(jid: peer, accountID: accountID, conversationEncryptionEnabled: true)
            }
        }

        // MARK: - Pre-Keys

        @Test(arguments: [true, false])
        func `A pre-key a key exchange used is saved as used by a later upkeep run, and only for the device that handed it out`(
            isThisDevice: Bool
        ) async throws {
            let identity = makeIdentityData(preKeyIDs: [1, 2, 3])
            await store.seedFromIdentityData(identity, accountJID: testJIDString)
            _ = trustGuard.admitKeyExchange(
                from: SessionKey(jid: peer, deviceID: 1), offeredKey: keyA, replacing: .none,
                preKey: OMEMOTrustGuard.PreKeyUse(id: 2, ownDeviceID: isThisDevice ? identity.deviceID : 9999, isUsedByThisModule: false)
            )
            await store.setFailing(.consumePreKey)
            await service.maintainPreKeys(accountJID: testJIDString, module: nil)
            await store.setFailing(.consumePreKey, false)

            await service.maintainPreKeys(accountJID: testJIDString, module: nil)

            let used = try await store.loadPreKeys(for: testJIDString).filter(\.isUsed).map(\.keyID)
            #expect(used == (isThisDevice ? [2] : []))
        }

        // MARK: - Untrust

        @Test func `An untrust whose save fails throws and still refuses the device, which a stored trusted row does not loosen`() async throws {
            try await seedTrust(fingerprint: fingerprintA, level: .trusted)
            await store.setFailing(.markTrust)

            await #expect(throws: MockOMEMOStore.InjectedFailure.self) { try await untrust() }
            await prepareSend()

            #expect(verdict == .untrusted)
        }

        @Test func `An untrust made before the account's first module is built stays when the module loads the stored rows`() async throws {
            try await seedTrust(fingerprint: fingerprintA, level: .trusted)
            await store.setFailing(.markTrust)
            try? await untrust()

            _ = try await service.buildModule(for: #require(BareJID.parse(testJIDString)), accountID: accountID, pepModule: PEPModule())

            #expect(verdict == .untrusted)
        }

        @Test func `An untrust of a device with no row stores the key held for it`() async throws {
            #expect(verdict == .accepted)

            try await untrust()

            let stored = try await storedTrust()
            #expect(stored?.fingerprint == fingerprintA)
            #expect(stored?.trustLevel == .untrusted)
        }

        /// The guard keys a device by its normalized address, so the row must use the same one or a send-time merge of
        /// the real row would lift the refusal.
        @Test func `An untrust of an address typed in another case changes the device's own row`() async throws {
            try await seedTrust(fingerprint: fingerprintA, level: .trusted)

            try await service.untrustDevice(accountID: accountID, peerJID: "Peer@Example.com", deviceID: 1)
            await prepareSend()

            #expect(try await storedTrust()?.trustLevel == .untrusted)
            #expect(try await store.loadAllDevices(for: "Peer@Example.com", accountJID: testJIDString).isEmpty)
            #expect(verdict == .untrusted)
        }

        @Test func `An untrust keeps the stored fingerprint and the held one, even when they differ`() async throws {
            try await seedTrust(fingerprint: fingerprintB, level: .trusted)
            #expect(verdict == .accepted)

            try await untrust()

            let stored = try await storedTrust()
            #expect(stored?.fingerprint == fingerprintB)
            #expect(stored?.trustLevel == .untrusted)
            #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 1) == fingerprintA)
            #expect(verdict == .untrusted)
        }

        @Test func `An untrust saved while a send merged the device leaves nothing pending, so a re-trust from another process lifts it`() async throws {
            try await seedTrust(fingerprint: fingerprintA, level: .trusted)
            await prepareSendDuringNextTrustWrite()
            try await untrust()
            #expect(verdict == .untrusted)
            let other = try await ServiceProcess(store: store)

            try await other.trust()
            await prepareSend()

            #expect(verdict == .accepted)
        }

        // MARK: - Grants

        @Test func `A trust after a failed untrust lifts the refusal, even with a send merging the device during its save`() async throws {
            try await seedTrust(fingerprint: fingerprintA, level: .trusted)
            await store.setFailing(.markTrust)
            try? await untrust()
            await prepareSendDuringNextTrustWrite()

            try await trust()

            #expect(verdict == .accepted)
        }

        @Test func `A trust whose save fails leaves the device as it was`() async throws {
            try await seedTrust(fingerprint: fingerprintA, level: .untrusted)
            await prepareSend()
            await store.setFailing(.saveTrust)

            await #expect(throws: MockOMEMOStore.InjectedFailure.self) { try await trust() }

            #expect(verdict == .untrusted)
            #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 1) == fingerprintA)
        }

        /// Another process may have stored the device's first key; a Trust that compared nothing must not erase it.
        @Test func `A trust from a list without a fingerprint keeps the one another process stored`() async throws {
            try await seedTrust(fingerprint: fingerprintB, level: .undecided)

            try await trust(fingerprint: "")

            let stored = try await storedTrust()
            #expect(stored?.fingerprint == fingerprintB)
            #expect(stored?.trustLevel == .trusted)
        }

        @Test func `A verify of the held fingerprint stores Verified and keeps the device admitted`() async throws {
            try await seedTrust(fingerprint: "", level: .trusted)
            #expect(verdict == .accepted)

            try await service.verifyDevice(accountID: accountID, peerJID: peer.description, deviceID: 1, fingerprint: fingerprintA)

            #expect(try await storedTrust()?.trustLevel == .verified)
            #expect(verdict == .accepted)
        }

        /// The stored rows of the device's duplicates disagree, so a Trust without a fingerprint would certify neither.
        @Test func `A trust without a fingerprint of a device whose rows disagree is refused`() async throws {
            try await seedTrust(fingerprint: "", level: .untrusted)
            await store.setFailing(.markTrustConflict)

            let error = await #expect(throws: OMEMOServiceError.self) { try await trust(fingerprint: "") }

            if case .conflictingFingerprints? = error {} else { Issue.record("Expected conflicting fingerprints, got \(String(describing: error))") }
        }

        @Test func `A trust and the device list use the device's normalized address, whatever case was typed`() async throws {
            try await seedTrust(fingerprint: fingerprintA, level: .untrusted)

            try await service.trustDevice(accountID: accountID, peerJID: "Peer@Example.com", deviceID: 1, fingerprint: fingerprintA)

            #expect(try await storedTrust()?.trustLevel == .trusted)
            #expect(await service.deviceInfoList(for: "Peer@Example.com", accountID: accountID).map(\.trustLevel) == [.trusted])
        }

        @Test func `A verify without a fingerprint is refused, changing nothing`() async throws {
            try await seedTrust(fingerprint: "", level: .trusted)

            let error = await #expect(throws: OMEMOServiceError.self) {
                try await service.verifyDevice(accountID: accountID, peerJID: peer.description, deviceID: 1, fingerprint: "")
            }

            if case .noFingerprintToVerify? = error {} else { Issue.record("Expected a missing fingerprint, got \(String(describing: error))") }
            #expect(try await storedTrust()?.trustLevel == .trusted)
        }

        @Test func `A trust from a list without a fingerprint saves the one held`() async throws {
            try await seedTrust(fingerprint: "", level: .undecided)
            #expect(verdict == .accepted)

            try await trust(fingerprint: "")

            let stored = try await storedTrust()
            #expect(stored?.fingerprint == fingerprintA)
            #expect(stored?.trustLevel == .trusted)
        }

        @Test func `A verify of another fingerprint than the one held is refused, changing nothing`() async throws {
            try await seedTrust(fingerprint: fingerprintB, level: .undecided)
            #expect(verdict == .accepted)

            let error = await #expect(throws: OMEMOServiceError.self) {
                try await service.verifyDevice(accountID: accountID, peerJID: peer.description, deviceID: 1, fingerprint: fingerprintB)
            }

            if case .identityKeyMismatch? = error {} else { Issue.record("Expected an identity key mismatch, got \(String(describing: error))") }
            let stored = try await storedTrust()
            #expect(stored?.fingerprint == fingerprintB)
            #expect(stored?.trustLevel == .undecided)
            #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 1) == fingerprintA)
        }

        @Test func `A stored Verified row lifts a refusal at the next send`() async throws {
            try await seedTrust(fingerprint: fingerprintA, level: .untrusted)
            await prepareSend()
            #expect(verdict == .untrusted)

            try await seedTrust(fingerprint: fingerprintA, level: .verified)
            await prepareSend()

            #expect(verdict == .accepted)
        }

        // MARK: - Device Lists

        /// A device list names devices, it does not decide on them, so it only adds rows for devices without one.
        @Test func `A device list adds rows for new devices and leaves decided ones as they are`() async throws {
            try await seedTrust(fingerprint: fingerprintA, level: .untrusted)

            await service.handleEvent(.omemoDeviceListReceived(jid: peer, devices: [1, 2]), accountID: accountID)

            let first = try await storedTrust()
            let second = try await storedTrust(deviceID: 2)
            #expect(first?.trustLevel == .untrusted)
            #expect(first?.fingerprint == fingerprintA)
            #expect(second?.trustLevel == .undecided)
            #expect(second?.fingerprint == "")
        }

        // MARK: - Other Processes

        @Test func `An untrust and a re-trust made by another process reach the guard by the next send`() async throws {
            try await seedTrust(fingerprint: fingerprintA, level: .trusted)
            let other = try await ServiceProcess(store: store)
            await prepareSend()
            #expect(verdict == .accepted)

            try await other.untrust()
            await prepareSend()
            #expect(verdict == .untrusted)

            try await other.trust()
            await prepareSend()
            #expect(verdict == .accepted)
        }
    }

    /// A send merges the stored rows of the account's own devices and of each room member, not only those of the contact.
    @MainActor
    struct SendMerges {
        @Test func `A send merges the rows of the account's own devices and of a room's members`() async throws {
            let store = MockOMEMOStore()
            let transport = MockTransport()
            // Encrypting stops at the module, after the recipients were chosen.
            let omemoModule = OMEMOModule(pepModule: PEPModule())
            omemoModule.markIdentityUnavailable()
            let accounts = makeAccountService(
                store: MockPersistenceStore(), clientFactory: MockXMPPClientFactory(transport: transport, modules: [omemoModule])
            )
            let service = OMEMOService(omemoStore: store)
            service.setAccountService(accounts)
            let accountID = try await accounts.createAccount(jidString: testJIDString, requireTLS: false)
            let (_, connection) = try await driveMockConnect(accounts, accountID: accountID, transport: transport)
            let own = try #require(BareJID.parse(testJIDString))
            let member = try #require(BareJID(localPart: "carol", domainPart: "example.com"))
            for jid in [own, member] {
                try await store.saveTrust(OMEMOTrust(
                    accountJID: testJIDString, peerJID: jid.description, deviceID: 1, fingerprint: fingerprintA, trustLevel: .untrusted
                ))
            }

            _ = try? await service.encryptMessage(content: [], to: peer, trustedDeviceIDs: [9], accountID: accountID)
            _ = try? await service.encryptGroupMessage(
                content: [], roomJID: try #require(BareJID(localPart: "room", domainPart: "conference.example.com")), memberJIDs: [member], accountID: accountID
            )

            let trustGuard = service.trustGuard(forAccountJID: testJIDString)
            for jid in [own, member] {
                #expect(trustGuard.admitSession(with: SessionKey(jid: jid, deviceID: 1), identityKey: keyA) == .untrusted)
            }
            await accounts.disconnect(accountID: accountID)
            _ = await connection.result
        }
    }
}
