/// What became of an OMEMO message this device received.
public enum OMEMOReceiveOutcome: Sendable {
    case decrypted(OMEMODecryptedMessage)
    case undecryptable(OMEMOUndecryptableReason)
}

/// An OMEMO message as its sender wrote it.
public struct OMEMODecryptedMessage: Sendable {
    /// The received stanza's attributes, with the envelope's content as its children. Only those children are covered by
    /// the encryption, so the received stanza's own ids, delay and hints are read from it, not from this message.
    public let message: XMPPMessage
    /// The envelope's `time` affix, for the receiver to check against the time the message was sent (XEP-0420).
    public let sentTime: String?

    public init(message: XMPPMessage, sentTime: String?) {
        self.message = message
        self.sentTime = sentTime
    }
}

/// Why an OMEMO message with content could not be read.
public enum OMEMOUndecryptableReason: Sendable, Equatable {
    case decryptionFailed
    /// The sender encrypted it for other devices only.
    case notForThisDevice
    /// The envelope names other parties than the stanza does (XEP-0420).
    case mismatchedEnvelope
    /// A key exchange from a device marked untrusted, which built no session.
    case untrustedDevice
    /// The identity key of a key exchange, or of the session a message came through, is not the one held for its device.
    /// A refused key exchange builds no session.
    case changedIdentityKey
    /// A room message from an occupant whose address the room does not reveal, so no session with them can be found.
    case senderHidden
}
