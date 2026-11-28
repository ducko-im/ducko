import struct os.OSAllocatedUnfairLock

/// The fingerprint an identity key is stored as, which names its own form by its length: an OMEMO 2 key as the 64 hex
/// digits of its Ed25519 key, a legacy key as the 66 hex digits of its `0x05`-prefixed Curve25519 key.
package func omemoFingerprint(of identityKey: some Sequence<UInt8>, format: OMEMOWireFormat) -> String {
    hexString(format.encodedIdentityKey(Array(identityKey)))
}

/// The form XEP-0384 shows a fingerprint in: the identity key as Curve25519, in lowercase hex split into eight
/// space-separated groups of eight. A stored fingerprint that is empty or has no Curve25519 form is returned unchanged.
package func omemoDisplayFingerprint(ofStoredFingerprint hex: String) -> String {
    guard let curveKey = OMEMOFingerprint.curveKey(ofStoredFingerprint: hex) else { return hex }
    let digits = Array(hexString(curveKey))
    return stride(from: 0, to: digits.count, by: 8).map { String(digits[$0 ..< $0 + 8]) }.joined(separator: " ")
}

/// Comparing stored fingerprints, which name one identity key in the form of whichever OMEMO version showed it.
package enum OMEMOFingerprint {
    /// Whether two stored fingerprints name the same identity key, whatever form each has. A fingerprint with no
    /// Curve25519 form, an empty one included, matches nothing, not even itself.
    package static func matches(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhsKey = curveKey(ofStoredFingerprint: lhs), let rhsKey = curveKey(ofStoredFingerprint: rhs) else { return false }
        return lhsKey == rhsKey
    }

    /// The Curve25519 key a stored fingerprint names: an Ed25519 key converted, or a `0x05`-prefixed key without its
    /// prefix. Nil for any other form.
    static func curveKey(ofStoredFingerprint hex: String) -> [UInt8]? {
        guard let bytes = decodeHex(hex.utf8) else { return nil }
        switch bytes.count {
        case OMEMOCrypto.keyLength: return OMEMOCurveConversion.ed25519ToX25519(bytes)
        case OMEMOCrypto.keyLength + 1 where bytes[0] == legacyKeyType: return Array(bytes.dropFirst())
        default: return nil
        }
    }
}

/// One account's record of whose sessions it accepts, kept for the life of the process, so it outlasts each
/// connection's `OMEMOModule`. For each device it holds the identity key, pinned on first use when nothing named one,
/// and whether the device is marked untrusted. It also holds the one-time pre-keys that key exchanges used up. Each
/// check or change is one locked step that calls out to nothing.
package final class OMEMOTrustGuard: Sendable {
    /// A device's trust row as the store held it when read.
    package struct StoredTrust: Sendable {
        /// What the row records the user decided.
        package enum Decision: Sendable {
            /// No decision: a placeholder for a listed device, or a row a session filled in.
            case undecided
            /// A Trust or Verify.
            case granted
            case untrusted
        }

        package let peer: BareJID
        package let deviceID: UInt32
        /// Empty when the row holds no fingerprint.
        package let fingerprint: String
        package let decision: Decision

        package init(peer: BareJID, deviceID: UInt32, fingerprint: String, decision: Decision) {
            self.peer = peer
            self.deviceID = deviceID
            self.fingerprint = fingerprint
            self.decision = decision
        }
    }

    /// A Trust or Verify about to be saved: the decision it belongs to, and the fingerprint it certifies.
    package struct Grant: Equatable, Sendable {
        package let decision: UInt64
        package let fingerprint: String
    }

    enum Verdict: Equatable {
        case accepted
        /// The device is marked untrusted.
        case untrusted
        /// The key differs from the one held for the device or, with none held, from the key of the device's session
        /// that stands in for one. Also when a session's key could not be read.
        case keyMismatch
        /// An earlier module of this device took the pre-key up.
        case preKeyUsed
    }

    /// The one-time pre-key a key exchange names: its id among those the device `ownDeviceID` handed out, and whether the
    /// module asking used it already. That module's own record of key exchanges tells a replay, so the guard leaves its
    /// pre-keys to it.
    struct PreKeyUse {
        let id: UInt32
        let ownDeviceID: UInt32
        let isUsedByThisModule: Bool
    }

    /// The device's session whose key stands in for a held one while none is held.
    enum ExistingSession {
        case none
        /// The stored fingerprint of the session's key.
        case key(String)
        /// A session exists, but its key could not be read.
        case unreadable
    }

    private struct Entry {
        /// The held key's stored fingerprint, empty while none is held.
        var fingerprint = ""
        var isRefused = false
        /// A distrust whose save has not succeeded yet, which no stored row loosens.
        var hasPendingDistrust = false
        /// Bumped by each user decision, so a save's completion applies only while no later decision was made.
        var decisionRevision: UInt64 = 0
        /// The change counter at this entry's last change.
        var lastChange: UInt64 = 0
    }

    private struct State {
        var entries: [OMEMODeviceKey: Entry] = [:]
        var changeCounter: UInt64 = 0
        /// The pre-keys that key exchanges used up, keyed by the id of this device that handed them out.
        var usedPreKeyIDs: [UInt32: Set<UInt32>] = [:]

        func entry(_ key: OMEMODeviceKey) -> Entry {
            entries[key] ?? Entry()
        }

        mutating func record(_ entry: Entry, for key: OMEMODeviceKey) {
            changeCounter += 1
            var entry = entry
            entry.lastChange = changeCounter
            entries[key] = entry
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package init() {}

    // MARK: - Stored Trust

    /// Read before loading the rows to pass to `merge`.
    package func currentStamp() -> UInt64 {
        state.withLock { $0.changeCounter }
    }

    /// Takes in stored rows read after `stamp`. A device whose entry changed since then keeps it, so an older read
    /// cannot undo a newer change. A stored fingerprint fills an empty one but never replaces one held. An untrusted row
    /// refuses the device. A granted row whose fingerprint is empty or the held one lifts the refusal, unless a distrust
    /// is still unsaved. An undecided row never lifts one. Devices without a row keep their entries. Stores return one row
    /// per device, but rows that repeat a device anyway cannot lift a refusal one of them sets, whatever their order.
    package func merge(_ rows: [StoredTrust], loadedAfter stamp: UInt64) {
        state.withLock { state in
            // This merge's own change to a device does not make the stamp check skip the device's next row.
            var mergedNow: Set<OMEMODeviceKey> = []
            var refusedNow: Set<OMEMODeviceKey> = []
            for row in rows {
                let key = OMEMODeviceKey(jid: row.peer, deviceID: row.deviceID)
                let current = state.entry(key)
                guard current.lastChange <= stamp || mergedNow.contains(key) else { continue }
                var merged = current
                if merged.fingerprint.isEmpty {
                    merged.fingerprint = row.fingerprint
                }
                switch row.decision {
                case .untrusted:
                    merged.isRefused = true
                    refusedNow.insert(key)
                case .granted:
                    if !merged.hasPendingDistrust, !refusedNow.contains(key), row.fingerprint.isEmpty || OMEMOFingerprint.matches(row.fingerprint, merged.fingerprint) {
                        merged.isRefused = false
                    }
                case .undecided:
                    break
                }
                if merged.fingerprint != current.fingerprint || merged.isRefused != current.isRefused {
                    state.record(merged, for: key)
                    mergedNow.insert(key)
                }
            }
        }
    }

    // MARK: - Decisions

    /// Refuses the device at once, before the distrust is saved. Returns the decision to pass to `distrustSaved`.
    package func applyDistrust(peer: BareJID, deviceID: UInt32) -> UInt64 {
        distrust(OMEMODeviceKey(jid: peer, deviceID: deviceID), holding: nil)
    }

    /// Lets stored rows decide the device again once the distrust of `decision` is saved, unless a later decision was
    /// made.
    package func distrustSaved(peer: BareJID, deviceID: UInt32, decision: UInt64) {
        state.withLock { state in
            let key = OMEMODeviceKey(jid: peer, deviceID: deviceID)
            var entry = state.entry(key)
            guard entry.decisionRevision == decision else { return }
            entry.hasPendingDistrust = false
            state.record(entry, for: key)
        }
    }

    /// Settles the key a Trust or Verify certifies before it is saved: `fingerprint`, the one the user compared, or the
    /// held one when the user compared none. A compared key is held from now on when none was. Nil when another key is
    /// held.
    package func prepareGrant(peer: BareJID, deviceID: UInt32, fingerprint: String) -> Grant? {
        state.withLock { state in
            let key = OMEMODeviceKey(jid: peer, deviceID: deviceID)
            var entry = state.entry(key)
            if !fingerprint.isEmpty, !OMEMOFingerprint.matches(fingerprint, entry.fingerprint) {
                guard entry.fingerprint.isEmpty else { return nil }
                entry.fingerprint = fingerprint
                state.record(entry, for: key)
            }
            return Grant(decision: entry.decisionRevision, fingerprint: entry.fingerprint)
        }
    }

    /// Lifts the refusal once the grant of `decision` is saved, unless a later decision was made.
    package func applyGrant(peer: BareJID, deviceID: UInt32, decision: UInt64) {
        state.withLock { state in
            let key = OMEMODeviceKey(jid: peer, deviceID: deviceID)
            var entry = state.entry(key)
            guard entry.decisionRevision == decision else { return }
            entry.isRefused = false
            entry.hasPendingDistrust = false
            entry.decisionRevision += 1
            state.record(entry, for: key)
        }
    }

    /// Holds `fingerprint` for the device in place of the key held so far, and refuses the device until the user trusts
    /// the new key. The only way a held key is ever replaced, for a session reset that found the device's key changed.
    /// Returns the decision to pass to `distrustSaved` once the new key is stored as untrusted.
    package func replaceHeldKey(peer: BareJID, deviceID: UInt32, fingerprint: String) -> UInt64 {
        distrust(OMEMODeviceKey(jid: peer, deviceID: deviceID), holding: fingerprint)
    }

    /// Refuses the device until its distrust is saved, holding `fingerprint` in place of its key when one is given.
    private func distrust(_ key: OMEMODeviceKey, holding fingerprint: String?) -> UInt64 {
        state.withLock { state in
            var entry = state.entry(key)
            if let fingerprint {
                entry.fingerprint = fingerprint
            }
            entry.isRefused = true
            entry.hasPendingDistrust = true
            entry.decisionRevision += 1
            state.record(entry, for: key)
            return entry.decisionRevision
        }
    }

    /// Empty while none is held.
    package func heldFingerprint(peer: BareJID, deviceID: UInt32) -> String {
        state.withLock { $0.entry(OMEMODeviceKey(jid: peer, deviceID: deviceID)).fingerprint }
    }

    /// Whether the device is marked untrusted, including by a distrust whose save has not succeeded yet.
    package func refuses(peer: BareJID, deviceID: UInt32) -> Bool {
        refuses(OMEMODeviceKey(jid: peer, deviceID: deviceID))
    }

    /// The pre-keys of the device `ownDeviceID` that key exchanges used up in this process.
    package func consumedPreKeyIDs(ownDeviceID: UInt32) -> Set<UInt32> {
        state.withLock { $0.usedPreKeyIDs[ownDeviceID] ?? [] }
    }

    // MARK: - Admission

    /// Whether a key exchange from `device` whose key has the stored fingerprint `offered` may install its session. With
    /// no key held, the key of `standIn`, an existing session with the device, stands in for one, and with neither the key
    /// exchange is the device's first use. A pre-key another module took up is refused. An acceptance holds the key when
    /// none was held and records the pre-key. A refusal changes nothing.
    func admitKeyExchange(from device: OMEMODeviceKey, offering offered: String, standIn: ExistingSession, preKey: PreKeyUse) -> Verdict {
        state.withLock { state in
            var entry = state.entry(device)
            guard !entry.isRefused else { return .untrusted }
            guard Self.matchesKnownKey(offered, held: entry.fingerprint, standIn: standIn) else { return .keyMismatch }
            if !preKey.isUsedByThisModule, state.usedPreKeyIDs[preKey.ownDeviceID]?.contains(preKey.id) == true {
                return .preKeyUsed
            }
            state.usedPreKeyIDs[preKey.ownDeviceID, default: []].insert(preKey.id)
            if entry.fingerprint.isEmpty {
                entry.fingerprint = offered
                state.record(entry, for: device)
            }
            return .accepted
        }
    }

    /// Holds `fingerprint` for the device while no key is held, whether or not the device is marked untrusted, and
    /// returns the key held from then on. An empty one holds nothing, so it returns empty while none is held.
    func holdKeyIfNoneHeld(_ fingerprint: String, for device: OMEMODeviceKey) -> String {
        state.withLock { state in
            var entry = state.entry(device)
            guard entry.fingerprint.isEmpty, !fingerprint.isEmpty else { return entry.fingerprint }
            entry.fingerprint = fingerprint
            state.record(entry, for: device)
            return fingerprint
        }
    }

    /// Whether the device is marked untrusted.
    func refuses(_ device: OMEMODeviceKey) -> Bool {
        state.withLock { $0.entry(device).isRefused }
    }

    /// Whether a message from `device` may be decrypted through a session whose key has the stored fingerprint
    /// `fingerprint`. It may not when the key contradicts the one held, or cannot be read while one is held. A device
    /// marked untrusted still passes (XEP-0384 §8). Pins nothing.
    func admitsDecryption(from device: OMEMODeviceKey, fingerprint: String?) -> Bool {
        let held = state.withLock { $0.entry(device).fingerprint }
        return held.isEmpty || fingerprint.map { OMEMOFingerprint.matches($0, held) } == true
    }

    /// Whether a session with `device`, whose key has the stored fingerprint `fingerprint`, may be installed or encrypted
    /// with. Nil, a key that could not be read, is refused. With no key held, the key of `standIn` stands in for one, as
    /// for a key exchange. An acceptance holds the key when none was held.
    func admitSession(with device: OMEMODeviceKey, fingerprint: String?, standIn: ExistingSession = .none) -> Verdict {
        state.withLock { state in
            var entry = state.entry(device)
            guard !entry.isRefused else { return .untrusted }
            guard let fingerprint, Self.matchesKnownKey(fingerprint, held: entry.fingerprint, standIn: standIn) else { return .keyMismatch }
            if entry.fingerprint.isEmpty {
                entry.fingerprint = fingerprint
                state.record(entry, for: device)
            }
            return .accepted
        }
    }

    /// Whether `offered` names the `held` key or, with none held, the key of `standIn`. With neither, any key is the
    /// device's first.
    private static func matchesKnownKey(_ offered: String, held: String, standIn: ExistingSession) -> Bool {
        guard held.isEmpty else { return OMEMOFingerprint.matches(held, offered) }
        switch standIn {
        case .none: return true
        case let .key(fingerprint): return OMEMOFingerprint.matches(fingerprint, offered)
        case .unreadable: return false
        }
    }
}
