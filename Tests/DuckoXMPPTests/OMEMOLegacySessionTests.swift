import CryptoKit
import Foundation
import Testing
@testable import DuckoXMPP

/// Legacy sessions replaying the reference implementation's conversation, as alice and as bob.
struct OMEMOLegacySessionTests {
    @Test(arguments: ["alice", "bob"])
    func `a session sends and receives the reference conversation, surviving a record round trip after each step`(party: String) throws {
        let conversation = try OMEMOLegacyFixtures.conversation()
        let device = try OMEMOLegacyFixtures.device(party)
        let peer = try OMEMOLegacyFixtures.device(party == "alice" ? "bob" : "alice")
        var session = party == "alice" ? try alicesStartedSession(in: conversation) : nil
        let events = conversation.events.filter { $0.party == party }
        try #require(!events.isEmpty)
        var previousReference: OMEMO2Fixtures.Ratchet?

        for event in events {
            defer { previousReference = event.ratchet }
            let message = conversation.messages[event.message]
            switch event.action {
            case "send":
                var sender = try #require(session)
                let sent = try sender.encryptKey(Array(message.keyMaterial))

                #expect(sent.isKex == (message.keyExchange != nil))
                #expect(sent.data == Array(message.keyExchange?.bytes ?? message.authenticatedMessage.bytes))
                session = sender
            case "receive":
                var receiver = try receive(message, in: session, of: event, as: device)
                expectReceivingHalf(of: receiver.ratchet, matches: event.ratchet, reading: message, from: previousReference)
                // A ratchet step draws a random ratchet key, while the reference's next messages answer the one it drew.
                if receiver.ratchet.dhSendKeyPair.rawRepresentation != event.ratchet.ownPrivateKey {
                    receiver.ratchet = try OMEMODoubleRatchetSession(legacyReference: event.ratchet)
                }
                #expect(receiver.pendingKeyExchange == nil)
                session = receiver
            default:
                Issue.record("Unknown action \(event.action)")
            }

            let record = try #require(session).serialized
            let restored = try OMEMOSession(serialized: record, associatedData: #require(session).associatedData)
            #expect(record.starts(with: Array("OMEMO legacy session 1".utf8)))
            #expect(restored.format == .legacy)
            #expect(restored.serialized == record)
            session = restored
        }
        #expect(session?.peerIdentityKey == Array(peer.identityKey.agreementPublicKey))
    }

    /// alice's session as her first send found it: her key exchange to bob, and the reference's ratchet rewound to the
    /// chain key that send started from, since the ratchet key it draws is random.
    private func alicesStartedSession(in conversation: OMEMOLegacyFixtures.Conversation) throws -> OMEMOSession {
        let alice = try OMEMOLegacyFixtures.device("alice")
        let bob = try OMEMOLegacyFixtures.device("bob")
        let event = try #require(conversation.events.first)
        #expect(event.party == "alice" && event.action == "send")
        let ephemeralKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: #require(event.x3dh?.ephemeralPrivateKey))
        let keyExchange = try OMEMOKeyExchangeHeader(
            preKeyID: #require(conversation.messages[event.message].keyExchange).pkID,
            signedPreKeyID: bob.signedPreKey.id,
            identityKey: Array(alice.identityKey.agreementPublicKey),
            ephemeralKey: Array(ephemeralKey.publicKey.rawRepresentation)
        )
        var ratchet = try OMEMODoubleRatchetSession(legacyReference: event.ratchet)
        ratchet.sendChainKey = try Array(#require(event.messageChainSteps.first).chainKey)
        ratchet.sendMessageNumber = 0
        return OMEMOSession(ratchet: ratchet, associatedData: Array(conversation.associatedData), start: .sent(keyExchange, isConfirmed: false))
    }

    /// Reads `message` as the module does: a key exchange that started `session` carries a message for it, any other
    /// starts a new session, and a plain message goes through `session`.
    private func receive(
        _ message: OMEMOLegacyFixtures.Message, in session: OMEMOSession?, of event: OMEMOLegacyFixtures.Event, as device: OMEMOLegacyFixtures.Device
    ) throws -> OMEMOSession {
        guard let keyExchangeBytes = message.keyExchange?.bytes else {
            var current = try #require(session)
            let keyMaterial = try current.decrypt(.legacy(OMEMOLegacyMessage(serialized: Array(message.authenticatedMessage.bytes))))
            #expect(keyMaterial == Array(message.keyMaterial))
            return current
        }
        let keyExchange = try OMEMOLegacyKeyExchange(serialized: Array(keyExchangeBytes))
        if var current = session, current.isStarted(by: keyExchange.header) {
            #expect(event.x3dh == nil)
            let keyMaterial = try current.decrypt(.legacy(keyExchange.message))
            #expect(keyMaterial == Array(message.keyMaterial))
            return current
        }
        let preKey = try #require(device.preKeys.first { $0.id == keyExchange.preKeyID })
        let signedPreKey = try OMEMOSignedPreKey(
            keyID: device.signedPreKey.id, rawRepresentation: Array(device.signedPreKey.privateKey),
            signature: Array(device.signedPreKey.publishedSignature)
        )
        let x3dh = try OMEMOX3DH.responderKeyAgreement(
            identityKeyPair: device.restoredIdentityKey(),
            signedPreKey: signedPreKey,
            oneTimePreKey: OMEMOPreKey(keyID: preKey.id, rawRepresentation: Array(preKey.privateKey)),
            peerIdentityKey: keyExchange.identityKey,
            peerEphemeralKey: keyExchange.ephemeralKey,
            format: .legacy
        )
        #expect(Data(x3dh.sharedSecret) == event.x3dh?.sharedSecret)
        var started = OMEMOSession(
            ratchet: OMEMODoubleRatchetSession(
                asResponderWithSharedSecret: x3dh.sharedSecret, ourSignedPreKeyPair: signedPreKey.keyPair, format: .legacy
            ),
            associatedData: x3dh.associatedData,
            start: .received(keyExchange.header)
        )
        let keyMaterial = try started.decrypt(.legacy(keyExchange.message))
        #expect(keyMaterial == Array(message.keyMaterial))
        return started
    }

    private func expectReceivingHalf(
        of ratchet: OMEMODoubleRatchetSession, matches reference: OMEMO2Fixtures.Ratchet,
        reading message: OMEMOLegacyFixtures.Message, from previous: OMEMO2Fixtures.Ratchet?
    ) {
        #expect(ratchet.dhRecvPublicKey == reference.otherPublicKey.map(Array.init))
        #expect(ratchet.recvChainKey == reference.receivingChain.map { Array($0.key) })
        #expect(ratchet.recvMessageNumber == reference.receivingChain?.length ?? 0)
        #expect(ratchet.skippedMessageKeys == OMEMOLegacyFixtures.skippedKeys(of: reference, reading: message.message, from: previous))
    }
}
