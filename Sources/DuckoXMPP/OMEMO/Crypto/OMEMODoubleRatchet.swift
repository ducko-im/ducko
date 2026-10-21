import CryptoKit

/// Double Ratchet session state for OMEMO. Value type — callers serialize mutating encrypt/decrypt.
struct OMEMODoubleRatchetSession {
    /// Our current DH ratchet key pair (sending).
    var dhSendKeyPair: Curve25519.KeyAgreement.PrivateKey
    /// Cached public key bytes from `dhSendKeyPair`, recomputed only on ratchet step.
    var dhSendPublicKeyBytes: [UInt8]
    /// Peer's current DH ratchet public key (receiving), `nil` for responder before first message.
    var dhRecvPublicKey: [UInt8]?
    /// Root key (32 bytes).
    var rootKey: [UInt8]
    /// Sending chain key (32 bytes), `nil` until first send after DH ratchet.
    var sendChainKey: [UInt8]?
    /// Receiving chain key (32 bytes), `nil` until first receive.
    var recvChainKey: [UInt8]?
    /// Number of messages sent in the current sending chain.
    var sendMessageNumber: UInt32 = 0
    /// Number of messages received in the current receiving chain.
    var recvMessageNumber: UInt32 = 0
    /// Number of messages sent in the previous sending chain.
    var previousSendCount: UInt32 = 0
    /// Skipped message keys for out-of-order delivery.
    var skippedMessageKeys: [SkippedKeyID: [UInt8]] = [:]
    /// Insertion order for FIFO eviction of skipped keys.
    var skippedKeyOrder: [SkippedKeyID] = []

    /// Maximum number of skipped message keys to store.
    static let maxSkippedMessages = 1000

    // MARK: - Initialization

    /// X3DH initiator (Alice). `peerSignedPreKey` becomes initial DHr; `sharedSecret` is the 32-byte X3DH output.
    init(
        asInitiatorWithSharedSecret sharedSecret: [UInt8],
        peerSignedPreKey: [UInt8]
    ) throws {
        self.dhSendKeyPair = Curve25519.KeyAgreement.PrivateKey()
        self.dhSendPublicKeyBytes = Array(dhSendKeyPair.publicKey.rawRepresentation)
        self.dhRecvPublicKey = peerSignedPreKey
        self.rootKey = sharedSecret

        // Perform initial root key ratchet
        let peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerSignedPreKey)
        let dhOutput = try OMEMOCrypto.dh(privateKey: dhSendKeyPair, publicKey: peerPublicKey)
        let rk = OMEMOCrypto.kdfRK(rootKey: rootKey, dhOutput: dhOutput)
        self.rootKey = rk.rootKey
        self.sendChainKey = rk.chainKey
    }

    /// X3DH responder (Bob). `ourSignedPreKeyPair` becomes initial DHs; recv chain stays nil until first inbound message.
    init(
        asResponderWithSharedSecret sharedSecret: [UInt8],
        ourSignedPreKeyPair: Curve25519.KeyAgreement.PrivateKey
    ) {
        self.dhSendKeyPair = ourSignedPreKeyPair
        self.dhSendPublicKeyBytes = Array(ourSignedPreKeyPair.publicKey.rawRepresentation)
        self.dhRecvPublicKey = nil
        self.rootKey = sharedSecret
        self.sendChainKey = nil
        self.recvChainKey = nil
    }

    // MARK: - Encryption

    /// Encrypts and advances the sending chain. `associatedData` must match the X3DH AD (64 bytes).
    mutating func encrypt(
        plaintext: [UInt8],
        associatedData: [UInt8]
    ) throws -> OMEMOAuthenticatedMessage {
        guard let ck = sendChainKey else {
            throw OMEMOCryptoError.sessionNotInitialized
        }

        let ckResult = OMEMOCrypto.kdfCK(chainKey: ck)
        sendChainKey = ckResult.chainKey

        let messageNumber = sendMessageNumber
        sendMessageNumber += 1

        return try OMEMOMessageCrypto.encrypt(
            plaintext: plaintext,
            messageKey: ckResult.messageKey,
            associatedData: associatedData
        ) { ciphertext in
            OMEMOMessage(
                messageNumber: messageNumber,
                previousChainCount: previousSendCount,
                dhPublicKey: dhSendPublicKeyBytes,
                ciphertext: ciphertext
            )
        }
    }

    // MARK: - Decryption

    /// Decrypts and advances the receiving chain; performs a DH ratchet step when `dhPublicKey` is new. Rolls back on auth failure.
    mutating func decrypt(
        message authenticatedMessage: OMEMOAuthenticatedMessage,
        associatedData: [UInt8]
    ) throws -> [UInt8] {
        let message = authenticatedMessage.message

        // 1. Try skipped message keys first
        if let plaintext = try trySkippedMessageKey(authenticatedMessage, associatedData: associatedData) {
            return plaintext
        }

        // Snapshot state before advancing — rollback if authentication fails,
        // preventing a forged/corrupted packet from desynchronizing the session.
        let snapshot = self

        // 2. DH ratchet step if we received a new ratchet key
        if message.dhPublicKey != dhRecvPublicKey {
            try skipMessageKeys(until: message.previousChainCount)
            try dhRatchetStep(peerPublicKey: message.dhPublicKey)
        }

        // 3. Skip to the correct message number
        try skipMessageKeys(until: message.messageNumber)

        // 4. Advance the receiving chain
        guard let ck = recvChainKey else {
            throw OMEMOCryptoError.sessionNotInitialized
        }
        let ckResult = OMEMOCrypto.kdfCK(chainKey: ck)
        recvChainKey = ckResult.chainKey
        recvMessageNumber += 1

        // 5. Decrypt and verify — rollback on auth failure
        do {
            return try OMEMOMessageCrypto.decrypt(
                authenticatedMessage,
                messageKey: ckResult.messageKey,
                associatedData: associatedData
            )
        } catch {
            self = snapshot
            throw error
        }
    }

    // MARK: - Private Ratchet Operations

    /// Attempts decryption using a previously skipped message key.
    private mutating func trySkippedMessageKey(
        _ authenticatedMessage: OMEMOAuthenticatedMessage,
        associatedData: [UInt8]
    ) throws -> [UInt8]? {
        let keyID = SkippedKeyID(
            publicKey: authenticatedMessage.message.dhPublicKey,
            messageNumber: authenticatedMessage.message.messageNumber
        )

        guard let messageKey = skippedMessageKeys[keyID] else {
            return nil
        }

        // Decrypt BEFORE removing the key — if HMAC verification fails, the key
        // is preserved for retrying with the genuine (non-corrupted) message.
        let plaintext = try OMEMOMessageCrypto.decrypt(
            authenticatedMessage,
            messageKey: messageKey,
            associatedData: associatedData
        )

        skippedMessageKeys.removeValue(forKey: keyID)
        skippedKeyOrder.removeAll { $0 == keyID }

        return plaintext
    }

    /// Advances skipped message keys for out-of-order delivery.
    private mutating func skipMessageKeys(until target: UInt32) throws {
        guard let ck = recvChainKey else { return }

        let toSkip = Int(target) - Int(recvMessageNumber)
        guard toSkip >= 0 else { return }
        guard toSkip <= Self.maxSkippedMessages else {
            throw OMEMOCryptoError.tooManySkippedMessages
        }

        var chainKey = ck
        for _ in recvMessageNumber ..< target {
            let result = OMEMOCrypto.kdfCK(chainKey: chainKey)
            let keyID = SkippedKeyID(publicKey: dhRecvPublicKey ?? [], messageNumber: recvMessageNumber)

            storeSkippedKey(id: keyID, messageKey: result.messageKey)
            chainKey = result.chainKey
            recvMessageNumber += 1
        }
        recvChainKey = chainKey
    }

    /// Stores a skipped message key, evicting the oldest if over the limit.
    private mutating func storeSkippedKey(id: SkippedKeyID, messageKey: [UInt8]) {
        skippedMessageKeys[id] = messageKey
        skippedKeyOrder.append(id)

        // FIFO eviction
        while skippedMessageKeys.count > Self.maxSkippedMessages {
            let oldest = skippedKeyOrder.removeFirst()
            skippedMessageKeys.removeValue(forKey: oldest)
        }
    }

    /// Performs a DH ratchet step when a new peer public key is received.
    private mutating func dhRatchetStep(peerPublicKey: [UInt8]) throws {
        previousSendCount = sendMessageNumber
        sendMessageNumber = 0
        recvMessageNumber = 0
        dhRecvPublicKey = peerPublicKey

        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)

        // Derive receiving chain key
        let dhRecv = try OMEMOCrypto.dh(privateKey: dhSendKeyPair, publicKey: peerKey)
        let rkRecv = OMEMOCrypto.kdfRK(rootKey: rootKey, dhOutput: dhRecv)
        rootKey = rkRecv.rootKey
        recvChainKey = rkRecv.chainKey

        // Generate new sending key pair and derive sending chain key
        dhSendKeyPair = Curve25519.KeyAgreement.PrivateKey()
        dhSendPublicKeyBytes = Array(dhSendKeyPair.publicKey.rawRepresentation)
        let dhSend = try OMEMOCrypto.dh(privateKey: dhSendKeyPair, publicKey: peerKey)
        let rkSend = OMEMOCrypto.kdfRK(rootKey: rootKey, dhOutput: dhSend)
        rootKey = rkSend.rootKey
        sendChainKey = rkSend.chainKey
    }

    // MARK: - Serialization

    /// Serializes the session state to bytes for persistent storage.
    func serialize() -> [UInt8] {
        var writer = OMEMORecordWriter()

        writer.append(dhSendKeyPair.rawRepresentation)

        if let recvKey = dhRecvPublicKey {
            writer.append(UInt32(recvKey.count))
            writer.append(recvKey)
        } else {
            writer.append(UInt32(0))
        }

        writer.append(rootKey)

        appendOptionalKey(sendChainKey, to: &writer)
        appendOptionalKey(recvChainKey, to: &writer)

        writer.append(sendMessageNumber)
        writer.append(recvMessageNumber)
        writer.append(previousSendCount)

        writer.append(UInt32(skippedKeyOrder.count))
        for keyID in skippedKeyOrder {
            writer.append(keyID.publicKey)
            writer.append(keyID.messageNumber)
            if let messageKey = skippedMessageKeys[keyID] {
                writer.append(messageKey)
            }
        }

        return writer.bytes
    }

    /// Restores a session from previously serialized bytes, which must hold nothing else.
    init(serialized bytes: [UInt8]) throws {
        var reader = OMEMORecordReader(bytes)

        self.dhSendKeyPair = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: reader.read(OMEMOCrypto.keyLength))
        self.dhSendPublicKeyBytes = Array(dhSendKeyPair.publicKey.rawRepresentation)

        let recvKeyLen = try reader.readUInt32()
        self.dhRecvPublicKey = recvKeyLen > 0 ? try reader.read(Int(recvKeyLen)) : nil

        self.rootKey = try reader.read(OMEMOCrypto.keyLength)

        self.sendChainKey = try reader.readByte() != 0 ? reader.read(OMEMOCrypto.keyLength) : nil
        self.recvChainKey = try reader.readByte() != 0 ? reader.read(OMEMOCrypto.keyLength) : nil

        self.sendMessageNumber = try reader.readUInt32()
        self.recvMessageNumber = try reader.readUInt32()
        self.previousSendCount = try reader.readUInt32()

        let skippedCount = try reader.readUInt32()
        self.skippedMessageKeys = [:]
        self.skippedKeyOrder = []
        for _ in 0 ..< skippedCount {
            let keyID = try SkippedKeyID(publicKey: reader.read(OMEMOCrypto.keyLength), messageNumber: reader.readUInt32())
            skippedMessageKeys[keyID] = try reader.read(OMEMOCrypto.keyLength)
            skippedKeyOrder.append(keyID)
        }
        guard reader.isAtEnd else { throw OMEMOModuleError.invalidKeyData }
    }

    // MARK: - Serialization Helpers

    private func appendOptionalKey(_ key: [UInt8]?, to writer: inout OMEMORecordWriter) {
        if let key {
            writer.append(UInt8(1))
            writer.append(key)
        } else {
            writer.append(UInt8(0))
        }
    }
}

// MARK: - Supporting Types

/// Identifier for a skipped message key: (ratchet public key, message number).
struct SkippedKeyID: Hashable {
    let publicKey: [UInt8]
    let messageNumber: UInt32

    func hash(into hasher: inout Hasher) {
        hasher.combine(publicKey)
        hasher.combine(messageNumber)
    }
}
