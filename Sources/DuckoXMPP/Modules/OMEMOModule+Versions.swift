/// Sending each recipient device the newest OMEMO version it lists (XEP-0384): OMEMO 2 to a device on its owner's
/// OMEMO 2 list, legacy OMEMO to one only on the legacy list. A message carries one `<encrypted>` element for each
/// version a device receives it in. The OMEMO 2 element holds the whole envelope (XEP-0420), the legacy one the body
/// alone, under a key of its own.
extension OMEMOModule {
    /// Encrypts a 1:1 message's `content`, the elements it would carry in the clear, sent at `time` (XEP-0082), and
    /// `legacyBody`, the body of `content`, for the devices that receive it as legacy OMEMO. A nil `legacyBody` leaves
    /// those devices out, as a device without a bundle is left out. `recipientDeviceIDs`/`ownDeviceIDs` nil means every
    /// device on either list.
    public func encryptMessage(
        content: [XMLElement],
        legacyBody: String?,
        time: String,
        to recipientJID: BareJID,
        recipientDeviceIDs: [UInt32]? = nil,
        ownDeviceIDs: [UInt32]? = nil
    ) async throws -> EncryptedMessageElements {
        let recipientDevices: [UInt32] = if let recipientDeviceIDs {
            recipientDeviceIDs
        } else {
            try await fetchListedDevices(of: recipientJID)
        }
        return try await encryptForDevices(
            OutgoingMessage(content: content, legacyBody: legacyBody, time: time, conversation: recipientJID),
            peerDevices: recipientDevices.map { (jid: recipientJID, deviceID: $0) },
            ownDeviceIDs: ownDeviceIDs
        )
    }

    /// Encrypts a group message's `content` and `legacyBody`, sent at `time`, as `encryptMessage` does. `roomJID` labels
    /// emitted `omemoRecipientsPartial` events for correlation. A legacy element lists its keys by device alone.
    public func encryptGroupMessage(
        content: [XMLElement],
        legacyBody: String?,
        time: String,
        roomJID: BareJID,
        recipients: [(jid: BareJID, deviceIDs: [UInt32])],
        ownDeviceIDs: [UInt32]? = nil
    ) async throws -> EncryptedMessageElements {
        let peerDevices = recipients.flatMap { r in r.deviceIDs.map { (jid: r.jid, deviceID: $0) } }
        return try await encryptForDevices(
            OutgoingMessage(content: content, legacyBody: legacyBody, time: time, conversation: roomJID),
            peerDevices: peerDevices,
            ownDeviceIDs: ownDeviceIDs
        )
    }

    /// The devices on either of `jid`'s lists, each once, OMEMO 2 ones first, each list fetched as `fetchDeviceList`
    /// fetches it with `forceRefresh`. Throws when either list cannot be read, since a message would then miss the
    /// devices on it.
    public func fetchListedDevices(of jid: BareJID, forceRefresh: Bool = false) async throws -> [UInt32] {
        let omemo2 = try await fetchDeviceList(for: jid, forceRefresh: forceRefresh, version: .omemo2)
        let legacy = try await fetchDeviceList(for: jid, forceRefresh: forceRefresh, version: .legacy)
        var seen: Set<UInt32> = []
        return (omemo2 + legacy).filter { seen.insert($0).inserted }
    }

    /// The versions whose list of `jid`, as last fetched or notified, holds each of its devices.
    public func listedVersions(of jid: BareJID) -> [UInt32: Set<OMEMOWireFormat>] {
        let deviceLists = state.withLock { $0.deviceLists }
        var versions: [UInt32: Set<OMEMOWireFormat>] = [:]
        for version in OMEMOWireFormat.allCases {
            for deviceID in deviceLists[version]?[jid] ?? [] {
                versions[deviceID, default: []].insert(version)
            }
        }
        return versions
    }

    /// A message to encrypt: its envelope's `content` and `legacyBody`, sent at `time`.
    private struct OutgoingMessage {
        let content: [XMLElement]
        let legacyBody: String?
        let time: String
        /// The peer or the room, which the envelope names as its recipient and which labels emitted
        /// `omemoRecipientsPartial` events.
        let conversation: BareJID
    }

    /// Shared encrypt pipeline. Throws `noUsableRecipientDevices` when no peer device of either version receives a key,
    /// since an empty list or all-missing bundles would otherwise look like a silent drop. A peer device receives none
    /// when its bundle is missing, when it receives legacy OMEMO and the message has no legacy body, or when it leaves
    /// its list while keys are wrapped. The account's own devices never stand in for a peer.
    private func encryptForDevices(
        _ message: OutgoingMessage,
        peerDevices: [(jid: BareJID, deviceID: UInt32)],
        ownDeviceIDs: [UInt32]?
    ) async throws -> EncryptedMessageElements {
        let conversation = message.conversation
        await awaitIdentityIfSettingUp()
        do {
            let identity = try requireOwnIdentity()
            var payloads: [OMEMOWireFormat: MessagePayload] = [:]
            let peerEncryption = try await encryptKeys(of: message, payloads: &payloads, for: peerDevices, identity: identity)
            guard peerEncryption.hasKeys else {
                // Emitted before throwing, which would otherwise hide the
                // dropped devices, so the worst case reports them as partial
                // coverage does.
                emitDroppedRecipientsEventIfNeeded(conversation: conversation, dropped: peerEncryption.dropped)
                throw OMEMOModuleError.noUsableRecipientDevices
            }
            let ownDevices = try await otherOwnDevices(ownDeviceIDs, identity: identity)
            let ownEncryption = try await encryptKeys(of: message, payloads: &payloads, for: ownDevices, identity: identity)
            // A device-list notification can remove a device while bundles are fetched, also once its key is wrapped.
            let deviceLists = state.withLock { $0.deviceLists }
            let listedPeers = peerEncryption.keepingDevices(listedIn: deviceLists)
            let listedOwn = ownEncryption.keepingDevices(listedIn: deviceLists)
            let droppedRecipients = listedPeers.dropped + listedOwn.dropped
            guard listedPeers.hasKeys else {
                emitDroppedRecipientsEventIfNeeded(conversation: conversation, dropped: droppedRecipients)
                throw OMEMOModuleError.noUsableRecipientDevices
            }
            let encrypted = payloads.compactMapValues { payload in
                let keys = listedPeers.results(in: payload.version) + listedOwn.results(in: payload.version)
                return keys.isEmpty ? nil : encryptedElement(keys: keys, payload: payload, senderDeviceID: identity.deviceID.value)
            }
            emitDroppedRecipientsEventIfNeeded(conversation: conversation, dropped: droppedRecipients)
            return EncryptedMessageElements(
                omemo2Encrypted: encrypted[.omemo2],
                legacyEncrypted: encrypted[.legacy],
                encryption: encryptionElement(naming: encrypted[.omemo2] == nil ? .legacy : .omemo2),
                droppedRecipients: droppedRecipients
            )
        } catch {
            throw OMEMOModuleError.translatingCryptoFailure(error)
        }
    }

    /// What a message's `<encrypted>` element carries in one version: the whole envelope in OMEMO 2, the body alone in
    /// legacy OMEMO.
    private enum MessagePayload {
        case omemo2(OMEMOPayload)
        case legacy(OMEMOLegacyPayload)

        var version: OMEMOWireFormat {
            switch self {
            case .omemo2: .omemo2
            case .legacy: .legacy
            }
        }

        var keyMaterial: [UInt8] {
            switch self {
            case let .omemo2(payload): payload.keyMaterial
            case let .legacy(payload): payload.keyMaterial
            }
        }
    }

    /// Wraps the key material of `message`'s payload for each of `devices` in the version it receives the message in. A
    /// device whose version has no payload is dropped.
    private func encryptKeys(
        of message: OutgoingMessage, payloads: inout [OMEMOWireFormat: MessagePayload],
        for devices: [(jid: BareJID, deviceID: UInt32)], identity: OwnIdentity
    ) async throws -> VersionedEncryption {
        var encryption = VersionedEncryption()
        for (version, versionDevices) in receivingVersions(of: devices) {
            encryption.batches[version] = if let payload = try messagePayload(in: version, of: message, identity: identity, payloads: &payloads) {
                try await encryptKeysInParallel(
                    keyMaterial: payload.keyMaterial, identity: identity, devices: versionDevices, version: version
                )
            } else {
                EncryptionBatch(results: [], dropped: versionDevices.map { DroppedOMEMORecipient(jid: $0.jid, deviceID: $0.deviceID) })
            }
        }
        return encryption
    }

    /// `message`'s payload in `version`, encrypted the first time a device receiving the message in that version needs
    /// it and kept in `payloads` for the devices after it, so a version no device receives encrypts nothing. Nil in
    /// legacy OMEMO for a message without a legacy body.
    private func messagePayload(
        in version: OMEMOWireFormat, of message: OutgoingMessage, identity: OwnIdentity,
        payloads: inout [OMEMOWireFormat: MessagePayload]
    ) throws -> MessagePayload? {
        if let payload = payloads[version] { return payload }
        let payload: MessagePayload? = switch version {
        case .omemo2:
            try .omemo2(OMEMOPayload(
                encrypting: SCEEnvelope.build(
                    content: message.content, time: message.time, to: message.conversation, from: identity.connectedJID.bareJID
                ),
                key: randomBytes(OMEMOPayload.keyLength)
            ))
        case .legacy:
            try message.legacyBody.map { try .legacy(OMEMOLegacyPayload(encrypting: $0)) }
        }
        payloads[version] = payload
        return payload
    }

    /// `devices` by the version each receives a message in: legacy OMEMO for a device only its owner's legacy list holds,
    /// OMEMO 2 for any other.
    private func receivingVersions(
        of devices: [(jid: BareJID, deviceID: UInt32)]
    ) -> [(OMEMOWireFormat, [(jid: BareJID, deviceID: UInt32)])] {
        let deviceLists = state.withLock { $0.deviceLists }
        let grouped = Dictionary(grouping: devices) { device -> OMEMOWireFormat in
            let isListed = { (version: OMEMOWireFormat) in deviceLists[version]?[device.jid]?.contains(device.deviceID) == true }
            return !isListed(.omemo2) && isListed(.legacy) ? .legacy : .omemo2
        }
        return OMEMOWireFormat.allCases.compactMap { version in grouped[version].map { (version, $0) } }
    }

    /// The account's devices but this one: `ownDeviceIDs`, or every device on either of the account's lists when nil.
    private func otherOwnDevices(
        _ ownDeviceIDs: [UInt32]?, identity: OwnIdentity
    ) async throws -> [(jid: BareJID, deviceID: UInt32)] {
        let ownJID = identity.connectedJID.bareJID
        let ownDevices: [UInt32] = if let ownDeviceIDs {
            ownDeviceIDs
        } else {
            try await fetchListedDevices(of: ownJID)
        }
        return ownDevices.filter { $0 != identity.deviceID.value }.map { (jid: ownJID, deviceID: $0) }
    }

    private func encryptedElement(keys: [EncryptionResult], payload: MessagePayload, senderDeviceID: UInt32) -> XMLElement {
        switch payload {
        case let .omemo2(payload):
            buildEncryptedElement(
                keys: keys.map { (jid: $0.sessionKey.jid, key: $0.keyElement) }, payload: Base64.encode(payload.ciphertext),
                senderDeviceID: senderDeviceID
            )
        case let .legacy(payload):
            buildLegacyEncryptedElement(
                keys: keys.map(\.keyElement), iv: payload.iv, payload: payload.ciphertext, senderDeviceID: senderDeviceID
            )
        }
    }

    private func encryptionElement(naming version: OMEMOWireFormat) -> XMLElement {
        let namespace = switch version {
        case .omemo2: XMPPNamespaces.omemo
        case .legacy: XMPPNamespaces.omemoLegacy
        }
        return XMLElement(name: "encryption", namespace: XMPPNamespaces.eme, attributes: ["namespace": namespace])
    }

    private func emitDroppedRecipientsEventIfNeeded(
        conversation: BareJID, dropped: [DroppedOMEMORecipient]
    ) {
        guard !dropped.isEmpty else { return }
        let context = state.withLock { $0.context }
        context?.emitEvent(.omemoRecipientsPartial(conversation: conversation, droppedDevices: dropped))
    }
}

extension OMEMOModule {
    /// A message's wrapped keys, in the batch of the version each device receives it in.
    struct VersionedEncryption {
        var batches: [OMEMOWireFormat: EncryptionBatch] = [:]

        /// Whether any device of either version receives a key.
        var hasKeys: Bool {
            batches.values.contains { !$0.results.isEmpty }
        }

        var dropped: [DroppedOMEMORecipient] {
            OMEMOWireFormat.allCases.flatMap { batches[$0]?.dropped ?? [] }
        }

        func results(in version: OMEMOWireFormat) -> [EncryptionResult] {
            batches[version]?.results ?? []
        }

        /// Each version's batch without the devices that version's list in `deviceLists` leaves out.
        func keepingDevices(listedIn deviceLists: [OMEMOWireFormat: [BareJID: [UInt32]]]) -> Self {
            Self(batches: Dictionary(uniqueKeysWithValues: batches.map { version, batch in
                (version, batch.keepingDevices(listedIn: deviceLists[version] ?? [:]))
            }))
        }
    }
}
