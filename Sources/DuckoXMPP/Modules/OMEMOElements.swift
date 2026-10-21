/// The XEP-0384 elements: the device list, the bundle and the `<encrypted>` message element.
extension OMEMOModule {
    struct ParsedHeader {
        let element: XMLElement
        let sid: UInt32
    }

    // MARK: - XML Parsing

    func parseDeviceList(
        _ element: XMLElement
    ) -> [UInt32] {
        element.children(named: "device").compactMap { device in
            guard let idStr = device.attribute("id"),
                  let id = UInt32(idStr)
            else { return nil }
            return id
        }
    }

    func parseBundleElement(
        _ element: XMLElement, deviceID: UInt32
    ) -> OMEMOBundle? {
        guard let spkEl = element.child(named: "spk"),
              let spkText = spkEl.textContent,
              let spkBytes = Base64.decode(spkText),
              let spkIDStr = spkEl.attribute("id"),
              let spkID = UInt32(spkIDStr), let sigText = element.child(named: "spks")?.textContent,
              let sigBytes = Base64.decode(sigText), let ikText = element.child(named: "ik")?.textContent,
              let ikBytes = Base64.decode(ikText), let prekeysEl = element.child(named: "prekeys")
        else { return nil }
        let preKeys = parsePreKeys(prekeysEl)
        return OMEMOBundle(
            deviceID: OMEMODeviceID(value: deviceID),
            identityKey: ikBytes,
            signedPreKeyID: spkID,
            signedPreKey: spkBytes,
            signedPreKeySignature: sigBytes,
            preKeys: preKeys
        )
    }

    private func parsePreKeys(
        _ element: XMLElement
    ) -> [OMEMOBundle.PreKeyPublic] {
        element.children(named: "pk").compactMap { pk in
            guard let idStr = pk.attribute("id"),
                  let id = UInt32(idStr),
                  let text = pk.textContent,
                  let bytes = Base64.decode(text)
            else { return nil }
            return OMEMOBundle.PreKeyPublic(id: id, publicKey: bytes)
        }
    }

    func parseHeader(
        _ encrypted: XMLElement
    ) throws -> ParsedHeader {
        guard let header = encrypted.child(named: "header"),
              let sidStr = header.attribute("sid"),
              let sid = UInt32(sidStr)
        else {
            throw OMEMOModuleError.invalidHeader
        }
        return ParsedHeader(element: header, sid: sid)
    }

    /// The key for device `rid` among the keys for `jid`.
    func findKeyElement(
        _ header: XMLElement, jid: BareJID, rid: UInt32
    ) -> XMLElement? {
        let ridStr = "\(rid)"
        return header.children(named: "keys")
            .filter { $0.attribute("jid").flatMap(BareJID.parse) == jid }
            .flatMap { $0.children(named: "key") }
            .first { $0.attribute("rid") == ridStr }
    }

    // MARK: - XML Building

    func buildDeviceListElement(
        _ devices: [UInt32]
    ) -> XMLElement {
        var list = XMLElement(
            name: "devices", namespace: XMPPNamespaces.omemo
        )
        for id in devices {
            let device = XMLElement(
                name: "device", attributes: ["id": "\(id)"]
            )
            list.addChild(device)
        }
        return list
    }

    func buildBundleElement(
        _ bundle: OMEMOBundle
    ) -> XMLElement {
        var bundleEl = XMLElement(
            name: "bundle", namespace: XMPPNamespaces.omemo
        )
        var spk = XMLElement(
            name: "spk",
            attributes: ["id": "\(bundle.signedPreKeyID)"]
        )
        spk.addText(Base64.encode(bundle.signedPreKey))
        bundleEl.addChild(spk)
        var sig = XMLElement(name: "spks")
        sig.addText(Base64.encode(bundle.signedPreKeySignature))
        bundleEl.addChild(sig)
        var ik = XMLElement(name: "ik")
        ik.addText(Base64.encode(bundle.identityKey))
        bundleEl.addChild(ik)
        var prekeys = XMLElement(name: "prekeys")
        for pk in bundle.preKeys {
            var pkEl = XMLElement(
                name: "pk",
                attributes: ["id": "\(pk.id)"]
            )
            pkEl.addText(Base64.encode(pk.publicKey))
            prekeys.addChild(pkEl)
        }
        bundleEl.addChild(prekeys)
        return bundleEl
    }

    /// Groups the keys under one `<keys>` element per recipient, in the order the recipients first appear. A nil
    /// `payload` makes an empty message, which carries only key material.
    func buildEncryptedElement(
        keys: [(jid: BareJID, key: XMLElement)], payload: String?,
        senderDeviceID: UInt32
    ) -> XMLElement {
        var encrypted = XMLElement(
            name: "encrypted", namespace: XMPPNamespaces.omemo
        )
        var recipients: [(jid: BareJID, keys: XMLElement)] = []
        for (jid, key) in keys {
            if let index = recipients.firstIndex(where: { $0.jid == jid }) {
                recipients[index].keys.addChild(key)
            } else {
                var keysEl = XMLElement(name: "keys", attributes: ["jid": jid.description])
                keysEl.addChild(key)
                recipients.append((jid, keysEl))
            }
        }
        var header = XMLElement(
            name: "header",
            attributes: ["sid": "\(senderDeviceID)"]
        )
        for recipient in recipients {
            header.addChild(recipient.keys)
        }
        encrypted.addChild(header)
        if let payload {
            var payloadEl = XMLElement(name: "payload")
            payloadEl.addText(payload)
            encrypted.addChild(payloadEl)
        }
        return encrypted
    }

    func buildKeyElement(
        deviceID: UInt32, data: [UInt8], isKex: Bool
    ) -> XMLElement {
        var attrs = ["rid": "\(deviceID)"]
        if isKex { attrs["kex"] = "true" }
        var key = XMLElement(name: "key", attributes: attrs)
        key.addText(Base64.encode(data))
        return key
    }

    // MARK: - Publish Options

    /// `maxItems` is a count or `max`.
    func pepPublishOptions(
        maxItems: String
    ) -> [DataFormField] {
        [
            DataFormField.pubsubPublishOptionsHeader,
            DataFormField(variable: "pubsub#persist_items", values: ["true"]),
            DataFormField(variable: "pubsub#access_model", values: ["open"]),
            DataFormField(variable: "pubsub#max_items", values: [maxItems])
        ]
    }
}
