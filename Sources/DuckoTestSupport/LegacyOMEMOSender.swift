import DuckoXMPP
import Testing

/// A legacy OMEMO client's device writing to one device, as Conversations writes: it starts a session from the device's
/// legacy bundle, and repeats the key exchange until the device answers.
package struct LegacyOMEMOSender {
    let deviceID: UInt32
    let recipientDeviceID: UInt32
    private(set) var session: OMEMOSession
    private static let elements = OMEMOModule(pepModule: PEPModule())

    /// `identity`'s device `deviceID`, with a session to `recipient`'s device on the first pre-key its bundle lists.
    package init(identity: OMEMOIdentityKeyPair, deviceID: UInt32, to recipient: OMEMOModule.OMEMOIdentityData) throws {
        let recipientIdentity = try OMEMOIdentityKeyPair(rawRepresentation: recipient.identityKeyRaw)
        let bundle = try OMEMOPreKeyManager.buildLegacyBundle(
            deviceID: OMEMODeviceID(value: recipient.deviceID),
            identityKeyPair: recipientIdentity,
            signedPreKey: OMEMOSignedPreKey(
                keyID: recipient.signedPreKeyID, rawRepresentation: recipient.signedPreKeyRaw, signature: recipient.signedPreKeySignature
            ),
            preKeys: recipient.preKeys.map { try OMEMOPreKey(keyID: $0.keyID, rawRepresentation: $0.keyRaw) }
        )
        let preKey = try #require(bundle.preKeys.first)
        let x3dh = try OMEMOX3DH.initiatorKeyAgreement(
            identityKeyPair: identity,
            peerBundle: OMEMOX3DHPeerBundle(
                identityKey: bundle.identityKey, signedPreKey: bundle.signedPreKey,
                signedPreKeySignature: bundle.signedPreKeySignature, oneTimePreKey: preKey.publicKey
            ),
            format: .legacy
        )
        let keyExchange = try OMEMOKeyExchangeHeader(
            preKeyID: preKey.id, signedPreKeyID: bundle.signedPreKeyID,
            identityKey: OMEMOX3DH.identityKey(of: identity, format: .legacy), ephemeralKey: x3dh.ephemeralPublicKey
        )
        self.deviceID = deviceID
        self.recipientDeviceID = recipient.deviceID
        self.session = try OMEMOSession(
            ratchet: OMEMODoubleRatchetSession(asInitiatorWithSharedSecret: x3dh.sharedSecret, peerSignedPreKey: bundle.signedPreKey, format: .legacy),
            associatedData: x3dh.associatedData,
            start: .sent(keyExchange, isConfirmed: false)
        )
    }

    /// A legacy `<encrypted>` element carrying `body`, or a key-transport element when `body` is nil.
    package mutating func encrypted(_ body: String?) throws -> XMLElement {
        let payload = try body.map { try OMEMOLegacyPayload(encrypting: $0) }
        let transport = OMEMOLegacyPayload.KeyTransport()
        let key = try session.encryptKey(payload?.keyMaterial ?? transport.keyMaterial)
        return Self.elements.buildLegacyEncryptedElement(
            keys: [Self.elements.buildLegacyKeyElement(deviceID: recipientDeviceID, data: key.data, isPreKey: key.isKex)],
            iv: payload?.iv ?? transport.iv, payload: payload?.ciphertext, senderDeviceID: deviceID
        )
    }

    /// Reads the device's legacy answer, such as the key transport that confirms the session, and returns the key
    /// material it carried.
    package mutating func read(_ encrypted: XMLElement) throws -> [UInt8] {
        let parsed = try Self.elements.parseLegacyEncryptedElement(encrypted)
        let key = try #require(parsed.keys.first { $0.rid == deviceID })
        return try session.decrypt(.legacy(OMEMOLegacyMessage(serialized: key.data)))
    }
}
