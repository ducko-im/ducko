/// The legacy XEP-0384 (v0.3) elements: the device list, the bundle and the `<encrypted>` message element. Their keys
/// travel after libsignal's `0x05` type byte, which parsing strips and building adds. A legacy device list's entries
/// read as an OMEMO 2 one's do, so `parseDeviceList` parses both.
extension OMEMOModule {
    /// A legacy `<encrypted>` element. Its keys are listed flat by device, without grouping by account.
    package struct ParsedLegacyEncrypted: Equatable {
        package struct Key: Equatable {
            package let rid: UInt32
            /// The serialized `OMEMOLegacyKeyExchange` when `isPreKey`, else the serialized `OMEMOLegacyMessage`.
            package let data: [UInt8]
            let isPreKey: Bool
        }

        let sid: UInt32
        package let keys: [Key]
        let iv: [UInt8]
        /// The ciphertext, or nil for a key-transport element, which has no `<payload>`.
        let payload: [UInt8]?
    }

    // MARK: - XML Parsing

    /// The bundle with its keys without the `0x05` type byte. Nil when the identity key or the signed pre-key lacks it
    /// or is not 32 bytes after it. A pre-key with either fault is left out, as an OMEMO 2 bundle's unreadable
    /// pre-key is.
    func parseLegacyBundleElement(
        _ element: XMLElement, deviceID: UInt32
    ) -> OMEMOBundle? {
        guard let spkEl = element.child(named: "signedPreKeyPublic"),
              let spkBytes = Self.legacyKey(inText: spkEl.textContent),
              let spkIDStr = spkEl.attribute("signedPreKeyId"),
              let spkID = UInt32(spkIDStr), let sigText = element.child(named: "signedPreKeySignature")?.textContent,
              let sigBytes = Base64.decode(sigText),
              let ikBytes = Self.legacyKey(inText: element.child(named: "identityKey")?.textContent),
              let prekeysEl = element.child(named: "prekeys")
        else { return nil }
        let preKeys = parseLegacyPreKeys(prekeysEl)
        return OMEMOBundle(
            deviceID: OMEMODeviceID(value: deviceID),
            identityKey: ikBytes,
            signedPreKeyID: spkID,
            signedPreKey: spkBytes,
            signedPreKeySignature: sigBytes,
            preKeys: preKeys
        )
    }

    private func parseLegacyPreKeys(
        _ element: XMLElement
    ) -> [OMEMOBundle.PreKeyPublic] {
        element.children(named: "preKeyPublic").compactMap { pk in
            guard let idStr = pk.attribute("preKeyId"),
                  let id = UInt32(idStr),
                  let bytes = Self.legacyKey(inText: pk.textContent)
            else { return nil }
            return OMEMOBundle.PreKeyPublic(id: id, publicKey: bytes)
        }
    }

    /// Throws `invalidHeader` for a missing or non-numeric `sid` or `rid`, a missing `<iv>` or an unknown `prekey`
    /// value, `invalidKeyData` for a key or IV that is empty or not base64, and `invalidPayload` for a `<payload>` that
    /// holds no base64 ciphertext. An empty `<payload/>` is malformed, not a key transport.
    package func parseLegacyEncryptedElement(
        _ encrypted: XMLElement
    ) throws -> ParsedLegacyEncrypted {
        guard let header = encrypted.child(named: "header"),
              let sidStr = header.attribute("sid"),
              let sid = UInt32(sidStr),
              let ivEl = header.child(named: "iv")
        else {
            throw OMEMOModuleError.invalidHeader
        }
        guard let iv = Self.nonEmptyBase64(ivEl.textContent) else { throw OMEMOModuleError.invalidKeyData }
        let keys = try header.children(named: "key").map(parseLegacyKey)
        let payload: [UInt8]?
        if let payloadEl = encrypted.child(named: "payload") {
            guard let ciphertext = Self.nonEmptyBase64(payloadEl.textContent) else { throw OMEMOModuleError.invalidPayload }
            payload = ciphertext
        } else {
            payload = nil
        }
        return ParsedLegacyEncrypted(sid: sid, keys: keys, iv: iv, payload: payload)
    }

    private func parseLegacyKey(
        _ key: XMLElement
    ) throws -> ParsedLegacyEncrypted.Key {
        guard let ridStr = key.attribute("rid"),
              let rid = UInt32(ridStr)
        else { throw OMEMOModuleError.invalidHeader }
        // An XML Schema boolean, which clients write as `true` or `1`.
        let isPreKey: Bool
        switch key.attribute("prekey") {
        case nil, "false"?, "0"?: isPreKey = false
        case "true"?, "1"?: isPreKey = true
        case .some: throw OMEMOModuleError.invalidHeader
        }
        guard let data = Self.nonEmptyBase64(key.textContent) else { throw OMEMOModuleError.invalidKeyData }
        return ParsedLegacyEncrypted.Key(rid: rid, data: data, isPreKey: isPreKey)
    }

    // MARK: - XML Building

    func buildLegacyDeviceListElement(
        _ devices: [UInt32]
    ) -> XMLElement {
        var list = XMLElement(
            name: "list", namespace: XMPPNamespaces.omemoLegacy
        )
        for id in devices {
            let device = XMLElement(
                name: "device", attributes: ["id": "\(id)"]
            )
            list.addChild(device)
        }
        return list
    }

    func buildLegacyBundleElement(
        _ bundle: OMEMOBundle
    ) -> XMLElement {
        var bundleEl = XMLElement(
            name: "bundle", namespace: XMPPNamespaces.omemoLegacy
        )
        var spk = XMLElement(
            name: "signedPreKeyPublic",
            attributes: ["signedPreKeyId": "\(bundle.signedPreKeyID)"]
        )
        spk.addText(Self.legacyKeyText(bundle.signedPreKey))
        bundleEl.addChild(spk)
        var sig = XMLElement(name: "signedPreKeySignature")
        sig.addText(Base64.encode(bundle.signedPreKeySignature))
        bundleEl.addChild(sig)
        var ik = XMLElement(name: "identityKey")
        ik.addText(Self.legacyKeyText(bundle.identityKey))
        bundleEl.addChild(ik)
        var prekeys = XMLElement(name: "prekeys")
        for pk in bundle.preKeys {
            var pkEl = XMLElement(
                name: "preKeyPublic",
                attributes: ["preKeyId": "\(pk.id)"]
            )
            pkEl.addText(Self.legacyKeyText(pk.publicKey))
            prekeys.addChild(pkEl)
        }
        bundleEl.addChild(prekeys)
        return bundleEl
    }

    /// A nil `payload` makes a key-transport element.
    package func buildLegacyEncryptedElement(
        keys: [XMLElement], iv: [UInt8], payload: [UInt8]?,
        senderDeviceID: UInt32
    ) -> XMLElement {
        var encrypted = XMLElement(
            name: "encrypted", namespace: XMPPNamespaces.omemoLegacy
        )
        var header = XMLElement(
            name: "header",
            attributes: ["sid": "\(senderDeviceID)"]
        )
        for key in keys {
            header.addChild(key)
        }
        var ivEl = XMLElement(name: "iv")
        ivEl.addText(Base64.encode(iv))
        header.addChild(ivEl)
        encrypted.addChild(header)
        if let payload {
            var payloadEl = XMLElement(name: "payload")
            payloadEl.addText(Base64.encode(payload))
            encrypted.addChild(payloadEl)
        }
        return encrypted
    }

    package func buildLegacyKeyElement(
        deviceID: UInt32, data: [UInt8], isPreKey: Bool
    ) -> XMLElement {
        var attrs = ["rid": "\(deviceID)"]
        if isPreKey { attrs["prekey"] = "true" }
        var key = XMLElement(name: "key", attributes: attrs)
        key.addText(Base64.encode(data))
        return key
    }

    /// The `<key>` element in `version`'s form, `isKex` marking a key exchange.
    func keyElement(deviceID: UInt32, data: [UInt8], isKex: Bool, version: OMEMOWireFormat) -> XMLElement {
        switch version {
        case .omemo2: buildKeyElement(deviceID: deviceID, data: data, isKex: isKex)
        case .legacy: buildLegacyKeyElement(deviceID: deviceID, data: data, isPreKey: isKex)
        }
    }

    // MARK: - Key Encoding

    private static func legacyKeyText(_ key: [UInt8]) -> String {
        Base64.encode([legacyKeyType] + key)
    }

    /// The 32-byte key that `text` encodes after the `0x05` type byte, or nil when it is anything else.
    private static func legacyKey(inText text: String?) -> [UInt8]? {
        guard let text, let bytes = Base64.decode(text),
              bytes.count == OMEMOCrypto.keyLength + 1, bytes[0] == legacyKeyType
        else { return nil }
        return Array(bytes.dropFirst())
    }

    private static func nonEmptyBase64(_ text: String?) -> [UInt8]? {
        guard let text, let bytes = Base64.decode(text), !bytes.isEmpty else { return nil }
        return bytes
    }
}

package extension OMEMOPreKeyManager {
    /// Builds a publishable legacy bundle from local key material: the identity's Curve25519 key, and a fresh legacy
    /// signature over the signed pre-key, since only the OMEMO 2 one is stored.
    static func buildLegacyBundle(
        deviceID: OMEMODeviceID,
        identityKeyPair: OMEMOIdentityKeyPair,
        signedPreKey: OMEMOSignedPreKey,
        preKeys: [OMEMOPreKey]
    ) throws -> OMEMOBundle {
        try OMEMOBundle(
            deviceID: deviceID,
            identityKey: OMEMOX3DH.identityKey(of: identityKeyPair, format: .legacy),
            signedPreKeyID: signedPreKey.keyID,
            signedPreKey: signedPreKey.publicKeyBytes,
            signedPreKeySignature: OMEMOLegacySignature.sign(signedPreKey: signedPreKey.publicKeyBytes, with: identityKeyPair),
            preKeys: preKeys.map { OMEMOBundle.PreKeyPublic(id: $0.keyID, publicKey: $0.publicKeyBytes) }
        )
    }
}
