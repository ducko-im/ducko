/// Rotating the signed pre-key while key exchanges that name an older one still succeed (XEP-0384).
package extension OMEMOModule {
    /// Replaces the signed pre-key this device publishes and the older ones it still takes key exchanges for. Nothing is
    /// published here: a new current key leaves the bundle needing a publish, which the next upkeep run makes.
    func installSignedPreKeys(
        current: OMEMOIdentityData.SignedPreKeyData, retained: [OMEMOIdentityData.SignedPreKeyData]
    ) throws {
        let currentKey = try OMEMOSignedPreKey(current)
        let retainedKeys = try retained.map(OMEMOSignedPreKey.init)
        state.withLock { state in
            state.ownIdentity?.signedPreKey = currentKey
            state.ownIdentity?.retainedSignedPreKeys = retainedKeys
        }
    }
}

extension OwnIdentity {
    /// The held signed pre-key with `keyID`, the current one or a retained one.
    func signedPreKey(withID keyID: UInt32) -> OMEMOSignedPreKey? {
        ([signedPreKey] + retainedSignedPreKeys).first { $0.keyID == keyID }
    }
}

extension OMEMOSignedPreKey {
    init(_ data: OMEMOModule.OMEMOIdentityData.SignedPreKeyData) throws {
        try self.init(keyID: data.keyID, rawRepresentation: data.keyRaw, signature: data.signature)
    }

    var identityData: OMEMOModule.OMEMOIdentityData.SignedPreKeyData {
        OMEMOModule.OMEMOIdentityData.SignedPreKeyData(keyID: keyID, keyRaw: rawRepresentation, signature: signature)
    }
}
