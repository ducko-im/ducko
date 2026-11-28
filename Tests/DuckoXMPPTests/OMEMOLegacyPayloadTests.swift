import CryptoKit
import Foundation
import Testing
@testable import DuckoXMPP

/// Legacy payloads and key transports, checked against the reference implementation's messages.
struct OMEMOLegacyPayloadTests {
    static let payloadMessages = [0, 1, 2, 4, 5, 6, 7]
    static let keyTransportMessage = 3

    @Test(arguments: payloadMessages)
    func `the reference payload decrypts to its body`(index: Int) throws {
        let message = try OMEMOLegacyFixtures.conversation().messages[index]

        let body = try Self.payload(of: message).decryptBody()

        #expect(body == message.body)
    }

    @Test(arguments: ["Hello", " \t\nTwo lines\n\t ", "Grüße 🦆"])
    func `a Ducko payload round-trips, trimming only spaces and tabs`(body: String) throws {
        let payload = try OMEMOLegacyPayload(encrypting: body)

        let decrypted = try OMEMOLegacyPayload(ciphertext: payload.ciphertext, iv: payload.iv, keyMaterial: payload.keyMaterial)
            .decryptBody()

        #expect(payload.iv.count == 12)
        #expect(payload.keyMaterial.count == 32)
        #expect(decrypted == body.trimmingCharacters(in: CharacterSet(charactersIn: " \t")))
    }

    @Test func `the reference key transport is accepted`() throws {
        let message = try OMEMOLegacyFixtures.conversation().messages[Self.keyTransportMessage]

        #expect(message.payload == nil)
        try OMEMOLegacyPayload.KeyTransport.validate(receivedKeyMaterial: Array(message.keyMaterial))
    }

    @Test func `a Ducko key transport carries a fresh key and IV, and is accepted`() throws {
        let first = OMEMOLegacyPayload.KeyTransport()
        let second = OMEMOLegacyPayload.KeyTransport()

        #expect(first.keyMaterial.count == 16)
        #expect(first.iv.count == 12)
        #expect(first.keyMaterial != second.keyMaterial)
        #expect(first.iv != second.iv)
        try OMEMOLegacyPayload.KeyTransport.validate(receivedKeyMaterial: first.keyMaterial)
    }

    @Test(arguments: [16, 32])
    func `key transport accepts a key with or without a tag`(length: Int) throws {
        try OMEMOLegacyPayload.KeyTransport.validate(receivedKeyMaterial: [UInt8](repeating: 1, count: length))
    }

    @Test(arguments: [0, 15, 17, 31, 33, 48])
    func `key transport rejects other key material lengths`(length: Int) {
        #expect(throws: OMEMOModuleError.invalidPayload) {
            try OMEMOLegacyPayload.KeyTransport.validate(receivedKeyMaterial: [UInt8](repeating: 1, count: length))
        }
    }

    enum Malformation: CaseIterable {
        case eightByteIV, keyWithoutTag, emptyCiphertext, notUTF8
    }

    @Test(arguments: Malformation.allCases)
    func `a malformed payload is rejected`(malformation: Malformation) throws {
        let message = try OMEMOLegacyFixtures.conversation().messages[0]
        var payload = try Self.payload(of: message)
        switch malformation {
        case .eightByteIV:
            payload = OMEMOLegacyPayload(ciphertext: payload.ciphertext, iv: Array(payload.iv.prefix(8)), keyMaterial: payload.keyMaterial)
        case .keyWithoutTag:
            payload = OMEMOLegacyPayload(ciphertext: payload.ciphertext, iv: payload.iv, keyMaterial: Array(payload.keyMaterial.prefix(16)))
        case .emptyCiphertext:
            payload = OMEMOLegacyPayload(ciphertext: [], iv: payload.iv, keyMaterial: payload.keyMaterial)
        case .notUTF8:
            let key = SymmetricKey(size: .bits128)
            let sealed = try AES.GCM.seal([0xFF, 0xFE], using: key)
            payload = OMEMOLegacyPayload(
                ciphertext: Array(sealed.ciphertext), iv: Array(sealed.nonce),
                keyMaterial: key.withUnsafeBytes { Array($0) } + Array(sealed.tag)
            )
        }

        #expect(throws: OMEMOModuleError.invalidPayload) {
            try payload.decryptBody()
        }
    }

    enum Tampering: CaseIterable {
        case tag, ciphertext, iv, key
    }

    @Test(arguments: Tampering.allCases)
    func `a tampered payload fails authentication`(tampering: Tampering) throws {
        let message = try OMEMOLegacyFixtures.conversation().messages[4]
        let payload = try Self.payload(of: message)
        var ciphertext = payload.ciphertext
        var iv = payload.iv
        var keyMaterial = payload.keyMaterial
        switch tampering {
        case .tag: keyMaterial[31] ^= 0x01
        case .ciphertext: ciphertext[0] ^= 0x01
        case .iv: iv[15] ^= 0x01
        case .key: keyMaterial[0] ^= 0x01
        }

        let error = #expect(throws: OMEMOCryptoError.self) {
            try OMEMOLegacyPayload(ciphertext: ciphertext, iv: iv, keyMaterial: keyMaterial).decryptBody()
        }

        guard case .hmacVerificationFailed = error else {
            Issue.record("Expected an authentication failure, got \(String(describing: error))")
            return
        }
    }

    private static func payload(of message: OMEMOLegacyFixtures.Message) throws -> OMEMOLegacyPayload {
        let payloadText = try #require(message.payload)
        let ciphertext = try #require(Data(base64Encoded: payloadText))
        return OMEMOLegacyPayload(ciphertext: Array(ciphertext), iv: Array(message.iv), keyMaterial: Array(message.keyMaterial))
    }
}
