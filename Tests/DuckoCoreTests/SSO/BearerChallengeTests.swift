import Foundation
import Testing
@testable import DuckoCore

struct BearerChallengeTests {
    @Test
    func `A challenge naming an https discovery URL decodes its status, scope and URL`() throws {
        let challenge = try BearerChallenge(
            json: #"{"status":"invalid_token","scope":"xmpp","openid-configuration":"https://auth.example.com/.well-known/openid-configuration"}"#
        )
        #expect(challenge.status == "invalid_token")
        #expect(challenge.scope == "xmpp")
        #expect(challenge.discoveryURL == URL(string: "https://auth.example.com/.well-known/openid-configuration"))
    }

    @Test
    func `An empty scope counts as none`() throws {
        let challenge = try BearerChallenge(json: #"{"scope":"","openid-configuration":"https://auth.example.com/.well-known/openid-configuration"}"#)
        #expect(challenge.scope == nil)
    }

    @Test(arguments: [
        #"{"status":"invalid_token"}"#,
        #"{"status":"invalid_token","openid-configuration":"http://auth.example.com/.well-known/openid-configuration"}"#,
        #"{"openid-configuration":"https:///.well-known/openid-configuration"}"#,
        #"{"openid-configuration":42}"#,
        "not json"
    ])
    func `A challenge without an https discovery URL fails closed`(json: String) {
        #expect(throws: SSOError.serverUnsupported) { try BearerChallenge(json: json) }
    }
}
