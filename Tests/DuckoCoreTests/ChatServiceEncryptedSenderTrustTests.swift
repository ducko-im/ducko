import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let contact = BareJID(localPart: "bob", domainPart: "example.com")!

/// A message decrypted from a device the user has not trusted for encryption is marked, so the user can tell it from
/// one sent by a device they trust.
@MainActor
struct ChatServiceEncryptedSenderTrustTests {
    enum Origin: CaseIterable {
        case live, carbon
    }

    @Test(arguments: Origin.allCases, [OMEMOTrustLevel.trusted, .untrusted])
    func `a decrypted message is marked when its sending device's trust row does not allow encrypting to it`(
        origin: Origin, trust: OMEMOTrustLevel
    ) async throws {
        let harness = try await EncryptedSendHarness.connect()
        try await harness.omemoStore.saveTrust(OMEMOTrust(
            accountJID: testJIDString, peerJID: contact.description, deviceID: 200, fingerprint: "", trustLevel: trust
        ))
        let message = try await harness.sentByBob("hello", id: "b1")

        switch origin {
        case .live:
            let module = try #require(await harness.accountService.client(for: harness.accountID)?.module(ofType: OMEMOModule.self))
            let outcome = try #require(module.receiveForwardedMessage(message))
            await harness.omemoService.handleEvent(
                .omemoEncryptedMessageReceived(message: message, outcome: outcome, roomAuthor: nil), accountID: harness.accountID
            )
        case .carbon:
            await harness.omemoService.handleEncryptedCarbon(
                ForwardedMessage(message: message, timestamp: nil), isOutgoing: false, accountID: harness.accountID
            )
        }

        let stored = try #require(await harness.transcripts.messages.last)
        #expect(stored.body == "hello")
        #expect(stored.isFromUntrustedDevice == (trust == .untrusted))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }
}
