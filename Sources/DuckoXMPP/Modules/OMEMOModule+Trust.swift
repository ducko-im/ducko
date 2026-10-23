/// Checking a device's sessions against the account's trust guard: a key exchange before its session is installed, and
/// a session before it is installed, decrypts or encrypts a message.
extension OMEMOModule {
    /// Wires the account's guard in place of the module's own, so pins and used pre-keys outlive this module. A
    /// disconnect leaves it in place, since a carbon can still be decrypted while the connection is torn down.
    package func configureTrustGuard(_ trustGuard: OMEMOTrustGuard) {
        state.withLock { $0.trustGuard = trustGuard }
    }

    /// What the guard compares a key exchange with: the key of the session it would replace.
    static func existingSession(_ session: OMEMOSession?) -> OMEMOTrustGuard.ExistingSession {
        guard let session else { return .none }
        return session.peerIdentityKey.map { .key($0) } ?? .unreadable
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
