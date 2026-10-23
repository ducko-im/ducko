import Testing
@testable import DuckoXMPP

private let peer = BareJID(localPart: "peer", domainPart: "example.com")!
private let keyA = [UInt8](repeating: 0xAA, count: 32)
private let keyB = [UInt8](repeating: 0xBB, count: 32)
private let fingerprintA = omemoFingerprint(of: keyA)
private let fingerprintB = omemoFingerprint(of: keyB)

/// The trust guard's rules: which key exchanges and sessions it admits, and how stored rows and the user's decisions
/// change what it holds.
struct OMEMOTrustGuardTests {
    private let trustGuard = OMEMOTrustGuard()

    /// Merges a stored row for the peer's device, read now unless `stamp` says when.
    private func mergeRow(
        fingerprint: String, decision: OMEMOTrustGuard.StoredTrust.Decision, deviceID: UInt32 = 1, loadedAfter stamp: UInt64? = nil
    ) {
        trustGuard.mergeRow(peer: peer, deviceID: deviceID, fingerprint: fingerprint, decision: decision, loadedAfter: stamp)
    }

    private func admitKeyExchange(
        offering key: [UInt8] = keyA, session: OMEMOTrustGuard.ExistingSession = .none, deviceID: UInt32 = 1, preKeyID: UInt32 = 7,
        ownDeviceID: UInt32 = 200, usedByThisModule: Bool = false
    ) -> OMEMOTrustGuard.Verdict {
        trustGuard.admitKeyExchange(
            from: SessionKey(jid: peer, deviceID: deviceID), offeredKey: key, replacing: session,
            preKey: OMEMOTrustGuard.PreKeyUse(id: preKeyID, ownDeviceID: ownDeviceID, isUsedByThisModule: usedByThisModule)
        )
    }

    private func admitSession(_ key: [UInt8]?) -> OMEMOTrustGuard.Verdict {
        trustGuard.admitSession(with: SessionKey(jid: peer, deviceID: 1), identityKey: key)
    }

    // MARK: - Admission

    enum Held: Sendable {
        case none, keyA, keyB, refused
    }

    @Test(arguments: [
        (Held.none, OMEMOTrustGuard.ExistingSession.none, OMEMOTrustGuard.Verdict.accepted),
        (.none, .key(keyA), .accepted),
        (.none, .key(keyB), .keyMismatch),
        (.none, .unreadable, .keyMismatch),
        (.keyA, .key(keyB), .accepted),
        (.keyA, .unreadable, .accepted),
        (.keyB, .none, .keyMismatch),
        (.refused, .none, .untrusted)
    ])
    func `A key exchange offering key A is admitted only for the key held, or else the session's, and a refusal changes nothing`(
        held: Held, session: OMEMOTrustGuard.ExistingSession, expected: OMEMOTrustGuard.Verdict
    ) {
        switch held {
        case .none: break
        case .keyA: mergeRow(fingerprint: fingerprintA, decision: .granted)
        case .keyB: mergeRow(fingerprint: fingerprintB, decision: .granted)
        case .refused: mergeRow(fingerprint: fingerprintA, decision: .untrusted)
        }
        let heldBefore = trustGuard.heldFingerprint(peer: peer, deviceID: 1)

        let verdict = admitKeyExchange(session: session)

        #expect(verdict == expected)
        if verdict == .accepted {
            #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 1) == fingerprintA)
            #expect(trustGuard.consumedPreKeyIDs(ownDeviceID: 200) == [7])
        } else {
            #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 1) == heldBefore)
            #expect(trustGuard.consumedPreKeyIDs(ownDeviceID: 200).isEmpty)
        }
    }

    @Test(arguments: [true, false])
    func `A pre-key another module used is refused, one this module used is not, and another device's ids are its own`(usedByThisModule: Bool) {
        #expect(admitKeyExchange(deviceID: 1) == .accepted)

        #expect(admitKeyExchange(deviceID: 2, usedByThisModule: usedByThisModule) == (usedByThisModule ? .accepted : .preKeyUsed))
        #expect(admitKeyExchange(deviceID: 3, ownDeviceID: 300) == .accepted)
        #expect(trustGuard.consumedPreKeyIDs(ownDeviceID: 300) == [7])
    }

    @Test func `A session is admitted only with a readable key that matches the held one, and the first one is held`() {
        #expect(admitSession(nil) == .keyMismatch)
        #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 1).isEmpty)

        #expect(admitSession(keyA) == .accepted)
        #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 1) == fingerprintA)
        #expect(admitSession(keyB) == .keyMismatch)

        _ = trustGuard.applyDistrust(peer: peer, deviceID: 1)
        #expect(admitSession(keyA) == .untrusted)
    }

    // MARK: - Stored Trust

    @Test func `A stored fingerprint fills an empty one but never replaces one held`() {
        mergeRow(fingerprint: fingerprintB, decision: .granted, deviceID: 2)
        #expect(admitSession(keyA) == .accepted)

        mergeRow(fingerprint: fingerprintB, decision: .granted)

        #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 2) == fingerprintB)
        #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 1) == fingerprintA)
    }

    @Test func `A stored untrusted row refuses the device whatever its fingerprint, keeping the one held`() {
        #expect(admitSession(keyA) == .accepted)

        mergeRow(fingerprint: fingerprintB, decision: .untrusted)

        #expect(admitSession(keyA) == .untrusted)
        #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 1) == fingerprintA)
    }

    @Test func `A stored row with another fingerprint does not lift a refusal, and one with the held fingerprint does`() {
        mergeRow(fingerprint: fingerprintA, decision: .untrusted)

        mergeRow(fingerprint: fingerprintB, decision: .granted)
        #expect(admitSession(keyA) == .untrusted)

        mergeRow(fingerprint: fingerprintA, decision: .granted)
        #expect(admitSession(keyA) == .accepted)
    }

    @Test func `Rows absent from a load leave their devices as they were`() {
        mergeRow(fingerprint: fingerprintA, decision: .untrusted)

        mergeRow(fingerprint: "", decision: .granted, deviceID: 2)

        #expect(admitSession(keyA) == .untrusted)
    }

    /// A placeholder for a listed device, as one re-created after its row was purged, is no decision to reverse one.
    @Test(arguments: [OMEMOTrustGuard.StoredTrust.Decision.granted, .undecided])
    func `Only a granted row lifts a refusal, also with no fingerprint`(decision: OMEMOTrustGuard.StoredTrust.Decision) {
        #expect(admitSession(keyA) == .accepted)
        mergeRow(fingerprint: fingerprintA, decision: .untrusted)

        mergeRow(fingerprint: "", decision: decision)

        #expect(admitSession(keyA) == (decision == .granted ? .accepted : .untrusted))
    }

    @Test(arguments: [true, false])
    func `Duplicate rows of a device in one load keep its saved refusal whichever comes first`(untrustedFirst: Bool) {
        mergeRow(fingerprint: "", decision: .untrusted)
        let rows = [OMEMOTrustGuard.StoredTrust.Decision.untrusted, .granted].map {
            OMEMOTrustGuard.StoredTrust(peer: peer, deviceID: 1, fingerprint: "", decision: $0)
        }

        trustGuard.merge(untrustedFirst ? rows : rows.reversed(), loadedAfter: trustGuard.currentStamp())

        #expect(admitSession(keyA) == .untrusted)
    }

    @Test func `Decryption passes with no key held or the held key, also for a refused device, and not with another or none`() {
        let device = SessionKey(jid: peer, deviceID: 1)
        #expect(trustGuard.admitsDecryption(from: device, identityKey: keyB))

        mergeRow(fingerprint: fingerprintA, decision: .untrusted)

        #expect(trustGuard.admitsDecryption(from: device, identityKey: keyA))
        #expect(!trustGuard.admitsDecryption(from: device, identityKey: keyB))
        #expect(!trustGuard.admitsDecryption(from: device, identityKey: nil))
    }

    enum LaterChange: CaseIterable {
        case admission, grant
    }

    @Test(arguments: LaterChange.allCases)
    func `A load read before a change does not undo it`(change: LaterChange) throws {
        let stamp = trustGuard.currentStamp()
        switch change {
        case .admission:
            #expect(admitSession(keyA) == .accepted)
        case .grant:
            let grant = try #require(trustGuard.prepareGrant(peer: peer, deviceID: 1, fingerprint: fingerprintA))
            trustGuard.applyGrant(peer: peer, deviceID: 1, decision: grant.decision)
        }

        mergeRow(fingerprint: fingerprintB, decision: .untrusted, loadedAfter: stamp)

        #expect(admitSession(keyA) == .accepted)
        mergeRow(fingerprint: fingerprintB, decision: .untrusted)
        #expect(admitSession(keyA) == .untrusted)
    }

    @Test func `A merge that changes nothing does not count as a change`() {
        mergeRow(fingerprint: fingerprintA, decision: .granted)
        let stamp = trustGuard.currentStamp()

        mergeRow(fingerprint: fingerprintA, decision: .granted)
        mergeRow(fingerprint: fingerprintA, decision: .untrusted, loadedAfter: stamp)

        #expect(admitSession(keyA) == .untrusted)
    }

    // MARK: - Decisions

    @Test func `A distrust is not loosened by stored rows until it is saved`() {
        mergeRow(fingerprint: fingerprintA, decision: .granted)
        let decision = trustGuard.applyDistrust(peer: peer, deviceID: 1)

        mergeRow(fingerprint: fingerprintA, decision: .granted)
        #expect(admitSession(keyA) == .untrusted)

        trustGuard.distrustSaved(peer: peer, deviceID: 1, decision: decision)
        mergeRow(fingerprint: fingerprintA, decision: .granted)
        #expect(admitSession(keyA) == .accepted)
    }

    @Test(arguments: [true, false])
    func `A saved distrust stops being pending whether or not a merge altered the device meanwhile`(mergeAlters: Bool) {
        let decision = trustGuard.applyDistrust(peer: peer, deviceID: 1)
        mergeRow(fingerprint: mergeAlters ? fingerprintA : "", decision: .granted)

        trustGuard.distrustSaved(peer: peer, deviceID: 1, decision: decision)

        mergeRow(fingerprint: fingerprintA, decision: .granted)
        #expect(admitSession(keyA) == .accepted)
    }

    @Test func `A load read before a distrust's save keeps the device refused when it merges after the save`() {
        mergeRow(fingerprint: fingerprintA, decision: .granted)
        let stamp = trustGuard.currentStamp()
        let decision = trustGuard.applyDistrust(peer: peer, deviceID: 1)
        trustGuard.distrustSaved(peer: peer, deviceID: 1, decision: decision)

        mergeRow(fingerprint: fingerprintA, decision: .granted, loadedAfter: stamp)

        #expect(admitSession(keyA) == .untrusted)
    }

    @Test func `An older grant's save does not lift a newer distrust`() throws {
        let grant = try #require(trustGuard.prepareGrant(peer: peer, deviceID: 1, fingerprint: fingerprintA))
        _ = trustGuard.applyDistrust(peer: peer, deviceID: 1)

        trustGuard.applyGrant(peer: peer, deviceID: 1, decision: grant.decision)

        #expect(admitSession(keyA) == .untrusted)
    }

    @Test func `An older distrust's save leaves a newer distrust pending`() {
        let older = trustGuard.applyDistrust(peer: peer, deviceID: 1)
        _ = trustGuard.applyDistrust(peer: peer, deviceID: 1)

        trustGuard.distrustSaved(peer: peer, deviceID: 1, decision: older)
        mergeRow(fingerprint: fingerprintA, decision: .granted)

        #expect(admitSession(keyA) == .untrusted)
    }

    @Test func `A grant holds the fingerprint the user compared, or the held one when they compared none, and refuses another`() throws {
        let compared = try #require(trustGuard.prepareGrant(peer: peer, deviceID: 1, fingerprint: fingerprintA))
        #expect(compared.fingerprint == fingerprintA)
        #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 1) == fingerprintA)

        #expect(trustGuard.prepareGrant(peer: peer, deviceID: 1, fingerprint: "")?.fingerprint == fingerprintA)
        #expect(trustGuard.prepareGrant(peer: peer, deviceID: 1, fingerprint: fingerprintB) == nil)
        #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 1) == fingerprintA)
    }

    @Test func `A key exchange with another key while a grant saves is refused`() throws {
        let grant = try #require(trustGuard.prepareGrant(peer: peer, deviceID: 1, fingerprint: fingerprintA))

        #expect(admitKeyExchange(offering: keyB) == .keyMismatch)

        trustGuard.applyGrant(peer: peer, deviceID: 1, decision: grant.decision)
        #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 1) == fingerprintA)
    }
}
