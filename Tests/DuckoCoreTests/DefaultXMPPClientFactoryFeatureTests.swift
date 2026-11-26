import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

struct DefaultXMPPClientFactoryFeatureTests {
    @Test
    func `The production client advertises Bits of Binary`() async throws {
        let account = try Account(id: UUID(), jid: #require(BareJID.parse("alice@example.com")), isEnabled: true, connectOnLaunch: false, createdAt: Date())

        let (client, _) = await DefaultXMPPClientFactory().makeClient(account: account, secret: .password("secret"), resuming: nil, requireTLSOverride: nil, omemoService: nil)

        #expect(await client.availableFeatures.contains(XMPPNamespaces.bitsOfBinary))
    }
}
