import struct os.OSAllocatedUnfairLock

/// The fingerprint an identity key shows as: its bytes in lowercase hex.
package func omemoFingerprint(of identityKey: some Sequence<UInt8>) -> String {
    hexString(identityKey)
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
        /// The key differs from the one held for the device or, with none held, from the key of the session a key
        /// exchange would replace. Also when a session's key could not be read.
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

    /// The session with a device that a key exchange would replace.
    enum ExistingSession {
        case none
        case key([UInt8])
        /// A session exists, but its key could not be read.
        case unreadable
    }

    private struct Entry {
        /// Empty while none is held.
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
        var entries: [SessionKey: Entry] = [:]
        var changeCounter: UInt64 = 0
        /// The pre-keys that key exchanges used up, keyed by the id of this device that handed them out.
        var usedPreKeyIDs: [UInt32: Set<UInt32>] = [:]

        func entry(_ key: SessionKey) -> Entry {
            entries[key] ?? Entry()
        }

        mutating func record(_ entry: Entry, for key: SessionKey) {
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
            var mergedNow: Set<SessionKey> = []
            var refusedNow: Set<SessionKey> = []
            for row in rows {
                let key = SessionKey(jid: row.peer, deviceID: row.deviceID)
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
                    if !merged.hasPendingDistrust, !refusedNow.contains(key), row.fingerprint.isEmpty || row.fingerprint == merged.fingerprint {
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
        state.withLock { state in
            let key = SessionKey(jid: peer, deviceID: deviceID)
            var entry = state.entry(key)
            entry.isRefused = true
            entry.hasPendingDistrust = true
            entry.decisionRevision += 1
            state.record(entry, for: key)
            return entry.decisionRevision
        }
    }

    /// Lets stored rows decide the device again once the distrust of `decision` is saved, unless a later decision was
    /// made.
    package func distrustSaved(peer: BareJID, deviceID: UInt32, decision: UInt64) {
        state.withLock { state in
            let key = SessionKey(jid: peer, deviceID: deviceID)
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
            let key = SessionKey(jid: peer, deviceID: deviceID)
            var entry = state.entry(key)
            if !fingerprint.isEmpty, fingerprint != entry.fingerprint {
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
            let key = SessionKey(jid: peer, deviceID: deviceID)
            var entry = state.entry(key)
            guard entry.decisionRevision == decision else { return }
            entry.isRefused = false
            entry.hasPendingDistrust = false
            entry.decisionRevision += 1
            state.record(entry, for: key)
        }
    }

    /// Empty while none is held.
    package func heldFingerprint(peer: BareJID, deviceID: UInt32) -> String {
        state.withLock { $0.entry(SessionKey(jid: peer, deviceID: deviceID)).fingerprint }
    }

    /// The pre-keys of the device `ownDeviceID` that key exchanges used up in this process.
    package func consumedPreKeyIDs(ownDeviceID: UInt32) -> Set<UInt32> {
        state.withLock { $0.usedPreKeyIDs[ownDeviceID] ?? [] }
    }

    // MARK: - Admission

    /// Whether a key exchange from `device` signed with `offeredKey` may install its session. With no key held, the
    /// existing session's key stands in for one, and with neither the key exchange is the device's first use. A pre-key
    /// another module took up is refused. An acceptance holds the key when none was held and records the pre-key. A
    /// refusal changes nothing.
    func admitKeyExchange(from device: SessionKey, offeredKey: [UInt8], replacing session: ExistingSession, preKey: PreKeyUse) -> Verdict {
        state.withLock { state in
            var entry = state.entry(device)
            guard !entry.isRefused else { return .untrusted }
            let offered = omemoFingerprint(of: offeredKey)
            if entry.fingerprint.isEmpty {
                switch session {
                case .none: break
                case let .key(sessionKey): guard sessionKey == offeredKey else { return .keyMismatch }
                case .unreadable: return .keyMismatch
                }
            } else if entry.fingerprint != offered {
                return .keyMismatch
            }
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

    /// Whether a message from `device` may be decrypted through a session whose key is `identityKey`. It may not when the
    /// key contradicts the one held, or cannot be read while one is held. A device marked untrusted still passes
    /// (XEP-0384 §8). Pins nothing.
    func admitsDecryption(from device: SessionKey, identityKey: [UInt8]?) -> Bool {
        let held = state.withLock { $0.entry(device).fingerprint }
        return held.isEmpty || identityKey.map { omemoFingerprint(of: $0) == held } == true
    }

    /// Whether a session with `device`, whose key is `identityKey`, may be installed or encrypted with. Nil, a key that
    /// could not be read, is refused. An acceptance holds the key when none was held.
    func admitSession(with device: SessionKey, identityKey: [UInt8]?) -> Verdict {
        state.withLock { state in
            var entry = state.entry(device)
            guard !entry.isRefused else { return .untrusted }
            guard let identityKey else { return .keyMismatch }
            let fingerprint = omemoFingerprint(of: identityKey)
            if entry.fingerprint.isEmpty {
                entry.fingerprint = fingerprint
                state.record(entry, for: device)
            } else if entry.fingerprint != fingerprint {
                return .keyMismatch
            }
            return .accepted
        }
    }
}
