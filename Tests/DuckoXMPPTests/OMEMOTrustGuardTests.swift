import Testing
@testable import DuckoXMPP

private let peer = BareJID(localPart: "peer", domainPart: "example.com")!
private let keyA = [UInt8](repeating: 0xAA, count: 32)
private let keyB = [UInt8](repeating: 0xBB, count: 32)
private let fingerprintA = omemoFingerprint(of: keyA, format: .omemo2)
private let fingerprintB = omemoFingerprint(of: keyB, format: .omemo2)

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
            from: OMEMODeviceKey(jid: peer, deviceID: deviceID), offering: omemoFingerprint(of: key, format: .omemo2), standIn: session,
            preKey: OMEMOTrustGuard.PreKeyUse(id: preKeyID, ownDeviceID: ownDeviceID, isUsedByThisModule: usedByThisModule)
        )
    }

    private func admitSession(_ key: [UInt8]?) -> OMEMOTrustGuard.Verdict {
        trustGuard.admitSession(with: OMEMODeviceKey(jid: peer, deviceID: 1), fingerprint: key.map { omemoFingerprint(of: $0, format: .omemo2) })
    }

    // MARK: - Display

    private static let formlessFingerprints = [
        "", "abcd", String(repeating: "zz", count: 32), "01" + String(repeating: "00", count: 31), "06" + String(repeating: "11", count: 32)
    ]

    @Test(arguments: formlessFingerprints)
    func `A stored fingerprint that is empty or has no Curve25519 form displays unchanged`(stored: String) {
        #expect(omemoDisplayFingerprint(ofStoredFingerprint: stored) == stored)
    }

    @Test func `A legacy key's stored form displays as its Curve25519 key, as the OMEMO 2 form of the same identity does`() throws {
        let identity = OMEMOIdentityKeyPair()
        let curveKey = try identity.agreementPrivateKey().publicKey.rawRepresentation
        let legacy = omemoFingerprint(of: curveKey, format: .legacy)

        #expect(legacy == "05" + hexString(curveKey))
        #expect(omemoDisplayFingerprint(ofStoredFingerprint: legacy).filter { $0 != " " } == hexString(curveKey))
        #expect(omemoDisplayFingerprint(ofStoredFingerprint: legacy) == omemoDisplayFingerprint(
            ofStoredFingerprint: omemoFingerprint(of: identity.publicKeyBytes, format: .omemo2)
        ))
    }

    // MARK: - Admission

    enum Held: Sendable {
        case none, keyA, keyB, refused
    }

    @Test(arguments: [
        (Held.none, OMEMOTrustGuard.ExistingSession.none, OMEMOTrustGuard.Verdict.accepted),
        (.none, .key(fingerprintA), .accepted),
        (.none, .key(fingerprintB), .keyMismatch),
        (.none, .unreadable, .keyMismatch),
        (.keyA, .key(fingerprintB), .accepted),
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
        #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 1) == fingerprintA)
    }

    @Test func `A key is held only while none is, also for a device marked untrusted, and the key held from then on is returned`() {
        let device = OMEMODeviceKey(jid: peer, deviceID: 1)
        _ = trustGuard.applyDistrust(peer: peer, deviceID: 1)

        #expect(trustGuard.holdKeyIfNoneHeld("", for: device).isEmpty)
        #expect(trustGuard.holdKeyIfNoneHeld(fingerprintA, for: device) == fingerprintA)
        #expect(trustGuard.holdKeyIfNoneHeld(fingerprintB, for: device) == fingerprintA)
        #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 1) == fingerprintA)
    }

    // MARK: - Fingerprint Forms

    /// An identity's key in the stored form of `format`: its Ed25519 key for OMEMO 2, its Curve25519 key for legacy.
    private static func storedForm(of identity: OMEMOIdentityKeyPair, in format: OMEMOWireFormat) throws -> String {
        switch format {
        case .omemo2: omemoFingerprint(of: identity.publicKeyBytes, format: .omemo2)
        case .legacy: try omemoFingerprint(of: identity.agreementPrivateKey().publicKey.rawRepresentation, format: .legacy)
        }
    }

    @Test func `A key's stored forms match each other and themselves, and never another key's`() throws {
        let identity = OMEMOIdentityKeyPair()
        let other = OMEMOIdentityKeyPair()
        let forms = try [OMEMOWireFormat.omemo2, .legacy].map { try Self.storedForm(of: identity, in: $0) }
        let otherForms = try [OMEMOWireFormat.omemo2, .legacy].map { try Self.storedForm(of: other, in: $0) }

        for form in forms {
            #expect(forms.allSatisfy { OMEMOFingerprint.matches(form, $0) })
            #expect(!otherForms.contains { OMEMOFingerprint.matches(form, $0) })
        }
    }

    @Test(arguments: formlessFingerprints)
    func `A fingerprint with no Curve25519 form matches nothing, not even itself`(stored: String) {
        #expect(!OMEMOFingerprint.matches(stored, stored))
        #expect(!OMEMOFingerprint.matches(stored, fingerprintA))
        #expect(!OMEMOFingerprint.matches(fingerprintA, stored))
    }

    @Test(arguments: [OMEMOWireFormat.omemo2, .legacy])
    func `A key held in one version's form admits that key in the other's form and refuses another key, keeping the held form`(
        heldFormat: OMEMOWireFormat
    ) throws {
        let identity = OMEMOIdentityKeyPair()
        let offeredFormat: OMEMOWireFormat = heldFormat == .omemo2 ? .legacy : .omemo2
        let held = try Self.storedForm(of: identity, in: heldFormat)
        let same = try Self.storedForm(of: identity, in: offeredFormat)
        let another = try Self.storedForm(of: OMEMOIdentityKeyPair(), in: offeredFormat)
        let device = OMEMODeviceKey(jid: peer, deviceID: 1)
        let unheldDevice = OMEMODeviceKey(jid: peer, deviceID: 2)
        func admitKeyExchange(from device: OMEMODeviceKey, offering offered: String, standIn session: OMEMOTrustGuard.ExistingSession) -> OMEMOTrustGuard.Verdict {
            trustGuard.admitKeyExchange(
                from: device, offering: offered, standIn: session, preKey: OMEMOTrustGuard.PreKeyUse(id: 7, ownDeviceID: 200, isUsedByThisModule: true)
            )
        }
        mergeRow(fingerprint: held, decision: .granted)

        #expect(trustGuard.admitSession(with: device, fingerprint: same) == .accepted)
        #expect(trustGuard.admitsDecryption(from: device, fingerprint: same))
        #expect(admitKeyExchange(from: device, offering: same, standIn: .none) == .accepted)
        #expect(trustGuard.prepareGrant(peer: peer, deviceID: 1, fingerprint: same)?.fingerprint == held)
        #expect(trustGuard.admitSession(with: device, fingerprint: another) == .keyMismatch)
        #expect(!trustGuard.admitsDecryption(from: device, fingerprint: another))
        #expect(admitKeyExchange(from: device, offering: another, standIn: .none) == .keyMismatch)
        #expect(trustGuard.prepareGrant(peer: peer, deviceID: 1, fingerprint: another) == nil)
        #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 1) == held)
        #expect(admitKeyExchange(from: unheldDevice, offering: another, standIn: .key(held)) == .keyMismatch)
        #expect(admitKeyExchange(from: unheldDevice, offering: same, standIn: .key(held)) == .accepted)
        let sessionOnlyDevice = OMEMODeviceKey(jid: peer, deviceID: 3)
        #expect(trustGuard.admitSession(with: sessionOnlyDevice, fingerprint: another, standIn: .key(held)) == .keyMismatch)
        #expect(trustGuard.admitSession(with: sessionOnlyDevice, fingerprint: same, standIn: .key(held)) == .accepted)
    }

    @Test(arguments: [OMEMOWireFormat.omemo2, .legacy])
    func `A granted row naming the refused device's held key in the other version's form lifts the refusal`(heldFormat: OMEMOWireFormat) throws {
        let identity = OMEMOIdentityKeyPair()
        let held = try Self.storedForm(of: identity, in: heldFormat)
        let same = try Self.storedForm(of: identity, in: heldFormat == .omemo2 ? .legacy : .omemo2)
        mergeRow(fingerprint: held, decision: .untrusted)

        mergeRow(fingerprint: same, decision: .granted)

        #expect(trustGuard.admitSession(with: OMEMODeviceKey(jid: peer, deviceID: 1), fingerprint: held) == .accepted)
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
        let device = OMEMODeviceKey(jid: peer, deviceID: 1)
        #expect(trustGuard.admitsDecryption(from: device, fingerprint: fingerprintB))

        mergeRow(fingerprint: fingerprintA, decision: .untrusted)

        #expect(trustGuard.admitsDecryption(from: device, fingerprint: fingerprintA))
        #expect(!trustGuard.admitsDecryption(from: device, fingerprint: fingerprintB))
        #expect(!trustGuard.admitsDecryption(from: device, fingerprint: nil))
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
        #expect(!trustGuard.refuses(peer: peer, deviceID: 1))
        let decision = trustGuard.applyDistrust(peer: peer, deviceID: 1)

        mergeRow(fingerprint: fingerprintA, decision: .granted)
        #expect(trustGuard.refuses(peer: peer, deviceID: 1))
        #expect(admitSession(keyA) == .untrusted)

        trustGuard.distrustSaved(peer: peer, deviceID: 1, decision: decision)
        mergeRow(fingerprint: fingerprintA, decision: .granted)
        #expect(!trustGuard.refuses(peer: peer, deviceID: 1))
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

    /// A session reset that found the device's key changed. The store write of the new key may fail, leaving the
    /// distrust pending.
    @Test(arguments: [true, false])
    func `A replaced key refuses the device under the new key, a stored grant of the old one does not lift that, and a grant of the new one does`(
        isSaved: Bool
    ) throws {
        mergeRow(fingerprint: fingerprintA, decision: .granted)
        let decision = trustGuard.replaceHeldKey(peer: peer, deviceID: 1, fingerprint: fingerprintB)
        if isSaved {
            trustGuard.distrustSaved(peer: peer, deviceID: 1, decision: decision)
        }

        mergeRow(fingerprint: fingerprintA, decision: .granted)

        #expect(trustGuard.heldFingerprint(peer: peer, deviceID: 1) == fingerprintB)
        #expect(admitSession(keyB) == .untrusted)
        #expect(trustGuard.prepareGrant(peer: peer, deviceID: 1, fingerprint: fingerprintA) == nil)
        let grant = try #require(trustGuard.prepareGrant(peer: peer, deviceID: 1, fingerprint: fingerprintB))
        trustGuard.applyGrant(peer: peer, deviceID: 1, decision: grant.decision)
        #expect(admitSession(keyB) == .accepted)
    }
}
