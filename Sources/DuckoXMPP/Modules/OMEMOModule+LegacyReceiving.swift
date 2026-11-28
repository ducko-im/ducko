/// Reading legacy OMEMO messages (XEP-0384 v0.3), whose `<encrypted>` element may stand beside an OMEMO 2 one.
extension OMEMOModule {
    /// The `<encrypted>` element a message is read from, and its version: the OMEMO 2 element when it has a key for this
    /// device or stands alone, else the legacy one. Nil when the message carries neither.
    func receivedEncryptedElement(of message: XMPPMessage) -> (element: XMLElement, version: OMEMOWireFormat)? {
        let omemo2 = message.element.child(named: "encrypted", namespace: XMPPNamespaces.omemo)
        guard let legacy = message.element.child(named: "encrypted", namespace: XMPPNamespaces.omemoLegacy) else {
            return omemo2.map { ($0, .omemo2) }
        }
        guard let omemo2, isAddressedToThisDevice(omemo2) else { return (legacy, .legacy) }
        return (omemo2, .omemo2)
    }

    private func isAddressedToThisDevice(_ encrypted: XMLElement) -> Bool {
        guard let identity = state.withLock({ $0.ownIdentity }), let header = try? parseHeader(encrypted) else { return false }
        return findKeyElement(header.element, jid: identity.connectedJID.bareJID, rid: identity.deviceID.value) != nil
    }

    func decryptIncomingLegacyMessage(_ encrypted: XMLElement, from: JID, keyExchanges: KeyExchangePolicy = .accept) throws -> DecryptionResult {
        let parsed = try parseLegacyEncryptedElement(encrypted)
        // Checked before decrypting, since a message from a device without a session fails to decrypt yet matters most.
        refreshDeviceListIfUnannounced(sender: from.bareJID, deviceID: parsed.sid, version: .legacy)
        let identity = try requireOwnIdentity()
        // The keys are not grouped by account, so the first one for this device's id is read, as the reference
        // implementation reads it.
        guard let key = parsed.keys.first(where: { $0.rid == identity.deviceID.value }) else {
            throw OMEMOModuleError.notForThisDevice
        }
        if key.isPreKey, keyExchanges == .refuse { throw KeyExchangeRefusal() }
        let sessionKey = SessionKey(jid: from.bareJID, deviceID: parsed.sid, version: .legacy)
        let transport = if key.isPreKey {
            try decryptKexKey(key.data, sessionKey: sessionKey, isLive: keyExchanges == .accept)
        } else {
            try decryptExistingSessionKey(key.data, sessionKey: sessionKey)
        }
        let body = try decryptLegacyPayload(of: parsed, keyMaterial: transport.keyMaterial)
        return DecryptionResult(content: body.map { .legacyBody($0) }, senderDeviceID: parsed.sid, needsEmptyReply: transport.needsEmptyReply)
    }

    /// Nil for a key-transport element, which only advances the session.
    private func decryptLegacyPayload(of parsed: ParsedLegacyEncrypted, keyMaterial: [UInt8]) throws -> String? {
        guard let ciphertext = parsed.payload else {
            try OMEMOLegacyPayload.KeyTransport.validate(receivedKeyMaterial: keyMaterial)
            return nil
        }
        return try OMEMOLegacyPayload(ciphertext: ciphertext, iv: parsed.iv, keyMaterial: keyMaterial).decryptBody()
    }

    /// The message as its sender wrote it: the stanza's attributes, the decrypted body, and the elements beside the
    /// payload that ask for a receipt or a marker or tell a chat state. Only the body is encrypted, so anything else
    /// beside the payload, such as a correction, retraction or reply target, could have been added by anyone on the way
    /// and is left out.
    func rebuiltLegacyMessage(_ message: XMPPMessage, body: String) -> XMPPMessage {
        let element = XMLElement(name: message.element.name, namespace: message.element.namespace, attributes: message.element.attributes)
        var rebuilt = XMPPMessage(element: element)
        rebuilt.body = body
        for case let .element(child) in message.element.children where Self.isKeptBesideLegacyPayload(child) {
            rebuilt.element.addChild(child)
        }
        return rebuilt
    }

    /// Whether `element` is a receipt request, a marker request or a chat state: the elements beside a legacy payload
    /// that a legacy message's receiver keeps and its sender puts there, since they only ask for an answer or show typing.
    package static func isKeptBesideLegacyPayload(_ element: XMLElement) -> Bool {
        switch element.namespace {
        case XMPPNamespaces.receipts: element.name == "request"
        case XMPPNamespaces.chatMarkers: element.name == "markable"
        case XMPPNamespaces.chatStates: ChatState(rawValue: element.name) != nil
        default: false
        }
    }
}
