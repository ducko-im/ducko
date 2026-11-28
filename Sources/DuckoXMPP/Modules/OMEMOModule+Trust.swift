/// Checking a device's sessions against the account's trust guard: a key exchange before its session is installed, and
/// a session before it is installed, decrypts or encrypts a message.
extension OMEMOModule {
    /// Wires the account's guard in place of the module's own, so pins and used pre-keys outlive this module. A
    /// disconnect leaves it in place, since a carbon can still be decrypted while the connection is torn down.
    package func configureTrustGuard(_ trustGuard: OMEMOTrustGuard) {
        state.withLock { $0.trustGuard = trustGuard }
    }

    /// What the guard compares a key exchange or a new session in `sessionKey`'s version with while it holds no key for
    /// the device: the device's session in that version, else its session in another version, since the device has one
    /// identity key in every version.
    static func existingSession(for sessionKey: SessionKey, in sessions: [SessionKey: OMEMOSession]) -> OMEMOTrustGuard.ExistingSession {
        let session = sessions[sessionKey] ?? OMEMOWireFormat.allCases.lazy.compactMap {
            sessions[SessionKey(jid: sessionKey.jid, deviceID: sessionKey.deviceID, version: $0)]
        }.first
        guard let session else { return .none }
        return session.peerFingerprint.map { .key($0) } ?? .unreadable
    }
}

extension OMEMOTrustGuard.Verdict {
    /// Throws the error that refuses the session, for any verdict but `accepted`.
    func check() throws {
        switch self {
        case .accepted: return
        case .untrusted: throw OMEMOModuleError.untrustedDevice
        case .keyMismatch: throw OMEMOModuleError.changedIdentityKey
        case .preKeyUsed: throw OMEMOModuleError.unknownPreKey
        }
    }
}
