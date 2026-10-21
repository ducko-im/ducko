import Testing
@testable import DuckoXMPP

/// Malformed OMEMO protobufs are rejected as invalid key data rather than read as some other message.
struct OMEMOProtobufTests {
    enum Kind: Sendable {
        case message
        case authenticatedMessage
        case keyExchange
    }

    struct Input: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let kind: Kind
        let bytes: [UInt8]
    }

    // Fields of a valid OMEMOMessage: n=1, pn=2, a 32-byte dh_pub and a 3-byte ciphertext.
    private static let n: [UInt8] = [0x08, 0x01]
    private static let pn: [UInt8] = [0x10, 0x02]
    private static let dhPub: [UInt8] = [0x1A, 0x20] + Array(repeating: 0xAB, count: 32)
    private static let ciphertext: [UInt8] = [0x22, 0x03, 1, 2, 3]
    private static let message = n + pn + dhPub + ciphertext
    private static let mac: [UInt8] = [0x0A, 0x10] + Array(repeating: 0xCC, count: 16)
    private static let authenticatedMessage = mac + [0x12, UInt8(message.count)] + message
    private static let identityKey: [UInt8] = [0x1A, 0x20] + Array(repeating: 0x11, count: 32)
    private static let ephemeralKey: [UInt8] = [0x22, 0x20] + Array(repeating: 0x22, count: 32)
    private static let keyExchangeMessage: [UInt8] = [0x2A, UInt8(authenticatedMessage.count)] + authenticatedMessage

    static let malformed: [Input] = [
        Input(testDescription: "missing n", kind: .message, bytes: pn + dhPub + ciphertext),
        Input(testDescription: "missing dh_pub", kind: .message, bytes: n + pn + ciphertext),
        Input(testDescription: "missing ciphertext", kind: .message, bytes: n + pn + dhPub),
        Input(testDescription: "repeated n", kind: .message, bytes: n + message),
        Input(testDescription: "n as length-delimited", kind: .message, bytes: [0x0A, 0x01, 0x01] + pn + dhPub + ciphertext),
        Input(testDescription: "n past 32 bits", kind: .message, bytes: [0x08, 0x80, 0x80, 0x80, 0x80, 0x10] + pn + dhPub + ciphertext),
        Input(testDescription: "short dh_pub", kind: .message, bytes: n + pn + [0x1A, 0x1F] + Array(repeating: 0xAB, count: 31) + ciphertext),
        Input(testDescription: "length past the end", kind: .message, bytes: n + pn + [0x1A, 0x21] + Array(repeating: 0xAB, count: 32)),
        Input(testDescription: "truncated varint", kind: .message, bytes: message + [0x48, 0x80]),
        Input(testDescription: "varint longer than 10 bytes", kind: .message, bytes: message + [0x48] + Array(repeating: 0x80, count: 10) + [0x00]),
        Input(testDescription: "varint past 64 bits", kind: .message, bytes: message + [0x48] + Array(repeating: 0xFF, count: 9) + [0x02]),
        Input(testDescription: "truncated fixed32", kind: .message, bytes: message + [0x4D, 0x00, 0x00]),
        Input(testDescription: "field number 0", kind: .message, bytes: [0x00, 0x00] + message),
        Input(testDescription: "field number 2^29", kind: .message, bytes: message + [0x80, 0x80, 0x80, 0x80, 0x10, 0x00]),
        Input(testDescription: "field number 2^32", kind: .message, bytes: message + [0x80, 0x80, 0x80, 0x80, 0x80, 0x01, 0x00]),
        Input(testDescription: "group", kind: .message, bytes: message + [0x4B, 0x4C]),
        Input(testDescription: "wire type 7", kind: .message, bytes: message + [0x4F]),
        Input(testDescription: "missing mac", kind: .authenticatedMessage, bytes: [0x12, UInt8(message.count)] + message),
        Input(testDescription: "short mac", kind: .authenticatedMessage, bytes: [0x0A, 0x0F] + Array(repeating: 0xCC, count: 15) + [0x12, UInt8(message.count)] + message),
        Input(testDescription: "inner message missing n", kind: .authenticatedMessage, bytes: mac + [0x12, UInt8(message.count - 2)] + pn + dhPub + ciphertext),
        Input(testDescription: "missing pk_id", kind: .keyExchange, bytes: [0x10, 0x01] + identityKey + ephemeralKey + keyExchangeMessage),
        Input(testDescription: "missing message", kind: .keyExchange, bytes: [0x08, 0x07, 0x10, 0x01] + identityKey + ephemeralKey),
        Input(testDescription: "short ek", kind: .keyExchange, bytes: [0x08, 0x07, 0x10, 0x01] + identityKey + [0x22, 0x01, 0x22] + keyExchangeMessage)
    ]

    @Test(arguments: malformed)
    func `malformed input is rejected`(_ input: Input) {
        #expect(throws: OMEMOModuleError.invalidKeyData) {
            switch input.kind {
            case .message: _ = try OMEMOMessage(serialized: input.bytes)
            case .authenticatedMessage: _ = try OMEMOAuthenticatedMessage(serialized: input.bytes)
            case .keyExchange: _ = try OMEMOKeyExchange(serialized: input.bytes)
            }
        }
    }

    @Test func `the valid messages the malformed inputs start from decode`() throws {
        _ = try OMEMOMessage(serialized: Self.message)
        _ = try OMEMOAuthenticatedMessage(serialized: Self.authenticatedMessage)
        _ = try OMEMOKeyExchange(serialized: [0x08, 0x07, 0x10, 0x01] + Self.identityKey + Self.ephemeralKey + Self.keyExchangeMessage)
    }

    /// The MAC covers the message as sent, so a decoded message keeps those bytes even where Ducko would encode
    /// them differently.
    @Test func `a decoded message keeps the bytes it arrived as`() throws {
        let bytes = Self.message + [0x48, 0x05, 0x55, 0x01, 0x02, 0x03, 0x04]

        let decoded = try OMEMOMessage(serialized: bytes)

        #expect(decoded.messageNumber == 1)
        #expect(decoded.ciphertext == [1, 2, 3])
        #expect(decoded.serialized == bytes)
    }
}
