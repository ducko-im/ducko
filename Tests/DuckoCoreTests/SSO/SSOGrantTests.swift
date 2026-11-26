import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

struct SSOGrantTests {
    @Test
    func `A grant round-trips through the credential store`() throws {
        let store = MockCredentialStore()
        let jid = try #require(BareJID.parse("alice@example.com"))
        let grant = SSOFixtures.grant(expiresAt: Date(timeIntervalSince1970: 1_800_000_000), adminClient: true)
        try store.saveGrant(grant, for: jid)
        #expect(try store.loadGrant(for: jid) == grant)
        #expect(try store.loadSecret(for: "sso-grant:alice@example.com") != nil)
    }

    @Test
    func `A grant's description names no token`() {
        let description = String(describing: SSOFixtures.grant(access: "sentinel-access", refresh: "sentinel-refresh"))
        #expect(!description.contains("sentinel"))
    }

    @Test
    func `The longest-lived token is revoked`() {
        #expect(SSOFixtures.grant(access: "a", refresh: "r").revocableToken == ("r", "refresh_token"))
        #expect(SSOFixtures.grant(access: "a", refresh: nil).revocableToken == ("a", "access_token"))
    }
}
