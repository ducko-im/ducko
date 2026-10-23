/// The X3DH values an `OMEMOKeyExchange` carries around its first message.
struct OMEMOKeyExchangeHeader: Equatable {
    let preKeyID: UInt32
    let signedPreKeyID: UInt32
    /// The initiator's Ed25519 identity key.
    let identityKey: [UInt8]
    let ephemeralKey: [UInt8]
}

extension OMEMOKeyExchange {
    init(_ header: OMEMOKeyExchangeHeader, message: OMEMOAuthenticatedMessage) {
        self.init(
            preKeyID: header.preKeyID,
            signedPreKeyID: header.signedPreKeyID,
            identityKey: header.identityKey,
            ephemeralKey: header.ephemeralKey,
            message: message
        )
    }

    var header: OMEMOKeyExchangeHeader {
        OMEMOKeyExchangeHeader(
            preKeyID: preKeyID, signedPreKeyID: signedPreKeyID, identityKey: identityKey, ephemeralKey: ephemeralKey
        )
    }
}

/// A Double Ratchet session with one device, and the key exchange that started it (XEP-0384 §4.3).
struct OMEMOSession {
    enum Start: Equatable {
        /// This device sent the key exchange. Until a message from the device confirms the session, every message
        /// to it repeats the key exchange.
        case sent(OMEMOKeyExchangeHeader, isConfirmed: Bool)
        /// The device sent the key exchange. The same key exchange arriving again carries a message for this session.
        case received(OMEMOKeyExchangeHeader)
    }

    var ratchet: OMEMODoubleRatchetSession
    /// X3DH associated data (64 bytes).
    let associatedData: [UInt8]
    private(set) var start: Start

    init(ratchet: OMEMODoubleRatchetSession, associatedData: [UInt8], start: Start) {
        self.ratchet = ratchet
        self.associatedData = associatedData
        self.start = start
    }

    /// The key exchange a message to the device has to repeat, while the device has not answered.
    var pendingKeyExchange: OMEMOKeyExchangeHeader? {
        guard case let .sent(header, isConfirmed: false) = start else { return nil }
        return header
    }

    /// The device's identity key: the one its key exchange carried, or, for a session this device started, the
    /// responder's half of the associated data. Nil when the associated data does not pair this device's key with
    /// another.
    var peerIdentityKey: [UInt8]? {
        switch start {
        case let .received(header):
            return header.identityKey
        case let .sent(header, _):
            let keyLength = OMEMOCrypto.keyLength
            guard associatedData.count == 2 * keyLength, Array(associatedData.prefix(keyLength)) == header.identityKey else { return nil }
            return Array(associatedData.suffix(keyLength))
        }
    }

    /// Whether `keyExchange` is the device's key exchange that started this session, so it builds nothing new.
    func isStarted(by keyExchange: OMEMOKeyExchangeHeader) -> Bool {
        start == .received(keyExchange)
    }

    mutating func encrypt(_ plaintext: [UInt8]) throws -> OMEMOAuthenticatedMessage {
        try ratchet.encrypt(plaintext: plaintext, associatedData: associatedData)
    }

    /// What a `<key>` element carries `keyMaterial` to the device as: the message wrapped in the pending key exchange,
    /// which `isKex` marks, else the message alone.
    mutating func encryptKey(_ keyMaterial: [UInt8]) throws -> (data: [UInt8], isKex: Bool) {
        let message = try encrypt(keyMaterial)
        guard let keyExchange = pendingKeyExchange else { return (message.serialized, false) }
        return (OMEMOKeyExchange(keyExchange, message: message).serialized, true)
    }

    /// A message that decrypts confirms a session this device started.
    mutating func decrypt(_ message: OMEMOAuthenticatedMessage) throws -> [UInt8] {
        let plaintext = try ratchet.decrypt(message: message, associatedData: associatedData)
        if case let .sent(header, _) = start {
            start = .sent(header, isConfirmed: true)
        }
        return plaintext
    }

    // MARK: - Serialization

    /// Opens every record, so a record in an earlier encoding fails to decode.
    private static let formatTag = Array("OMEMO 2 session 1".utf8)

    private enum StartKind: UInt8 {
        case sentUnconfirmed = 0
        case sentConfirmed = 1
        case received = 2
    }

    /// The stored record. The associated data is stored beside it.
    var serialized: [UInt8] {
        let (kind, header): (StartKind, OMEMOKeyExchangeHeader) = switch start {
        case let .sent(header, isConfirmed): (isConfirmed ? .sentConfirmed : .sentUnconfirmed, header)
        case let .received(header): (.received, header)
        }
        var writer = OMEMORecordWriter()
        writer.append(Self.formatTag)
        writer.append(kind.rawValue)
        writer.append(header.preKeyID)
        writer.append(header.signedPreKeyID)
        writer.append(header.identityKey)
        writer.append(header.ephemeralKey)
        writer.append(ratchet.serialize())
        return writer.bytes
    }

    init(serialized bytes: [UInt8], associatedData: [UInt8]) throws {
        var reader = OMEMORecordReader(bytes)
        guard try reader.read(Self.formatTag.count) == Self.formatTag,
              let kind = try StartKind(rawValue: reader.readByte())
        else { throw OMEMOModuleError.invalidKeyData }
        let header = try OMEMOKeyExchangeHeader(
            preKeyID: reader.readUInt32(),
            signedPreKeyID: reader.readUInt32(),
            identityKey: reader.read(OMEMOCrypto.keyLength),
            ephemeralKey: reader.read(OMEMOCrypto.keyLength)
        )
        self.ratchet = try OMEMODoubleRatchetSession(serialized: reader.readRest())
        self.associatedData = associatedData
        self.start = switch kind {
        case .sentUnconfirmed: .sent(header, isConfirmed: false)
        case .sentConfirmed: .sent(header, isConfirmed: true)
        case .received: .received(header)
        }
    }
}
