import DuckoTestSupport
@testable import DuckoXMPP

/// The time the test helpers stamp on the envelopes they encrypt.
let testEnvelopeTime = "2026-01-01T00:00:00Z"

extension OMEMOModule {
    /// Encrypts a message whose envelope carries only `plaintext` as its body.
    func encryptMessage(
        plaintext: String, to recipientJID: BareJID, recipientDeviceIDs: [UInt32]? = nil, ownDeviceIDs: [UInt32]? = nil
    ) async throws -> EncryptedMessageElements {
        try await encryptMessage(
            content: [bodyElement(plaintext)], legacyBody: plaintext, time: testEnvelopeTime, to: recipientJID,
            recipientDeviceIDs: recipientDeviceIDs, ownDeviceIDs: ownDeviceIDs
        )
    }

    func encryptGroupMessage(
        plaintext: String, roomJID: BareJID, recipients: [(jid: BareJID, deviceIDs: [UInt32])], ownDeviceIDs: [UInt32]? = nil
    ) async throws -> EncryptedMessageElements {
        try await encryptGroupMessage(
            content: [bodyElement(plaintext)], legacyBody: plaintext, time: testEnvelopeTime, roomJID: roomJID, recipients: recipients, ownDeviceIDs: ownDeviceIDs
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
    guard case let .omemoEncryptedMessageReceived(_, .decrypted(decrypted), _) = event else { return nil }
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

/// The `<pubsub>` answer to `iq` when it fetches a device list in `version`, listing `devices`, and nil for any other
/// request.
func deviceListItems(_ devices: [UInt32], answering iq: XMLElement, in version: OMEMOWireFormat = .omemo2) -> XMLElement? {
    let module = OMEMOModule(pepModule: PEPModule())
    let (node, list) = switch version {
    case .omemo2: (XMPPNamespaces.omemoDevices, module.buildDeviceListElement(devices))
    case .legacy: (XMPPNamespaces.omemoLegacyDeviceList, module.buildLegacyDeviceListElement(devices))
    }
    guard iq.child(named: "pubsub")?.child(named: "items")?.attribute("node") == node else { return nil }
    var item = XMLElement(name: "item", attributes: ["id": "current"])
    item.addChild(list)
    var items = XMLElement(name: "items", attributes: ["node": node])
    items.addChild(item)
    var pubsub = XMLElement(name: "pubsub", namespace: XMPPNamespaces.pubsub)
    pubsub.addChild(items)
    return pubsub
}

/// Answers each legacy OMEMO request `mock` sends as a server holding no legacy nodes would: a read with no items, and
/// a publish with success. A new device reads the legacy list before it takes an id, and publishes for legacy OMEMO once
/// its setup completes.
func answerLegacyRequests(on mock: MockTransport) async {
    await mock.autoReply { stanza in
        guard stanza.hasPrefix("<iq "), stanza.contains(XMPPNamespaces.omemoLegacy), let id = extractIQID(from: stanza) else { return nil }
        return "<iq type=\"result\" id=\"\(id)\"/>"
    }
}

extension OMEMOTrustGuard {
    /// Takes in one stored row for `peer`'s device, read now unless `stamp` says when, as the service merges the rows
    /// it loads.
    func mergeRow(
        peer: BareJID, deviceID: UInt32, fingerprint: String, decision: StoredTrust.Decision, loadedAfter stamp: UInt64? = nil
    ) {
        merge(
            [StoredTrust(peer: peer, deviceID: deviceID, fingerprint: fingerprint, decision: decision)],
            loadedAfter: stamp ?? currentStamp()
        )
    }
}

/// The fingerprint of a newly generated identity key, which no test identity has.
func unrelatedFingerprint() -> String {
    omemoFingerprint(of: OMEMOIdentityKeyPair().publicKeyBytes, format: .omemo2)
}

extension OMEMOModule.OMEMOIdentityData {
    /// The same keys, with `preKeys` as the one-time pre-keys, as a later connection loads only the unused ones.
    func withPreKeys(_ preKeys: [PreKeyData]) -> Self {
        Self(
            deviceID: deviceID, identityKeyRaw: identityKeyRaw, signedPreKeyID: signedPreKeyID,
            signedPreKeyRaw: signedPreKeyRaw, signedPreKeySignature: signedPreKeySignature, preKeys: preKeys
        )
    }
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
