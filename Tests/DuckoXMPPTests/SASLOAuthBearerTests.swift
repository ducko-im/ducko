import Testing
@testable import DuckoXMPP

// MARK: - Helpers

/// The access token of RFC 7628 §4.1.
private let token = "vF9dft4qmTc2Nvb3RlckBhbHRhdmlzdGEuY29tCg=="

/// An RFC 7628 §3.2.2 error challenge naming the server's authorization server.
private let errorChallenge =
    #"{"status":"invalid_token","scope":"xmpp","openid-configuration":"https://auth.example.com/.well-known/openid-configuration"}"#

/// What one step of a sign-in produced, in a form both SASL profiles share.
private enum Step: Equatable {
    case reply(name: String, namespace: String?, payload: [UInt8]?)
    case success
    case failure(SASLAuthError)
}

enum SASLProfile: CaseIterable {
    case sasl1
    case sasl2

    var namespace: String {
        switch self {
        case .sasl1: saslNamespace
        case .sasl2: XMPPNamespaces.sasl2
        }
    }

    func selectedMechanism(
        on features: XMLElement, secret: SignInSecret, tlsActive: Bool = true,
        channelBindings: [ChannelBindingType: [UInt8]] = [:], allowsPLAIN: Bool = false
    ) throws(SASLAuthError) -> String? {
        switch self {
        case .sasl1:
            var auth = SASLAuthenticator()
            return try auth.begin(
                features: features, authcid: "user", secret: secret, tlsActive: tlsActive, channelBindings: channelBindings,
                allowsPLAIN: allowsPLAIN
            ).attribute("mechanism")
        case .sasl2:
            var auth = SASL2Authenticator()
            return try auth.begin(
                features: features, authcid: "user", secret: secret, tlsActive: tlsActive, inlinePayloads: [],
                channelBindings: channelBindings, allowsPLAIN: allowsPLAIN
            ).attribute("mechanism")
        }
    }
}

/// A bearer sign-in over SASL1 or SASL2.
private struct BearerExchange {
    let profile: SASLProfile
    private var sasl1 = SASLAuthenticator()
    private var sasl2 = SASL2Authenticator()

    init(_ profile: SASLProfile) {
        self.profile = profile
    }

    /// Begins a sign-in with `token` on an offer of `mechanisms` over TLS, returning the decoded initial response.
    mutating func begin(token: String, mechanisms: [String] = ["SCRAM-SHA-256", "OAUTHBEARER"]) throws -> [UInt8]? {
        let features = try stanza(offer(mechanisms))
        switch profile {
        case .sasl1:
            let auth = try sasl1.begin(features: features, authcid: "user", secret: .bearerToken(token), tlsActive: true)
            #expect(auth.attribute("mechanism") == "OAUTHBEARER")
            return auth.textContent.flatMap(Base64.decode)
        case .sasl2:
            let authenticate = try sasl2.begin(
                features: features, authcid: "user", secret: .bearerToken(token), tlsActive: true, inlinePayloads: []
            )
            #expect(authenticate.attribute("mechanism") == "OAUTHBEARER")
            return authenticate.childText(named: "initial-response").flatMap(Base64.decode)
        }
    }

    /// Feeds the server's `<challenge>` carrying `payload`, base64-encoded.
    mutating func challenge(_ payload: [UInt8]) throws -> Step {
        try receive("<challenge xmlns='\(profile.namespace)'>\(Base64.encode(payload))</challenge>")
    }

    mutating func failure(_ condition: String, text: String? = nil) throws -> Step {
        let textElement = text.map { "<text>\($0)</text>" } ?? ""
        return try receive(
            "<failure xmlns='\(profile.namespace)'><\(condition) xmlns='\(saslNamespace)'/>\(textElement)</failure>"
        )
    }

    /// Feeds the server's `<success>`, which names the account's session on SASL2.
    mutating func success() throws -> Step {
        switch profile {
        case .sasl1:
            try receive("<success xmlns='\(saslNamespace)'/>")
        case .sasl2:
            try receive(
                "<success xmlns='\(XMPPNamespaces.sasl2)'><authorization-identifier>user@example.com/res</authorization-identifier></success>"
            )
        }
    }

    private mutating func receive(_ xml: String) throws -> Step {
        let element = try stanza(xml)
        switch profile {
        case .sasl1:
            return switch sasl1.receive(element) {
            case let .continueWith(reply): .reply(name: reply.name, namespace: reply.namespace, payload: reply.textContent.flatMap(Base64.decode))
            case .success: .success
            case let .failure(error): .failure(error)
            }
        case .sasl2:
            return switch sasl2.receive(element) {
            case let .continueWith(reply): .reply(name: reply.name, namespace: reply.namespace, payload: reply.textContent.flatMap(Base64.decode))
            case .success: .success
            case let .failure(error): .failure(error)
            }
        }
    }
}

// MARK: - Tests

enum SASLOAuthBearerTests {
    struct InitialResponse {
        @Test
        func `A token goes out as the GS2 header and auth key-value, byte for byte`() throws {
            var bearer = SASLOAuthBearer()
            let bytes = try bearer.initialResponse(token: token)
            #expect(bytes == Array("n,,\u{1}auth=Bearer vF9dft4qmTc2Nvb3RlckBhbHRhdmlzdGEuY29tCg==\u{1}\u{1}".utf8))
            #expect(Base64.encode(bytes) == "biwsAWF1dGg9QmVhcmVyIHZGOWRmdDRxbVRjMk52YjNSbGNrQmhiSFJoZG1semRHRXVZMjl0Q2c9PQEB")
        }

        @Test
        func `The empty probe is the exact message the server answers with its authorization server`() throws {
            var bearer = SASLOAuthBearer()
            let bytes = try bearer.initialResponse(token: "")
            #expect(bytes == [0x6E, 0x2C, 0x2C, 0x01] + Array("auth=Bearer ".utf8) + [0x01, 0x01])
            #expect(Base64.encode(bytes) == "biwsAWF1dGg9QmVhcmVyIAEB")
        }

        @Test(arguments: SASLProfile.allCases)
        func `Each profile sends the token as its initial response`(profile: SASLProfile) throws {
            var exchange = BearerExchange(profile)
            #expect(try exchange.begin(token: token) == Array("n,,\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8))
        }

        @Test(arguments: ["abc", "a-._~+/9Z", "abc=", "abc==", "secret-token:MjQ0Nzc5", "abc,def", "=abc", "ab=c"])
        func `A token of visible ASCII is accepted`(candidate: String) throws {
            var bearer = SASLOAuthBearer()
            #expect(try bearer.initialResponse(token: candidate) == Array("n,,\u{1}auth=Bearer \(candidate)\u{1}\u{1}".utf8))
        }

        @Test(arguments: ["abc\u{1}auth=Bearer x", "abc def", "abc\tdef", "abc\n", "abc\u{7F}", "tökén"])
        func `A token with a control byte, a space or non-ASCII is refused before anything is sent`(candidate: String) {
            var bearer = SASLOAuthBearer()
            #expect(throws: SASLAuthError.unsendableBearerToken) { try bearer.initialResponse(token: candidate) }
        }

        @Test(arguments: SASLProfile.allCases, ["abc\u{1}def", "abc def", "abc\tdef"])
        func `A framing byte in the token fails the sign-in before any element is produced`(
            profile: SASLProfile, candidate: String
        ) {
            var exchange = BearerExchange(profile)
            #expect(throws: SASLAuthError.unsendableBearerToken) { try exchange.begin(token: candidate) }
        }
    }

    struct ErrorChallenge {
        @Test(arguments: SASLProfile.allCases)
        func `An error challenge is answered with a single 0x01, and the failure after it carries the challenge and condition`(
            profile: SASLProfile
        ) throws {
            var exchange = BearerExchange(profile)
            _ = try exchange.begin(token: token)

            #expect(try exchange.challenge(Array(errorChallenge.utf8)) == .reply(name: "response", namespace: profile.namespace, payload: [0x01]))
            #expect(try exchange.failure("not-authorized", text: "Token expired") == .failure(
                .bearerTokenRejected(challenge: errorChallenge, condition: "not-authorized", text: "Token expired")
            ))
        }

        @Test(arguments: SASLProfile.allCases)
        func `A failure without an error challenge carries no challenge`(profile: SASLProfile) throws {
            var exchange = BearerExchange(profile)
            _ = try exchange.begin(token: token)

            #expect(try exchange.failure("not-authorized") == .failure(
                .bearerTokenRejected(challenge: nil, condition: "not-authorized", text: nil)
            ))
        }

        @Test(arguments: SASLProfile.allCases)
        func `A challenge that is not UTF-8 fails the sign-in`(profile: SASLProfile) throws {
            var exchange = BearerExchange(profile)
            _ = try exchange.begin(token: token)

            #expect(try exchange.challenge([0xC3, 0x28]) == .failure(.invalidBase64))
        }

        @Test
        func `The mechanism keeps the challenge only when it is strict UTF-8`() {
            var bearer = SASLOAuthBearer()
            guard case .failure(.invalidBase64) = bearer.handleChallenge([0x7B, 0xFF, 0x7D]) else {
                Issue.record("Expected invalidBase64")
                return
            }
            #expect(bearer.handleFailure(XMLElement(name: "failure", namespace: saslNamespace))
                == .bearerTokenRejected(challenge: nil, condition: "unknown", text: nil))
        }
    }

    struct Success {
        @Test(arguments: SASLProfile.allCases)
        func `A success after the token signs in`(profile: SASLProfile) throws {
            var exchange = BearerExchange(profile)
            _ = try exchange.begin(token: token)
            #expect(try exchange.success() == .success)
        }

        @Test(arguments: SASLProfile.allCases)
        func `A success after the empty probe is not a sign-in`(profile: SASLProfile) throws {
            var exchange = BearerExchange(profile)
            _ = try exchange.begin(token: "")
            #expect(try exchange.success() == .failure(.unexpectedReply))
        }

        @Test(arguments: SASLProfile.allCases)
        func `A success after an acknowledged error challenge is not a sign-in`(profile: SASLProfile) throws {
            var exchange = BearerExchange(profile)
            _ = try exchange.begin(token: token)
            _ = try exchange.challenge(Array(errorChallenge.utf8))
            #expect(try exchange.success() == .failure(.unexpectedReply))
        }
    }

    struct Classification {
        @Test(arguments: [
            ("not-authorized", AuthenticationFailure.Kind.credentialsRejected),
            ("temporary-auth-failure", .temporary),
            ("account-disabled", .other),
            ("x-unknown", .other)
        ])
        func `A rejected token is classified by its condition and keeps the challenge`(
            condition: String, kind: AuthenticationFailure.Kind
        ) {
            let failure = AuthenticationFailure(.bearerTokenRejected(challenge: errorChallenge, condition: condition, text: nil))
            #expect(failure.kind == kind)
            #expect(failure.serverCondition == condition)
            #expect(failure.bearerChallenge == errorChallenge)
        }

        @Test(arguments: [
            (SASLAuthError.bearerTokenRejected(challenge: nil, condition: "not-authorized", text: "Token expired"), "Token expired"),
            (.bearerTokenRejected(challenge: nil, condition: "temporary-auth-failure", text: nil), "Temporary server failure, try again later"),
            (.bearerTokenRejected(challenge: nil, condition: "x-unknown", text: " "), "The server refused the sign-in")
        ])
        func `A rejected token's text prefers the server's text, then the condition's phrase`(error: SASLAuthError, expected: String) {
            #expect(error.displayText == expected)
        }

        @Test(arguments: [
            (SASLAuthError.browserSignInOnly, AuthenticationFailure.Kind.browserSignInOnly),
            (.browserSignInUnavailable, .other),
            (.browserSignInNeedsTLS, .other),
            (.unsendableBearerToken, .other),
            (.accountMismatch(bound: "bob@example.com", expected: "alice@example.com"), .accountMismatch)
        ])
        func `Browser sign-in refusals have their kinds`(error: SASLAuthError, kind: AuthenticationFailure.Kind) {
            let failure = AuthenticationFailure(error)
            #expect(failure.kind == kind)
            #expect(failure.message == error.displayText)
            #expect(failure.serverCondition == nil)
            #expect(failure.bearerChallenge == nil)
        }
    }

    struct Logging {
        @Test
        func `Describing a failed sign-in names neither the challenge nor the server's text`() {
            let challengeSentinel = "CHALLENGE-SENTINEL-7f3a"
            let textSentinel = "TEXT-SENTINEL-91c2"
            let failure = AuthenticationFailure(
                .bearerTokenRejected(challenge: challengeSentinel, condition: "not-authorized", text: textSentinel)
            )
            #expect(failure.message == textSentinel)
            #expect(failure.bearerChallenge == challengeSentinel)

            for described in [String(describing: XMPPClientError.authenticationFailed(failure)), "\(failure)", String(reflecting: failure)] {
                #expect(!described.contains(challengeSentinel))
                #expect(!described.contains(textSentinel))
            }
            #expect(String(describing: failure).contains("credentialsRejected"))
            #expect(String(describing: failure).contains("not-authorized"))
        }
    }
}
