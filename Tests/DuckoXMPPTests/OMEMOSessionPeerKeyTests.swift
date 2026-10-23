import Testing
@testable import DuckoXMPP

private let accountJID = BareJID(localPart: "user", domainPart: "example.com")!
private let senderJID = FullJID.parse("peer@example.com/i")!

/// A session's peer identity key, which the trust guard compares a key exchange or a send with.
struct OMEMOSessionPeerKeyTests {
    @Test func `A session holds the other device's key, whichever side started it`() async throws {
        let sender = try makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1])
        let recipient = try makeTestOMEMOIdentity(deviceID: 200, preKeyIDs: [7])
        let senderModule = makeInstalledOMEMOModule(identity: sender.data, context: makeStubModuleContext(sendIQ: { _, _ in bundleItems(for: recipient) }))
        let recipientModule = makeInstalledOMEMOModule(identity: recipient.data, context: makeStubModuleContext())

        let encrypted = try await senderModule.encryptMessage(plaintext: "hi", to: accountJID, recipientDeviceIDs: [200], ownDeviceIDs: []).encrypted
        _ = try recipientModule.decryptIncomingMessage(encrypted, from: .full(senderJID))

        let started = senderModule.state.withLock { $0.sessions[SessionKey(jid: accountJID, deviceID: 200)] }
        let received = recipientModule.state.withLock { $0.sessions[SessionKey(jid: senderJID.bareJID, deviceID: 100)] }
        #expect(started?.peerIdentityKey == recipient.identityKeyPair.publicKeyBytes)
        #expect(received?.peerIdentityKey == sender.identityKeyPair.publicKeyBytes)
    }

    enum Corruption: CaseIterable {
        case wrongLength, otherFirstHalf
    }

    @Test(arguments: Corruption.allCases)
    func `A started session's key is unreadable when its associated data does not pair this device's key with another`(corruption: Corruption) throws {
        let ownKey = OMEMOIdentityKeyPair().publicKeyBytes
        let responderKey = OMEMOIdentityKeyPair().publicKeyBytes
        let header = OMEMOKeyExchangeHeader(preKeyID: 1, signedPreKeyID: 1, identityKey: ownKey, ephemeralKey: Array(repeating: 0xEE, count: 32))
        let associatedData = switch corruption {
        case .wrongLength: ownKey + responderKey.dropLast()
        case .otherFirstHalf: OMEMOIdentityKeyPair().publicKeyBytes + responderKey
        }

        let session = try OMEMOSession(
            ratchet: OMEMODoubleRatchetSession(
                asResponderWithSharedSecret: Array(repeating: 1, count: 32),
                ourSignedPreKeyPair: OMEMOSignedPreKey(keyID: 1, identityKey: OMEMOIdentityKeyPair()).keyPair
            ),
            associatedData: associatedData, start: .sent(header, isConfirmed: false)
        )

        #expect(session.peerIdentityKey == nil)
    }
}
