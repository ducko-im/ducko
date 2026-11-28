/// What a manual session reset did with one version of one of a contact's devices, or of one of the account's other
/// devices (XEP-0384).
package enum SessionResetOutcome: Equatable, Sendable {
    /// A new session was built from the device's bundle and announced with an empty key exchange.
    case rebuilt
    /// The device is marked untrusted, so its session was only discarded.
    case discarded
    /// The device's bundle carries another identity key than the one known for it, so its session was discarded. Both
    /// are stored fingerprints, `newFingerprint` in the form of the bundle's version, and `previousFingerprint` is empty
    /// when the known key could not be read.
    case keyChanged(previousFingerprint: String, newFingerprint: String)
    /// The device publishes no usable bundle, so its session was only discarded. A bundle whose signed pre-key signature
    /// does not verify counts as none.
    case noBundle
    /// The device's bundle carries the known identity key but lists no pre-key to build a session with, so its session
    /// was only discarded.
    case noPreKeys
}

/// What a manual session reset did with one device (XEP-0384). It discarded the device's sessions in every version, and
/// installed a new one in each of `replacedVersions`.
package struct SessionReset: Sendable {
    /// Each version's outcome. A version whose new session could not be built or announced has none.
    package var outcomes: [OMEMOWireFormat: SessionResetOutcome] = [:]
    /// The versions a new session was installed in, announced or not. Each other version has no session from the reset.
    package var replacedVersions: Set<OMEMOWireFormat> = []
    /// The stored fingerprint of the key the device is known by, which the trust guard holds. Empty when no key is known
    /// or no discarded session's key could be read.
    package var knownFingerprint = ""
    /// Whether a version's bundle carries the known key, its signed pre-key signature verifying. While one does, another
    /// key replaces nothing.
    package var carriesKnownKey = false
    /// The first error a version's new session could not be built or announced with.
    package var failure: (any Error)?
}

/// Replacing a session the user no longer trusts to work (XEP-0384).
package extension OMEMOModule {
    /// This device's id, or nil while the module has no identity. A reset of the account's own devices leaves it out,
    /// since a device has no session with itself.
    var ownDeviceID: UInt32? {
        state.withLock { $0.ownIdentity?.deviceID.value }
    }

    /// Exports the session in `version` with `jid`'s device `deviceID`, reading under one lock whether the module still
    /// has its identity, so a session the disconnect dropped never reads as one the module holds none in. Throws
    /// `notSetUp` once the identity is gone.
    func exportSessionRequiringIdentity(jid: BareJID, deviceID: UInt32, version: OMEMOWireFormat) throws -> StoredSessionEntry? {
        try state.withLock { state in
            guard state.ownIdentity != nil else { throw OMEMOModuleError.notSetUp }
            return Self.storedEntry(SessionKey(jid: jid, deviceID: deviceID, version: version), in: state.sessions)
        }
    }

    /// Discards the sessions with `jid`'s device `deviceID` in every version. For each of `versions` whose bundle
    /// verifies, carries the known identity key and lists a pre-key, it then builds a new session and sends it an empty
    /// key exchange, unless the device is marked untrusted. With no versions it only discards, as for a device no
    /// longer on its list.
    ///
    /// The known key is the one the trust guard holds. With none held, it is a discarded session's key that can be
    /// read, or, when no session was discarded, the key of the first fetched bundle whose signature verifies. The guard
    /// holds that key from then on, so it outlasts the discarded sessions, and a version whose bundle carries another
    /// key never replaces a key another version still carries.
    ///
    /// Throws, discarding nothing, when the module has no identity or a bundle cannot be fetched for another reason
    /// than its absence. A version whose session cannot be built or announced does not stop the others. The first such
    /// failure is reported beside what the reset did.
    func resetSession(jid: BareJID, deviceID: UInt32, versions: [OMEMOWireFormat]) async throws -> SessionReset {
        await awaitIdentityIfSettingUp()
        let identity = try requireOwnIdentity()
        var unfetched: [OMEMOWireFormat: SessionResetOutcome] = [:]
        var candidates: [ResetCandidate] = []
        for version in versions {
            do {
                try await candidates.append(ResetCandidate(version: version, bundle: fetchBundle(from: jid, deviceID: deviceID, version: version)))
            } catch where Self.meansNoBundle(error) {
                unfetched[version] = .noBundle
            }
        }
        var (rebuilding, reset) = try settleReset(of: OMEMODeviceKey(jid: jid, deviceID: deviceID), candidates: candidates)
        reset.outcomes.merge(unfetched) { $1 }
        for candidate in rebuilding {
            let sessionKey = SessionKey(jid: jid, deviceID: deviceID, version: candidate.version)
            do {
                _ = try establishSession(sessionKey: sessionKey, identity: identity, bundle: candidate.bundle)
                reset.replacedVersions.insert(candidate.version)
                try await sendEmptyMessageAwaiting(to: sessionKey)
                reset.outcomes[candidate.version] = .rebuilt
            } catch {
                reset.failure = reset.failure ?? error
            }
        }
        return reset
    }

    /// A version's bundle fetched for a reset, the stored fingerprint of its key, and whether its signed pre-key
    /// signature verifies, which a bundle that copies another device's identity key cannot make it do.
    private struct ResetCandidate {
        let version: OMEMOWireFormat
        let bundle: OMEMOBundle
        let fingerprint: String
        let isSigned: Bool

        init(version: OMEMOWireFormat, bundle: OMEMOBundle) {
            self.version = version
            self.bundle = bundle
            self.fingerprint = omemoFingerprint(of: bundle.identityKey, format: version)
            self.isSigned = (try? OMEMOX3DH.verifySignedPreKey(
                signedPreKeyPublic: bundle.signedPreKey, signature: bundle.signedPreKeySignature, identityKey: bundle.identityKey, format: version
            )) == true
        }
    }

    /// Discards `device`'s sessions in every version, and settles which of the `candidates` a new session is built from:
    /// each whose signature verifies, carrying the known key and listing a pre-key while the device is not marked
    /// untrusted. The others have their outcome, and one whose signature does not verify counts as no bundle whatever
    /// key it carries. Throws, discarding nothing, when the module lost its identity, as a disconnect meanwhile leaves it.
    private func settleReset(of device: OMEMODeviceKey, candidates: [ResetCandidate]) throws -> (rebuilding: [ResetCandidate], reset: SessionReset) {
        try state.withLock { state in
            guard state.ownIdentity != nil else { throw OMEMOModuleError.notSetUp }
            let discarded = OMEMOWireFormat.allCases.compactMap { state.sessions[SessionKey(jid: device.jid, deviceID: device.deviceID, version: $0)] }
            state.sessions = state.sessions.filter { $0.key.device != device }
            // With none held, discarded sessions whose keys cannot be read leave the key unknown, so every bundle's key
            // is then a change.
            let readable = discarded.lazy.compactMap(\.peerFingerprint).first
            let proposed = readable ?? (discarded.isEmpty ? candidates.first(where: \.isSigned)?.fingerprint : nil)
            let held = state.trustGuard.holdKeyIfNoneHeld(proposed ?? "", for: device)
            let known: String? = held.isEmpty && discarded.isEmpty ? nil : held
            let isRefused = state.trustGuard.refuses(device)
            var rebuilding: [ResetCandidate] = []
            var reset = SessionReset(knownFingerprint: known ?? "")
            for candidate in candidates {
                if !candidate.isSigned {
                    reset.outcomes[candidate.version] = .noBundle
                } else if let known, !OMEMOFingerprint.matches(known, candidate.fingerprint) {
                    reset.outcomes[candidate.version] = .keyChanged(previousFingerprint: known, newFingerprint: candidate.fingerprint)
                } else {
                    reset.carriesKnownKey = true
                    if isRefused {
                        reset.outcomes[candidate.version] = .discarded
                    } else if candidate.bundle.preKeys.isEmpty {
                        reset.outcomes[candidate.version] = .noPreKeys
                    } else {
                        rebuilding.append(candidate)
                    }
                }
            }
            return (rebuilding, reset)
        }
    }

    private static func meansNoBundle(_ error: any Error) -> Bool {
        switch error {
        case OMEMOModuleError.bundleNotFound: true
        case let stanzaError as XMPPStanzaError: stanzaError.condition == .itemNotFound
        default: false
        }
    }
}
