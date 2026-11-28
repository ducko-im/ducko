/// The X3DH values a key exchange carries around its first message, in either OMEMO version's wire format.
package struct OMEMOKeyExchangeHeader: Equatable {
    let preKeyID: UInt32
    let signedPreKeyID: UInt32
    /// The initiator's identity key: Ed25519 in OMEMO 2, Curve25519 without its `0x05` type byte in legacy.
    let identityKey: [UInt8]
    /// Without its `0x05` type byte in legacy.
    let ephemeralKey: [UInt8]

    package init(preKeyID: UInt32, signedPreKeyID: UInt32, identityKey: [UInt8], ephemeralKey: [UInt8]) {
        self.preKeyID = preKeyID
        self.signedPreKeyID = signedPreKeyID
        self.identityKey = identityKey
        self.ephemeralKey = ephemeralKey
    }
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

extension OMEMOLegacyKeyExchange {
    init(_ header: OMEMOKeyExchangeHeader, message: OMEMOLegacyMessage) {
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

extension OMEMORatchetMessage {
    /// Reads a message in `format`'s wire format.
    init(serialized: [UInt8], format: OMEMOWireFormat) throws {
        self = switch format {
        case .omemo2: try .omemo2(OMEMOAuthenticatedMessage(serialized: serialized))
        case .legacy: try .legacy(OMEMOLegacyMessage(serialized: serialized))
        }
    }

    /// Reads a key exchange in `format`'s wire format: its X3DH values, and the message they wrap.
    static func keyExchange(serialized: [UInt8], format: OMEMOWireFormat) throws -> (header: OMEMOKeyExchangeHeader, message: Self) {
        switch format {
        case .omemo2:
            let keyExchange = try OMEMOKeyExchange(serialized: serialized)
            return (keyExchange.header, .omemo2(keyExchange.message))
        case .legacy:
            let keyExchange = try OMEMOLegacyKeyExchange(serialized: serialized)
            return (keyExchange.header, .legacy(keyExchange.message))
        }
    }

    var serialized: [UInt8] {
        switch self {
        case let .omemo2(message): message.serialized
        case let .legacy(message): message.serialized
        }
    }

    /// The key exchange `header` describes, around this message, in the message's wire format.
    func serializedKeyExchange(_ header: OMEMOKeyExchangeHeader) -> [UInt8] {
        switch self {
        case let .omemo2(message): OMEMOKeyExchange(header, message: message).serialized
        case let .legacy(message): OMEMOLegacyKeyExchange(header, message: message).serialized
        }
    }
}

/// A Double Ratchet session with one device, and the key exchange that started it (XEP-0384 §4.3).
package struct OMEMOSession {
    package enum Start: Equatable {
        /// This device sent the key exchange. Until a message from the device confirms the session, every message
        /// to it repeats the key exchange.
        case sent(OMEMOKeyExchangeHeader, isConfirmed: Bool)
        /// The device sent the key exchange. The same key exchange arriving again carries a message for this session.
        case received(OMEMOKeyExchangeHeader)
    }

    var ratchet: OMEMODoubleRatchetSession
    /// X3DH associated data: the initiator's encoded identity key, then the responder's (64 bytes in OMEMO 2, 66 in
    /// legacy).
    let associatedData: [UInt8]
    private(set) var start: Start

    package init(ratchet: OMEMODoubleRatchetSession, associatedData: [UInt8], start: Start) {
        self.ratchet = ratchet
        self.associatedData = associatedData
        self.start = start
    }

    /// The OMEMO version the session speaks, which its ratchet holds.
    var format: OMEMOWireFormat {
        ratchet.format
    }

    /// The key exchange a message to the device has to repeat, while the device has not answered.
    var pendingKeyExchange: OMEMOKeyExchangeHeader? {
        guard case let .sent(header, isConfirmed: false) = start else { return nil }
        return header
    }

    /// The device's identity key: the one its key exchange carried, or, for a session this device started, the
    /// responder's half of the associated data without its encoding. Nil when the associated data does not pair this
    /// device's key with another.
    var peerIdentityKey: [UInt8]? {
        switch start {
        case let .received(header):
            return header.identityKey
        case let .sent(header, _):
            let ownKey = format.encodedIdentityKey(header.identityKey)
            let peerKey = Array(associatedData.suffix(OMEMOCrypto.keyLength))
            guard associatedData == ownKey + format.encodedIdentityKey(peerKey) else { return nil }
            return peerKey
        }
    }

    /// The stored fingerprint of `peerIdentityKey`, in the session's version's form.
    var peerFingerprint: String? {
        peerIdentityKey.map { omemoFingerprint(of: $0, format: format) }
    }

    /// Whether `keyExchange` is the device's key exchange that started this session, so it builds nothing new.
    func isStarted(by keyExchange: OMEMOKeyExchangeHeader) -> Bool {
        start == .received(keyExchange)
    }

    /// What a `<key>` element carries `keyMaterial` to the device as: the message wrapped in the pending key exchange,
    /// which `isKex` marks, else the message alone.
    package mutating func encryptKey(_ keyMaterial: [UInt8]) throws -> (data: [UInt8], isKex: Bool) {
        let message = try ratchet.encrypt(keyMaterial, associatedData: associatedData(sentByInitiator: isInitiator))
        guard let keyExchange = pendingKeyExchange else { return (message.serialized, false) }
        return (message.serializedKeyExchange(keyExchange), true)
    }

    /// A message that decrypts confirms a session this device started. A message in the other version's wire format
    /// throws `wireFormatMismatch`.
    package mutating func decrypt(_ message: OMEMORatchetMessage) throws -> [UInt8] {
        let plaintext = try ratchet.decrypt(message, associatedData: associatedData(sentByInitiator: !isInitiator))
        if case let .sent(header, _) = start {
            start = .sent(header, isConfirmed: true)
        }
        return plaintext
    }

    /// Whether this device sent the key exchange, so its identity key comes first in the associated data.
    private var isInitiator: Bool {
        switch start {
        case .sent: true
        case .received: false
        }
    }

    /// The associated data the MAC of a message covers. OMEMO 2 keeps the initiator's key first both ways. Legacy
    /// puts the sender's key first, as libsignal does, so a message from the responder covers the two halves swapped.
    private func associatedData(sentByInitiator: Bool) -> [UInt8] {
        switch format {
        case .omemo2:
            return associatedData
        case .legacy:
            guard !sentByInitiator else { return associatedData }
            let half = associatedData.count / 2
            return Array(associatedData[half...] + associatedData[..<half])
        }
    }

    // MARK: - Serialization

    /// Opens every record and names its version, so a record in an earlier encoding fails to decode.
    private static func formatTag(of format: OMEMOWireFormat) -> [UInt8] {
        switch format {
        case .omemo2: Array("OMEMO 2 session 1".utf8)
        case .legacy: Array("OMEMO legacy session 1".utf8)
        }
    }

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
        writer.append(Self.formatTag(of: format))
        writer.append(kind.rawValue)
        writer.append(header.preKeyID)
        writer.append(header.signedPreKeyID)
        writer.append(header.identityKey)
        writer.append(header.ephemeralKey)
        writer.append(ratchet.serialize())
        return writer.bytes
    }

    init(serialized bytes: [UInt8], associatedData: [UInt8]) throws {
        guard let format = OMEMOWireFormat.allCases.first(where: { bytes.starts(with: Self.formatTag(of: $0)) }) else {
            throw OMEMOModuleError.invalidKeyData
        }
        var reader = OMEMORecordReader(Array(bytes.dropFirst(Self.formatTag(of: format).count)))
        guard let kind = try StartKind(rawValue: reader.readByte()) else { throw OMEMOModuleError.invalidKeyData }
        let header = try OMEMOKeyExchangeHeader(
            preKeyID: reader.readUInt32(),
            signedPreKeyID: reader.readUInt32(),
            identityKey: reader.read(OMEMOCrypto.keyLength),
            ephemeralKey: reader.read(OMEMOCrypto.keyLength)
        )
        self.ratchet = try OMEMODoubleRatchetSession(serialized: reader.readRest(), format: format)
        self.associatedData = associatedData
        self.start = switch kind {
        case .sentUnconfirmed: .sent(header, isConfirmed: false)
        case .sentConfirmed: .sent(header, isConfirmed: true)
        case .received: .received(header)
        }
    }
}
