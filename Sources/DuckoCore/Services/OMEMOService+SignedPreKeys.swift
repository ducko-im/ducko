import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.omemo")

/// Signed pre-key rotation (XEP-0384). The app and the CLI can run on one profile at the same time, so each run first
/// takes up the keys another process stored, and a rotation deletes only keys older than the one it replaces.
extension OMEMOService {
    /// How long a signed pre-key stays current, and how long it is still taken up after it was replaced.
    static let signedPreKeyRotationPeriod: TimeInterval = 7 * 24 * 60 * 60
    /// The ids a signed pre-key can take, positive integers up to 2^31 - 1 (XEP-0384 §5.3.2).
    static let signedPreKeyIDs: ClosedRange<UInt32> = 1 ... 0x7FFF_FFFF

    /// Gives the module the stored signed pre-keys when they differ from the ones it holds, as after another process
    /// rotated. Otherwise replaces the current key once it is a rotation period old. A new current key leaves the bundle
    /// needing a publish, which the caller makes.
    func maintainSignedPreKeys(accountJID: String, module: any OMEMOPreKeyMaintaining, identityData: OMEMOModule.OMEMOIdentityData) async {
        let stored: [OMEMOStoredSignedPreKey]
        do {
            stored = try await storedSignedPreKeys(accountJID: accountJID, identityData: identityData)
        } catch {
            log.warning("Could not read the OMEMO signed pre-keys for upkeep")
            log.debug("Could not read the OMEMO signed pre-keys for upkeep: \(error)")
            return
        }
        let storedIDs = Set(stored.map(\.keyID))
        guard storedIDs == Set([identityData.signedPreKeyID] + identityData.retainedSignedPreKeys.map(\.keyID)) else {
            installSignedPreKeys(newestFirst: stored, into: module)
            return
        }
        let replaced = stored[0]
        guard Date().timeIntervalSince(replaced.timestamp) >= Self.signedPreKeyRotationPeriod else { return }

        var keyID = UInt32.random(in: Self.signedPreKeyIDs)
        while storedIDs.contains(keyID) {
            keyID = UInt32.random(in: Self.signedPreKeyIDs)
        }
        let newKey: OMEMOStoredSignedPreKey
        do {
            let generated = try OMEMOPreKeyManager.generateSignedPreKeyData(keyID: keyID, identityKeyRaw: identityData.identityKeyRaw)
            newKey = OMEMOStoredSignedPreKey(
                accountJID: accountJID, keyID: keyID,
                keyData: Data(generated.keyRaw), signature: Data(generated.signature), timestamp: Date()
            )
            try await omemoStore.saveSignedPreKey(newKey)
        } catch {
            log.warning("Could not store a new OMEMO signed pre-key")
            log.debug("Could not store a new OMEMO signed pre-key: \(error)")
            return
        }
        // A key another process stored as new as the replaced one, or newer, may be the one the server advertises.
        installSignedPreKeys(newestFirst: [newKey] + stored.filter { $0.timestamp >= replaced.timestamp }, into: module)
        log.info("Rotated the OMEMO signed pre-key")
        do {
            try await omemoStore.deleteSignedPreKeys(for: accountJID, olderThan: replaced.timestamp)
        } catch {
            log.warning("Could not delete the expired OMEMO signed pre-keys")
            log.debug("Could not delete the expired OMEMO signed pre-keys: \(error)")
        }
    }

    /// The account's stored signed pre-keys, newest first. When none is stored, as when first-time persistence stored the
    /// identity but not its signed pre-key, the module's current key is stored and returned.
    private func storedSignedPreKeys(accountJID: String, identityData: OMEMOModule.OMEMOIdentityData) async throws -> [OMEMOStoredSignedPreKey] {
        let stored = try await omemoStore.loadSignedPreKeys(for: accountJID)
        guard stored.isEmpty else { return stored }
        let current = OMEMOStoredSignedPreKey(
            accountJID: accountJID, keyID: identityData.signedPreKeyID,
            keyData: Data(identityData.signedPreKeyRaw), signature: Data(identityData.signedPreKeySignature), timestamp: Date()
        )
        try await omemoStore.saveSignedPreKey(current)
        return [current]
    }

    private func installSignedPreKeys(newestFirst keys: [OMEMOStoredSignedPreKey], into module: any OMEMOPreKeyMaintaining) {
        do {
            try module.installSignedPreKeys(current: keys[0].identityData, retained: keys.dropFirst().map(\.identityData))
        } catch {
            log.warning("Could not install the stored OMEMO signed pre-keys")
            log.debug("Could not install the stored OMEMO signed pre-keys: \(error)")
        }
    }
}

extension OMEMOStoredSignedPreKey {
    var identityData: OMEMOModule.OMEMOIdentityData.SignedPreKeyData {
        OMEMOModule.OMEMOIdentityData.SignedPreKeyData(keyID: keyID, keyRaw: Array(keyData), signature: Array(signature))
    }
}
