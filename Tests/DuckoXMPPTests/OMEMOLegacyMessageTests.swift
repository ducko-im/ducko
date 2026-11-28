import CryptoKit
import Foundation
import Testing
@testable import DuckoXMPP

/// The legacy OMEMO message and key exchange encodings, and the ratchet that seals and opens them, against the
/// reference implementation's conversation.
enum OMEMOLegacyMessageTests {
    struct Codec {
        @Test func `every message decodes and re-encodes byte for byte`() throws {
            for fixture in try OMEMOLegacyFixtures.conversation().messages {
                let decoded = try OMEMOLegacyMessage(serialized: Array(fixture.authenticatedMessage.bytes))
                let encoded = OMEMOLegacyMessage(
                    content: OMEMOLegacyMessage.Content(
                        messageNumber: decoded.content.messageNumber,
                        previousChainCount: decoded.content.previousChainCount,
                        dhPublicKey: decoded.content.dhPublicKey,
                        ciphertext: decoded.content.ciphertext
                    ),
                    mac: decoded.mac
                )

                #expect(decoded.content.messageNumber == fixture.message.n)
                #expect(decoded.content.previousChainCount == fixture.message.pn)
                #expect(decoded.content.dhPublicKey == Array(fixture.message.dhPub.dropFirst()))
                #expect(decoded.content.ciphertext == Array(fixture.message.ciphertext))
                #expect(decoded.content.serialized == Array(fixture.message.bytes))
                #expect(decoded.mac == Array(fixture.authenticatedMessage.mac))
                #expect(encoded.content.serialized == Array(fixture.message.bytes))
                #expect(encoded.serialized == Array(fixture.authenticatedMessage.bytes))
            }
        }

        @Test func `every key exchange decodes and re-encodes byte for byte`() throws {
            let messages = try OMEMOLegacyFixtures.conversation().messages
            let keyExchanges = messages.filter { $0.keyExchange != nil }
            try #require(!keyExchanges.isEmpty)

            for fixture in keyExchanges {
                let keyExchange = try #require(fixture.keyExchange)
                let decoded = try OMEMOLegacyKeyExchange(serialized: Array(keyExchange.bytes))
                let encoded = try OMEMOLegacyKeyExchange(
                    preKeyID: decoded.preKeyID,
                    signedPreKeyID: decoded.signedPreKeyID,
                    identityKey: decoded.identityKey,
                    ephemeralKey: decoded.ephemeralKey,
                    message: OMEMOLegacyMessage(serialized: Array(fixture.authenticatedMessage.bytes))
                )

                #expect(decoded.preKeyID == keyExchange.pkID)
                #expect(decoded.signedPreKeyID == keyExchange.spkID)
                #expect(decoded.identityKey == Array(keyExchange.ik.dropFirst()))
                #expect(decoded.ephemeralKey == Array(keyExchange.ek.dropFirst()))
                #expect(decoded.message.serialized == Array(fixture.authenticatedMessage.bytes))
                #expect(encoded.serialized == Array(keyExchange.bytes))
            }
        }

        /// libsignal clients write their registration id in field 5, which the reference stack never does.
        @Test func `a key exchange's registration id is skipped on read and not written back`() throws {
            let bytes = Malformed.keyExchange(registrationID: [0x28, 0x2A])

            let decoded = try OMEMOLegacyKeyExchange(serialized: bytes)

            #expect(decoded.preKeyID == 7)
            #expect(decoded.signedPreKeyID == 1)
            #expect(decoded.serialized == Malformed.keyExchange())
        }
    }

    /// Malformed legacy messages and key exchanges are rejected as invalid key data rather than read as some other
    /// message.
    struct Malformed {
        enum Kind: Sendable {
            case message
            case keyExchange
        }

        struct Input: Sendable, CustomTestStringConvertible {
            let testDescription: String
            let kind: Kind
            let bytes: [UInt8]
        }

        // Fields of a valid message: a 33-byte dh_pub, n=1, pn=2 and a 3-byte ciphertext, then an 8-byte MAC.
        private static let dhPub: [UInt8] = [0x0A, 0x21, 0x05] + Array(repeating: 0xAB, count: 32)
        private static let n: [UInt8] = [0x10, 0x01]
        private static let pn: [UInt8] = [0x18, 0x02]
        private static let ciphertext: [UInt8] = [0x22, 0x03, 1, 2, 3]
        private static let mac: [UInt8] = Array(repeating: 0xCC, count: 8)
        private static let protobuf = dhPub + n + pn + ciphertext
        static let message = [0x33] + protobuf + mac

        // Fields of a valid key exchange around `message`: pk_id=7, a 33-byte ek and ik, and spk_id=1.
        private static let pkID: [UInt8] = [0x08, 0x07]
        private static let ek: [UInt8] = [0x12, 0x21, 0x05] + Array(repeating: 0x22, count: 32)
        private static let ik: [UInt8] = [0x1A, 0x21, 0x05] + Array(repeating: 0x11, count: 32)
        private static let spkID: [UInt8] = [0x30, 0x01]

        static func keyExchange(
            version: [UInt8] = [0x33], ek: [UInt8] = ek, ik: [UInt8] = ik, message: [UInt8] = message,
            registrationID: [UInt8] = [], spkID: [UInt8] = spkID
        ) -> [UInt8] {
            version + pkID + ek + ik + [0x22, UInt8(message.count)] + message + registrationID + spkID
        }

        static let inputs: [Input] = [
            Input(testDescription: "empty", kind: .message, bytes: []),
            Input(testDescription: "only a MAC", kind: .message, bytes: [0x33] + Array(mac.dropFirst())),
            Input(testDescription: "missing version byte", kind: .message, bytes: protobuf + mac),
            Input(testDescription: "other version byte", kind: .message, bytes: [0x32] + protobuf + mac),
            Input(testDescription: "MAC truncated to 7 bytes", kind: .message, bytes: Array(message.dropLast())),
            Input(testDescription: "dh_pub without its type byte", kind: .message, bytes: [0x33, 0x0A, 0x20] + Array(repeating: 0xAB, count: 32) + n + pn + ciphertext + mac),
            Input(testDescription: "dh_pub with another type byte", kind: .message, bytes: [0x33, 0x0A, 0x21, 0x06] + Array(repeating: 0xAB, count: 32) + n + pn + ciphertext + mac),
            Input(testDescription: "repeated n", kind: .message, bytes: [0x33] + n + protobuf + mac),
            Input(testDescription: "missing ciphertext", kind: .message, bytes: [0x33] + dhPub + n + pn + mac),
            Input(testDescription: "group", kind: .message, bytes: [0x33] + protobuf + [0x4B, 0x4C] + mac),
            Input(testDescription: "wire type 7", kind: .message, bytes: [0x33] + protobuf + [0x4F] + mac),
            Input(testDescription: "missing version byte", kind: .keyExchange, bytes: Array(keyExchange().dropFirst())),
            Input(testDescription: "other version byte", kind: .keyExchange, bytes: keyExchange(version: [0x34])),
            Input(testDescription: "ik without its type byte", kind: .keyExchange, bytes: keyExchange(ik: [0x1A, 0x20] + Array(repeating: 0x11, count: 32))),
            Input(testDescription: "ek with another type byte", kind: .keyExchange, bytes: keyExchange(ek: [0x12, 0x21, 0x06] + Array(repeating: 0x22, count: 32))),
            Input(testDescription: "missing spk_id", kind: .keyExchange, bytes: keyExchange(spkID: [])),
            Input(testDescription: "repeated spk_id", kind: .keyExchange, bytes: keyExchange(spkID: spkID + spkID)),
            Input(testDescription: "wire type 7", kind: .keyExchange, bytes: keyExchange(registrationID: [0x2F])),
            Input(testDescription: "inner message missing its version byte", kind: .keyExchange, bytes: keyExchange(message: protobuf + mac))
        ]

        @Test(arguments: inputs)
        func `malformed input is rejected`(_ input: Input) {
            #expect(throws: OMEMOModuleError.invalidKeyData) {
                switch input.kind {
                case .message: _ = try OMEMOLegacyMessage(serialized: input.bytes)
                case .keyExchange: _ = try OMEMOLegacyKeyExchange(serialized: input.bytes)
                }
            }
        }

        @Test func `the valid inputs the malformed ones start from decode`() throws {
            _ = try OMEMOLegacyMessage(serialized: Self.message)
            _ = try OMEMOLegacyKeyExchange(serialized: Self.keyExchange())
        }
    }

    /// A ratchet rebuilt from the reference's state seals and opens the reference's messages.
    struct Ratchet {
        @Test func `every message encrypts to the reference's bytes`() throws {
            let conversation = try OMEMOLegacyFixtures.conversation()

            for event in conversation.events where event.action == "send" {
                let message = conversation.messages[event.message]
                let step = try #require(event.messageChainSteps.first)
                var ratchet = try OMEMODoubleRatchetSession(legacyReference: event.ratchet)
                ratchet.sendChainKey = Array(step.chainKey)
                ratchet.sendMessageNumber = message.message.n

                let encrypted = try ratchet.encrypt(Array(message.keyMaterial), associatedData: Array(message.associatedData))

                guard case let .legacy(legacyMessage) = encrypted else {
                    Issue.record("A legacy ratchet sealed a message in another format")
                    continue
                }
                #expect(legacyMessage.serialized == Array(message.authenticatedMessage.bytes))
            }
        }

        @Test func `each party decrypts every message it received`() throws {
            let conversation = try OMEMOLegacyFixtures.conversation()
            var lastStates: [String: OMEMO2Fixtures.Ratchet] = [:]

            for event in conversation.events {
                defer { lastStates[event.party] = event.ratchet }
                guard event.action == "receive" else { continue }
                let message = conversation.messages[event.message]
                var ratchet = try receivingRatchet(of: event, after: lastStates[event.party])

                let keyMaterial = try ratchet.decrypt(
                    .legacy(OMEMOLegacyMessage(serialized: Array(message.authenticatedMessage.bytes))),
                    associatedData: Array(message.associatedData)
                )

                #expect(keyMaterial == Array(message.keyMaterial))
                #expect(ratchet.dhRecvPublicKey == event.ratchet.otherPublicKey.map(Array.init))
                #expect(ratchet.recvChainKey == event.ratchet.receivingChain.map { Array($0.key) })
                #expect(ratchet.recvMessageNumber == event.ratchet.receivingChain?.length ?? 0)
                #expect(ratchet.skippedMessageKeys == OMEMOLegacyFixtures.skippedKeys(
                    of: event.ratchet, reading: message.message, from: lastStates[event.party]
                ))
            }
            #expect(lastStates.count == 2)
        }

        @Test func `the last message of a libsignal sender's previous chain decrypts after its next chain's first`() throws {
            var (sender, receiver) = try sessionPairAfterFirstMessage()
            let lastOfChain = try sender.encrypt(Array("last of chain".utf8), associatedData: associatedData)
            _ = try sender.decrypt(receiver.encrypt(Array("reply".utf8), associatedData: associatedData), associatedData: associatedData)
            // libsignal writes the index of the previous chain's last message, where Ducko writes the chain's length.
            #expect(sender.previousSendCount == 2)
            sender.previousSendCount -= 1

            let nextChain = try sender.encrypt(Array("next chain".utf8), associatedData: associatedData)

            #expect(nextChain.previousChainCount == 1)
            #expect(try receiver.decrypt(nextChain, associatedData: associatedData) == Array("next chain".utf8))
            #expect(try receiver.decrypt(lastOfChain, associatedData: associatedData) == Array("last of chain".utf8))
        }

        /// A libsignal sender writes the index of its previous chain's last message, one less than the length.
        @Test(arguments: [
            (outstanding: 1000, writesIndex: false, accepted: true), (outstanding: 1001, writesIndex: false, accepted: false),
            (outstanding: 1000, writesIndex: true, accepted: true)
        ])
        func `a sender is held to the skipped-key cap, whether it writes its previous chain's length or its last index`(
            outstanding: Int, writesIndex: Bool, accepted: Bool
        ) throws {
            var (sender, receiver) = try sessionPairAfterFirstMessage()
            var lastOfChain: OMEMORatchetMessage?
            for _ in 0 ..< outstanding {
                lastOfChain = try sender.encrypt(Array("undelivered".utf8), associatedData: associatedData)
            }
            _ = try sender.decrypt(receiver.encrypt(Array("reply".utf8), associatedData: associatedData), associatedData: associatedData)
            if writesIndex {
                sender.previousSendCount -= 1
            }

            let nextChain = try sender.encrypt(Array("next chain".utf8), associatedData: associatedData)

            #expect(nextChain.previousChainCount == UInt32(writesIndex ? outstanding : outstanding + 1))
            if accepted {
                #expect(try receiver.decrypt(nextChain, associatedData: associatedData) == Array("next chain".utf8))
                #expect(try receiver.decrypt(#require(lastOfChain), associatedData: associatedData) == Array("undelivered".utf8))
            } else {
                let error = #expect(throws: OMEMOCryptoError.self) {
                    try receiver.decrypt(nextChain, associatedData: associatedData)
                }
                guard case .tooManySkippedMessages = error else {
                    Issue.record("Expected the skipped-key cap, got \(String(describing: error))")
                    return
                }
            }
        }

        private let associatedData = Array(repeating: UInt8(0x5A), count: 66)

        /// A fresh legacy session pair whose receiver has read the sender's first message.
        private func sessionPairAfterFirstMessage() throws -> (OMEMODoubleRatchetSession, OMEMODoubleRatchetSession) {
            let sharedSecret = Array(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
            let signedPreKey = Curve25519.KeyAgreement.PrivateKey()
            var sender = try OMEMODoubleRatchetSession(
                asInitiatorWithSharedSecret: sharedSecret, peerSignedPreKey: Array(signedPreKey.publicKey.rawRepresentation), format: .legacy
            )
            var receiver = OMEMODoubleRatchetSession(asResponderWithSharedSecret: sharedSecret, ourSignedPreKeyPair: signedPreKey, format: .legacy)
            _ = try receiver.decrypt(sender.encrypt(Array("first".utf8), associatedData: associatedData), associatedData: associatedData)
            return (sender, receiver)
        }

        enum Tampering: CaseIterable {
            case flippedMAC, flippedCiphertext, swappedAssociatedData
        }

        @Test(arguments: Tampering.allCases)
        func `a tampered message fails authentication and leaves the ratchet as it was`(tampering: Tampering) throws {
            let conversation = try OMEMOLegacyFixtures.conversation()
            let event = try #require(conversation.events.first { $0.action == "receive" && $0.x3dh != nil })
            let message = conversation.messages[event.message]
            var bytes = Array(message.authenticatedMessage.bytes)
            var associatedData = Array(message.associatedData)
            switch tampering {
            case .flippedMAC: bytes[bytes.count - 1] ^= 0x01
            case .flippedCiphertext: bytes[bytes.count - OMEMOLegacyMessage.macLength - 1] ^= 0x01
            case .swappedAssociatedData: associatedData = Array(associatedData.suffix(33) + associatedData.prefix(33))
            }
            var ratchet = try receivingRatchet(of: event, after: nil)
            let before = ratchet.serialize()

            let error = #expect(throws: OMEMOCryptoError.self) {
                try ratchet.decrypt(.legacy(OMEMOLegacyMessage(serialized: bytes)), associatedData: associatedData)
            }
            guard case .hmacVerificationFailed = error else {
                Issue.record("Expected an authentication failure, got \(String(describing: error))")
                return
            }
            #expect(ratchet.serialize() == before)
        }

        /// The receiver's ratchet before `event`: its reference state after its previous event, or the responder's
        /// fresh ratchet from the key exchange.
        private func receivingRatchet(
            of event: OMEMOLegacyFixtures.Event, after lastState: OMEMO2Fixtures.Ratchet?
        ) throws -> OMEMODoubleRatchetSession {
            if let lastState { return try OMEMODoubleRatchetSession(legacyReference: lastState) }
            let x3dh = try #require(event.x3dh)
            let receiver = try OMEMOLegacyFixtures.device(event.party)
            return try OMEMODoubleRatchetSession(
                asResponderWithSharedSecret: Array(x3dh.sharedSecret),
                ourSignedPreKeyPair: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: receiver.signedPreKey.privateKey),
                format: .legacy
            )
        }
    }
}

extension OMEMODoubleRatchetSession {
    /// A legacy session in the reference's state, through the OMEMO 2 helper and the format-free record.
    init(legacyReference reference: OMEMO2Fixtures.Ratchet) throws {
        try self.init(serialized: OMEMODoubleRatchetSession(reference: reference).serialize(), format: .legacy)
    }
}
