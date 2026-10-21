@testable import DuckoXMPP

/// The time the test helpers stamp on the envelopes they encrypt.
let testEnvelopeTime = "2026-01-01T00:00:00Z"

extension OMEMOModule {
    /// Encrypts a message whose envelope carries only `plaintext` as its body.
    func encryptMessage(
        plaintext: String, to recipientJID: BareJID, recipientDeviceIDs: [UInt32]? = nil, ownDeviceIDs: [UInt32]? = nil
    ) async throws -> EncryptedMessageElements {
        try await encryptMessage(
            content: [bodyElement(plaintext)], time: testEnvelopeTime, to: recipientJID,
            recipientDeviceIDs: recipientDeviceIDs, ownDeviceIDs: ownDeviceIDs
        )
    }

    func encryptGroupMessage(
        plaintext: String, roomJID: BareJID, recipients: [(jid: BareJID, deviceIDs: [UInt32])], ownDeviceIDs: [UInt32]? = nil
    ) async throws -> EncryptedMessageElements {
        try await encryptGroupMessage(
            content: [bodyElement(plaintext)], time: testEnvelopeTime, roomJID: roomJID, recipients: recipients, ownDeviceIDs: ownDeviceIDs
        )
    }
}

func bodyElement(_ text: String) -> XMLElement {
    var body = XMLElement(name: "body")
    body.addText(text)
    return body
}

/// The decrypted message an encrypted-message event reports, or nil for one that could not be decrypted.
func decryptedMessage(of event: XMPPEvent) -> XMPPMessage? {
    guard case let .omemoEncryptedMessageReceived(_, .decrypted(decrypted)) = event else { return nil }
    return decrypted.message
}

/// Whether the first key `encrypted` carries is a key exchange.
func isKeyExchange(_ encrypted: XMLElement) -> Bool {
    encrypted.child(named: "header")?.child(named: "keys")?.children(named: "key").first?.attribute("kex") == "true"
}

/// A module talking through `context`, with `identity` installed as an established session installs it.
func makeInstalledOMEMOModule(
    identity: OMEMOModule.OMEMOIdentityData, context: ModuleContext, mucModule: MUCModule? = nil
) -> OMEMOModule {
    let pepModule = PEPModule()
    pepModule.setUp(context)
    let module = OMEMOModule(pepModule: pepModule, mucModule: mucModule)
    module.setUp(context)
    module.configureIdentity(identity)
    module.handleSessionEstablished(resumed: true)
    return module
}

extension OMEMO2Fixtures.Device {
    /// The device's keys, as Ducko stores them.
    var identityData: OMEMOModule.OMEMOIdentityData {
        OMEMOModule.OMEMOIdentityData(
            deviceID: deviceID,
            identityKeyRaw: Array(identityKey.seed),
            signedPreKeyID: signedPreKey.id,
            signedPreKeyRaw: Array(signedPreKey.privateKey),
            signedPreKeySignature: Array(signedPreKey.signature),
            preKeys: preKeys.map { .init(keyID: $0.id, keyRaw: Array($0.privateKey)) }
        )
    }

    func restoredIdentityKey() throws -> OMEMOIdentityKeyPair {
        try OMEMOIdentityKeyPair(rawRepresentation: Array(identityKey.seed))
    }

    func restoredSignedPreKey() throws -> OMEMOSignedPreKey {
        try OMEMOSignedPreKey(
            keyID: signedPreKey.id, rawRepresentation: Array(signedPreKey.privateKey), signature: Array(signedPreKey.signature)
        )
    }

    func restoredPreKeys() throws -> [OMEMOPreKey] {
        try preKeys.map { try OMEMOPreKey(keyID: $0.id, rawRepresentation: Array($0.privateKey)) }
    }
}
