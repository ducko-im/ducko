import Logging

private let log = Logger(label: "im.ducko.xmpp.omemo")

/// Reading OMEMO messages (XEP-0384) and their Stanza Content Encryption envelopes (XEP-0420).
extension OMEMOModule {
    /// The key a message's `<key>` element carried, and whether its sender is owed an empty message: one that confirms
    /// a session a key exchange built, or a heartbeat.
    struct KeyTransport {
        let keyMaterial: [UInt8]
        let needsEmptyReply: Bool
    }

    struct DecryptionResult {
        /// The decrypted envelope, or nil for a message that carries only key material.
        let envelope: SCEEnvelope?
        let senderDeviceID: UInt32
        let needsEmptyReply: Bool

        var body: String? {
            envelope?.content.first { $0.name == "body" }?.textContent
        }
    }

    /// How many messages a device receives on one ratchet key before it answers with a heartbeat (XEP-0384).
    static let heartbeatThreshold: UInt32 = 53

    /// What an empty message encrypts: a key for no payload, without the payload's authentication tag.
    private static let emptyMessageKey = [UInt8](repeating: 0, count: OMEMOPayload.keyLength)

    // MARK: - Receiving

    /// Reads a live OMEMO message and reports it. A decrypted message also goes to every module's
    /// `handleDecryptedMessage`.
    func handleEncryptedMessage(_ message: XMPPMessage) {
        guard let outcome = receive(message), let context = state.withLock({ $0.context }) else { return }
        if case let .decrypted(decrypted) = outcome {
            context.dispatchDecryptedMessage(decrypted.message)
        }
        let roomAuthor = message.from.flatMap { mucModule?.roomAuthor(of: message, in: $0.bareJID) }
        context.emitEvent(.omemoEncryptedMessageReceived(message: message, outcome: outcome, roomAuthor: roomAuthor))
    }

    /// Reads the OMEMO message a carbon forwards (XEP-0280), sent by another of the user's devices or received by one.
    /// Nil for a message with nothing to show, such as one that only carries key material: it still moves the session
    /// on.
    public func receiveForwardedMessage(_ message: XMPPMessage) -> OMEMOReceiveOutcome? {
        receive(message)
    }

    /// Reads an OMEMO message an archive returned (XEP-0313). A room message, or a room's private message when
    /// `isRoomPrivateMessage`, is decrypted with the session of `sender`, the real JID the archive recorded for its
    /// author, never with the live occupant list, and shows as hidden without one. Any other message is decrypted with
    /// its stanza's sender, as live. A key exchange is taken up only when `allowsKeyExchange`, and even then never in
    /// place of a session this connection built or took up live. Nil when there is nothing to show.
    public func receiveArchivedMessage(
        _ message: XMPPMessage, sender: BareJID?, isRoomPrivateMessage: Bool, allowsKeyExchange: Bool
    ) -> OMEMOReceiveOutcome? {
        receive(message, as: .archived(sender: sender, isRoomPrivateMessage: isRoomPrivateMessage, allowsKeyExchange: allowsKeyExchange))
    }

    /// How a message reached this device.
    private enum Arrival {
        /// Live, or forwarded by a carbon.
        case live
        /// Returned by an archive, which recorded `sender` as its author's real JID.
        case archived(sender: BareJID?, isRoomPrivateMessage: Bool, allowsKeyExchange: Bool)

        var keyExchanges: KeyExchangePolicy {
            switch self {
            case .live: .accept
            case let .archived(_, _, allowsKeyExchange): allowsKeyExchange ? .acceptUnlessLive : .refuse
            }
        }
    }

    /// Nil when there is nothing to show: an error bounce, which returns a message this device sent, a replay, a key
    /// exchange `arrival` does not take up, or a message that carries only key material.
    private func receive(_ message: XMPPMessage, as arrival: Arrival = .live) -> OMEMOReceiveOutcome? {
        guard message.messageType != .error,
              let encrypted = message.element.child(named: "encrypted", namespace: XMPPNamespaces.omemo)
        else { return nil }
        let hasPayload = encrypted.child(named: "payload") != nil
        let ownJID = state.withLock { $0.context?.connectedJID()?.bareJID }
        guard let sender = decryptingSender(of: message, ownJID: ownJID, arrival: arrival) else {
            return hasPayload ? .undecryptable(.senderHidden) : nil
        }
        let result: DecryptionResult
        do {
            result = try decryptIncomingMessage(encrypted, from: .bare(sender), keyExchanges: arrival.keyExchanges)
        } catch OMEMOModuleError.replayedKeyExchange {
            // XEP-0384: a copy of a message already read is ignored, so it shows no undecryptable row either.
            log.warning("OMEMO key exchange ignored: it repeats one already taken up")
            return nil
        } catch is KeyExchangeRefusal {
            return nil
        } catch {
            let reason = undecryptableReason(for: error, from: sender)
            return hasPayload ? .undecryptable(reason) : nil
        }
        if result.needsEmptyReply {
            sendEmptyMessage(to: SessionKey(jid: sender, deviceID: result.senderDeviceID))
        }
        guard let envelope = result.envelope else {
            // A message that carries only key material has nothing to show, but it still moved the ratchet.
            state.withLock { $0.context }?.emitEvent(.omemoSessionAdvanced(jid: sender, deviceID: result.senderDeviceID))
            return nil
        }
        // XEP-0384 requires the envelope of a message sent through a room, as a room message or a room's private
        // message, to name its recipient, so a server cannot pass it off as a 1:1 message or the other way round. An
        // affix that is there has to match.
        guard envelope.to.map({ $0 == envelopeRecipient(of: message, ownJID: ownJID) }) ?? !isSentThroughRoom(message, arrival: arrival),
              envelope.from.map({ $0 == sender }) ?? true
        else {
            log.warning("OMEMO envelope names other parties than its stanza")
            return .undecryptable(.mismatchedEnvelope)
        }
        return .decrypted(OMEMODecryptedMessage(
            message: rebuiltMessage(message, content: envelope.content), sentTime: envelope.time, senderJID: sender,
            senderDeviceID: result.senderDeviceID
        ))
    }

    /// Why a message from `sender` that failed to decrypt shows a notice. Logs every failure but one not encrypted for
    /// this device.
    private func undecryptableReason(for error: any Error, from sender: BareJID) -> OMEMOUndecryptableReason {
        switch error {
        case OMEMOModuleError.notForThisDevice:
            return .notForThisDevice
        case OMEMOModuleError.untrustedDevice:
            log.warning("OMEMO key exchange refused: its device is marked as untrusted")
            log.debug("The refused key exchange came from \(sender)")
            return .untrustedDevice
        case OMEMOModuleError.changedIdentityKey:
            log.warning("OMEMO message refused: its device's identity key is not the one held for it")
            log.debug("The refused message came from \(sender)")
            return .changedIdentityKey
        case OMEMOModuleError.unknownPreKey:
            log.warning("OMEMO key exchange rejected: it names a pre-key this device does not have")
            return .decryptionFailed
        default:
            log.warning("OMEMO decryption failed: \(error)")
            return .decryptionFailed
        }
    }

    /// Whose session decrypts `message`: for a live room message or room private message the occupant's real address,
    /// for an archived one the address the archive recorded, else the stanza's sender. Nil when the room or its archive
    /// does not reveal the occupant's address.
    private func decryptingSender(of message: XMPPMessage, ownJID: BareJID?, arrival: Arrival) -> BareJID? {
        switch arrival {
        case .live:
            encryptingSender(of: message, ownJID: ownJID)
        case let .archived(sender, isRoomPrivateMessage, _):
            message.messageType == .groupchat || isRoomPrivateMessage ? sender : message.from?.bareJID ?? ownJID
        }
    }

    private func encryptingSender(of message: XMPPMessage, ownJID: BareJID?) -> BareJID? {
        guard let from = message.from else { return ownJID }
        let isGroupchat = message.messageType == .groupchat
        guard case let .full(occupant) = from, isGroupchat || mucModule?.isInRoom(occupant.bareJID) == true else {
            return isGroupchat ? nil : from.bareJID
        }
        return mucModule?.realJID(ofOccupant: occupant.resourcePart, in: occupant.bareJID)
    }

    /// Whether `message` is a room message or a room's private message, to or from an occupant. An archived message's
    /// caller tells a private message apart, since its room may not be joined.
    private func isSentThroughRoom(_ message: XMPPMessage, arrival: Arrival) -> Bool {
        if case let .archived(_, isRoomPrivateMessage, _) = arrival { return message.messageType == .groupchat || isRoomPrivateMessage }
        return message.messageType == .groupchat || [message.from, message.to].contains { jid in
            guard case let .full(occupant) = jid else { return false }
            return mucModule?.isInRoom(occupant.bareJID) == true
        }
    }

    /// Whom the envelope has to name as its recipient: the room for a room message, else the stanza's recipient.
    private func envelopeRecipient(of message: XMPPMessage, ownJID: BareJID?) -> BareJID? {
        message.messageType == .groupchat ? message.from?.bareJID : message.to?.bareJID ?? ownJID
    }

    /// The message as its sender wrote it: the stanza's attributes, with the envelope's content as its children, less
    /// the elements the envelope may not carry.
    private func rebuiltMessage(_ message: XMPPMessage, content: [XMLElement]) -> XMPPMessage {
        var element = XMLElement(name: message.element.name, namespace: message.element.namespace, attributes: message.element.attributes)
        for child in content where !Self.isForbiddenInEnvelope(child) {
            element.addChild(child)
        }
        return XMPPMessage(element: element)
    }

    /// XEP-0420 has the recipient discard the elements a server acts on, which it cannot read inside the envelope:
    /// processing hints, a stanza-id, extended addressing and an encryption hint. An occupant id is the room's to
    /// assign, so one inside the envelope is dropped too.
    private static func isForbiddenInEnvelope(_ child: XMLElement) -> Bool {
        switch child.namespace {
        case XMPPNamespaces.processingHints, XMPPNamespaces.addresses, XMPPNamespaces.eme: true
        case XMPPNamespaces.stanzaID: child.name == "stanza-id"
        case XMPPNamespaces.occupantID: child.name == "occupant-id"
        default: false
        }
    }

    // MARK: - Decryption

    /// Which key exchanges a read takes up.
    enum KeyExchangePolicy {
        /// Every one, as for a live message or a carbon.
        case accept
        /// Every one but one that would replace a session this connection built or took up live, as for an archived
        /// message read at catch-up. A session it builds does not count as live.
        case acceptUnlessLive
        /// None, as for an older archived message read back in scrollback.
        case refuse
    }

    /// A key exchange the read's `KeyExchangePolicy` does not take up.
    private struct KeyExchangeRefusal: Error {}

    func decryptIncomingMessage(_ encrypted: XMLElement, from: JID, keyExchanges: KeyExchangePolicy = .accept) throws -> DecryptionResult {
        let header = try parseHeader(encrypted)
        // Checked before decrypting, since a message from a device without a session fails to decrypt yet matters most.
        refreshDeviceListIfUnannounced(sender: from.bareJID, deviceID: header.sid)
        let identity = try requireOwnIdentity()
        guard let keyElement = findKeyElement(
            header.element, jid: identity.connectedJID.bareJID, rid: identity.deviceID.value
        ) else {
            throw OMEMOModuleError.notForThisDevice
        }
        // An XML Schema boolean.
        let isKex = ["true", "1"].contains(keyElement.attribute("kex"))
        if isKex, keyExchanges == .refuse { throw KeyExchangeRefusal() }
        guard let keyText = keyElement.textContent,
              let keyData = Base64.decode(keyText)
        else {
            throw OMEMOModuleError.invalidKeyData
        }
        let sessionKey = SessionKey(jid: from.bareJID, deviceID: header.sid)
        let transport = if isKex {
            try decryptKexKey(keyData, sessionKey: sessionKey, isLive: keyExchanges == .accept)
        } else {
            try decryptExistingSessionKey(keyData, sessionKey: sessionKey)
        }
        let envelope = try decryptPayload(encrypted, keyMaterial: transport.keyMaterial)
        return DecryptionResult(envelope: envelope, senderDeviceID: header.sid, needsEmptyReply: transport.needsEmptyReply)
    }

    /// Nil for a message without a payload, which only carries key material.
    private func decryptPayload(_ encrypted: XMLElement, keyMaterial: [UInt8]) throws -> SCEEnvelope? {
        guard let payloadText = encrypted.child(named: "payload")?.textContent else { return nil }
        guard let ciphertext = Base64.decode(payloadText) else { throw OMEMOModuleError.invalidPayload }
        return try SCEEnvelope(parsing: OMEMOPayload(ciphertext: ciphertext, keyMaterial: keyMaterial).decrypt())
    }

    // MARK: - Empty Messages

    /// Sends the device behind `sessionKey` an OMEMO message without a payload, which confirms a session it started or
    /// answers its run of messages.
    private func sendEmptyMessage(to sessionKey: SessionKey) {
        let built: (message: XMPPMessage, context: ModuleContext)?
        do {
            built = try buildEmptyMessage(to: sessionKey)
        } catch {
            log.warning("OMEMO empty message could not be encrypted: \(error)")
            return
        }
        guard let (message, context) = built else { return }
        Task {
            do {
                try await context.sendStanza(message)
            } catch {
                log.warning("OMEMO empty message could not be sent: \(error)")
            }
        }
    }

    /// Sends the device behind `sessionKey` an OMEMO message without a payload, and returns once the client took it.
    func sendEmptyMessageAwaiting(to sessionKey: SessionKey) async throws {
        guard let (message, context) = try buildEmptyMessage(to: sessionKey) else { throw OMEMOModuleError.notSetUp }
        try await context.sendStanza(message)
    }

    /// The OMEMO message without a payload for the device behind `sessionKey`, and the context to send it through. Nil
    /// when the module has no context; a missing identity throws. The session advances under one lock, so a message
    /// decrypted meanwhile cannot undo it.
    private func buildEmptyMessage(to sessionKey: SessionKey) throws -> (message: XMPPMessage, context: ModuleContext)? {
        let identity = try requireOwnIdentity()
        let built = try state.withLock { state in
            guard var session = state.sessions[sessionKey] else { throw OMEMOModuleError.noSession }
            let built = try session.encryptKey(Self.emptyMessageKey)
            state.sessions[sessionKey] = session
            return built
        }
        guard let context = state.withLock({ $0.context }) else { return nil }
        let key = buildKeyElement(deviceID: sessionKey.deviceID, data: built.data, isKex: built.isKex)
        var message = XMPPMessage(type: .chat, to: .bare(sessionKey.jid), id: context.generateID())
        message.element.addChild(buildEncryptedElement(
            keys: [(jid: sessionKey.jid, key: key)], payload: nil, senderDeviceID: identity.deviceID.value
        ))
        message.element.addChild(XMLElement(name: "store", namespace: XMPPNamespaces.processingHints))
        context.emitEvent(.omemoSessionAdvanced(jid: sessionKey.jid, deviceID: sessionKey.deviceID))
        return (message, context)
    }
}
