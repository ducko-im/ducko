/// What a manual session reset did with one of a contact's devices, or one of the account's other devices (XEP-0384).
package enum SessionResetOutcome: Equatable, Sendable {
    /// A new session was built from the device's bundle and announced with an empty key exchange.
    case rebuilt
    /// The device is marked untrusted, so its session was only discarded.
    case discarded
    /// The device's bundle carries another identity key than the one known for it, so its session was discarded.
    /// `previousFingerprint` is empty when the known key could not be read.
    case keyChanged(previousFingerprint: String, newIdentityKey: [UInt8])
    /// The device publishes no usable bundle, so its session was only discarded.
    case noBundle
}

/// Replacing a session the user no longer trusts to work (XEP-0384).
package extension OMEMOModule {
    /// This device's id, or nil while the module has no identity. A reset of the account's own devices leaves it out,
    /// since a device has no session with itself.
    var ownDeviceID: UInt32? {
        state.withLock { $0.ownIdentity?.deviceID.value }
    }

    /// Discards the session with `jid`'s device `deviceID` and, when its bundle still carries the known identity key and
    /// the device is not marked untrusted, builds a new one and sends it an empty key exchange. The known key is the one
    /// the trust guard holds, else the discarded session's. Throws when the bundle cannot be fetched for another reason
    /// than its absence, or when the empty message cannot be sent.
    func resetSession(jid: BareJID, deviceID: UInt32) async throws -> SessionResetOutcome {
        let sessionKey = SessionKey(jid: jid, deviceID: deviceID)
        await awaitIdentityIfSettingUp()
        let identity = try requireOwnIdentity()
        let bundle: OMEMOBundle
        do {
            bundle = try await fetchBundle(from: jid, deviceID: deviceID)
        } catch where Self.meansNoBundle(error) {
            discardSession(jid: jid, deviceID: deviceID)
            return .noBundle
        }
        let offered = omemoFingerprint(of: bundle.identityKey)
        let settled = state.withLock { state -> SessionResetOutcome? in
            let discarded = state.sessions.removeValue(forKey: sessionKey)
            let held = state.trustGuard.heldFingerprint(peer: jid, deviceID: deviceID)
            let known: String? = if !held.isEmpty {
                held
            } else {
                // A session whose key cannot be read counts as one with another key.
                discarded.map { $0.peerIdentityKey.map { omemoFingerprint(of: $0) } ?? "" }
            }
            if let known, known != offered {
                return .keyChanged(previousFingerprint: known, newIdentityKey: bundle.identityKey)
            }
            return state.trustGuard.refuses(sessionKey) ? .discarded : nil
        }
        if let settled { return settled }
        do {
            _ = try establishSession(sessionKey: sessionKey, identity: identity, bundle: bundle)
        } catch OMEMOModuleError.bundleNotFound {
            return .noBundle
        }
        try await sendEmptyMessageAwaiting(to: sessionKey)
        return .rebuilt
    }

    /// Discards the session with `jid`'s device `deviceID` without building a new one, as for a device no longer on its
    /// list.
    func discardSession(jid: BareJID, deviceID: UInt32) {
        state.withLock { _ = $0.sessions.removeValue(forKey: SessionKey(jid: jid, deviceID: deviceID)) }
    }

    private static func meansNoBundle(_ error: any Error) -> Bool {
        switch error {
        case OMEMOModuleError.bundleNotFound: true
        case let stanzaError as XMPPStanzaError: stanzaError.condition == .itemNotFound
        default: false
        }
    }
}
