import CryptoKit
import Testing
@testable import DuckoXMPP

// MARK: - Base64 Tests

struct Base64Tests {
    @Test
    func `Encode empty`() {
        #expect(Base64.encode([]) == "")
    }

    @Test
    func `Decode empty`() {
        #expect(Base64.decode("") == [])
    }

    @Test(arguments: [
        "Hello, World!",
        "user",
        "pencil",
        "\0user\0pencil",
        "n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL"
    ])
    func `Encode/decode round-trip`(input: String) {
        let encoded = Base64.encode(input)
        let decoded = Base64.decodeString(encoded)
        #expect(decoded == input)
    }

    @Test(arguments: [
        ("", ""),
        ("f", "Zg=="),
        ("fo", "Zm8="),
        ("foo", "Zm9v"),
        ("foob", "Zm9vYg=="),
        ("fooba", "Zm9vYmE="),
        ("foobar", "Zm9vYmFy")
    ])
    func `Encode known vectors`(input: String, expected: String) {
        #expect(Base64.encode(input) == expected)
    }

    @Test
    func `Decode rejects invalid input`() {
        #expect(Base64.decode("!!!") == nil)
        #expect(Base64.decode("A") == nil) // not multiple of 4
    }

    @Test
    func `Decode rejects non-final padding`() {
        #expect(Base64.decode("AB==CD==") == nil) // padding in non-final quartet
    }

    @Test
    func `Decode rejects mismatched padding`() {
        #expect(Base64.decode("AB=A") == nil) // 3rd is = but 4th is not
    }

    @Test(arguments: ["\n", "\r", " ", "\t"])
    func `Only the strict decode rejects whitespace`(whitespace: String) {
        #expect(Base64.decode("AQ\(whitespace)ID") == [1, 2, 3])
        #expect(Base64.decodeStrict("AQ\(whitespace)ID") == nil)
        #expect(Base64.decodeStrict("AQID") == [1, 2, 3])
    }
}

// MARK: - SASL PLAIN Tests

struct SASLPlainTests {
    @Test
    func `Start produces correct auth element`() throws {
        var mechanism = SASLPlain()
        let auth = mechanism.start(authcid: "user", password: "pencil")

        #expect(auth.name == "auth")
        #expect(auth.namespace == saslNamespace)
        #expect(auth.attribute("mechanism") == "PLAIN")

        let payload = try #require(auth.textContent)
        let decoded = try #require(Base64.decode(payload))
        let expected: [UInt8] = [0] + Array("user".utf8) + [0] + Array("pencil".utf8)
        #expect(decoded == expected)
    }

    @Test
    func `Handle challenge returns failure`() {
        var mechanism = SASLPlain()
        _ = mechanism.start(authcid: "user", password: "pencil")
        let response = mechanism.handleChallenge(XMLElement(name: "challenge", namespace: saslNamespace))
        guard case .failure(.unsupportedSignInStep) = response else {
            Issue.record("Expected unsupportedSignInStep failure, got \(response)")
            return
        }
    }

    @Test
    func `Handle success returns success`() {
        var mechanism = SASLPlain()
        _ = mechanism.start(authcid: "user", password: "pencil")
        let response = mechanism.handleSuccess(XMLElement(name: "success", namespace: saslNamespace))
        guard case .success = response else {
            Issue.record("Expected success, got \(response)")
            return
        }
    }
}

// MARK: - SCRAM-SHA-1 Tests (RFC 5802 §5 test vector)

struct SCRAMSHA1Tests {
    // RFC 5802 §5 test vector
    private static let clientNonce = "fyko+d2lbbFgONRv9qkxdawL"
    private static let serverFirstMessage = "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=4096"
    private static let expectedServerSignature = "rmF9pqV8S7suAoZWja4dJRkFsKQ="

    @Test
    func `Full SCRAM-SHA-1 exchange with RFC 5802 test vector`() throws {
        var mechanism = SCRAM(
            mechanismName: SCRAMMechanismName.sha1, session: SCRAMState<Insecure.SHA1>(nonceGenerator: { Self.clientNonce })
        )
        let auth = mechanism.start(authcid: "user", password: "pencil")

        // Verify client-first-message
        let authPayload = try #require(auth.textContent)
        let clientFirst = try #require(Base64.decodeString(authPayload))
        #expect(clientFirst == "n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL")

        // Server sends challenge with server-first-message
        var challenge = XMLElement(name: "challenge", namespace: saslNamespace)
        challenge.addText(Base64.encode(Self.serverFirstMessage))

        let challengeResponse = mechanism.handleChallenge(challenge)
        guard case let .continueWith(responseElement) = challengeResponse else {
            Issue.record("Expected continueWith, got \(challengeResponse)")
            return
        }

        // Verify client-final-message
        let responsePayload = try #require(responseElement.textContent)
        let clientFinal = try #require(Base64.decodeString(responsePayload))
        #expect(clientFinal.hasPrefix("c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p="))

        // Server sends success with server signature
        var success = XMLElement(name: "success", namespace: saslNamespace)
        success.addText(Base64.encode("v=\(Self.expectedServerSignature)"))

        let successResponse = mechanism.handleSuccess(success)
        guard case .success = successResponse else {
            Issue.record("Expected success, got \(successResponse)")
            return
        }
    }

    @Test
    func `Client-first-message bare matches RFC 5802 §5`() {
        var state = SCRAMState<Insecure.SHA1>(nonceGenerator: { Self.clientNonce })
        let message = state.clientFirstMessage(authcid: "user", password: "pencil")
        #expect(message == "n,,n=user,r=fyko+d2lbbFgONRv9qkxdawL")
    }

    @Test
    func `Client-final-message proof matches RFC 5802 §5`() throws {
        var state = SCRAMState<Insecure.SHA1>(nonceGenerator: { Self.clientNonce })
        _ = state.clientFirstMessage(authcid: "user", password: "pencil")
        let result = state.clientFinalMessage(serverFirstMessage: Self.serverFirstMessage)
        let clientFinal = try result.get()
        #expect(clientFinal == "c=biws,r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,p=v0X8v3Bz2T0CJGbJQyF0X+HI4Ts=")
    }

    @Test
    func `Server signature verification matches RFC 5802 §5`() throws {
        var state = SCRAMState<Insecure.SHA1>(nonceGenerator: { Self.clientNonce })
        _ = state.clientFirstMessage(authcid: "user", password: "pencil")
        _ = state.clientFinalMessage(serverFirstMessage: Self.serverFirstMessage)
        let result = state.verifyServerFinal(serverFinalMessage: "v=\(Self.expectedServerSignature)")
        try result.get()
    }

    @Test
    func `Invalid server nonce rejected`() {
        var state = SCRAMState<Insecure.SHA1>(nonceGenerator: { Self.clientNonce })
        _ = state.clientFirstMessage(authcid: "user", password: "pencil")
        let result = state.clientFinalMessage(serverFirstMessage: "r=WRONG_NONCE,s=QSXCR+Q6sek8bf92,i=4096")
        guard case .failure(.invalidServerNonce) = result else {
            Issue.record("Expected invalidServerNonce, got \(result)")
            return
        }
    }

    @Test
    func `Iteration count below minimum rejected`() {
        var state = SCRAMState<Insecure.SHA1>(nonceGenerator: { Self.clientNonce })
        _ = state.clientFirstMessage(authcid: "user", password: "pencil")
        let result = state.clientFinalMessage(
            serverFirstMessage: "r=fyko+d2lbbFgONRv9qkxdawL3rfcNHYJY1ZVvWVs7j,s=QSXCR+Q6sek8bf92,i=100"
        )
        guard case .failure(.iterationCountTooLow(100)) = result else {
            Issue.record("Expected iterationCountTooLow(100), got \(result)")
            return
        }
    }

    @Test
    func `Wrong server signature rejected`() {
        var state = SCRAMState<Insecure.SHA1>(nonceGenerator: { Self.clientNonce })
        _ = state.clientFirstMessage(authcid: "user", password: "pencil")
        _ = state.clientFinalMessage(serverFirstMessage: Self.serverFirstMessage)
        let result = state.verifyServerFinal(serverFinalMessage: "v=AAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        guard case .failure(.serverSignatureMismatch) = result else {
            Issue.record("Expected serverSignatureMismatch, got \(result)")
            return
        }
    }

    @Test(arguments: [
        ("e=invalid-proof", SASLAuthError.scramServerError("invalid-proof")),
        ("x=unknown", SASLAuthError.serverProofMissing),
        ("v=!!!", SASLAuthError.invalidBase64)
    ])
    func `Server-final-message without a usable signature names why`(serverFinal: String, expected: SASLAuthError) {
        var state = SCRAMState<Insecure.SHA1>(nonceGenerator: { Self.clientNonce })
        _ = state.clientFirstMessage(authcid: "user", password: "pencil")
        _ = state.clientFinalMessage(serverFirstMessage: Self.serverFirstMessage)
        let result = state.verifyServerFinal(serverFinalMessage: serverFinal)
        guard case let .failure(error) = result else {
            Issue.record("Expected \(expected), got \(result)")
            return
        }
        #expect(error == expected)
    }

    @Test
    func `Username escaping: = becomes =3D, comma becomes =2C`() {
        var state = SCRAMState<Insecure.SHA1>(nonceGenerator: { "testnonce" })
        let message = state.clientFirstMessage(authcid: "user=name,test", password: "pass")
        #expect(message.contains("n=user=3Dname=2Ctest"))
    }
}

// MARK: - SCRAM-SHA-256 Tests (RFC 7677 §3 test vector)

struct SCRAMSHA256Tests {
    // RFC 7677 §3 test vector
    private static let clientNonce = "rOprNGfwEbeRWgbNEkqO"
    private static let serverFirstMessage =
        "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
    private static let expectedServerSignature = "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="

    @Test
    func `Full SCRAM-SHA-256 exchange with RFC 7677 test vector`() throws {
        var mechanism = SCRAM(
            mechanismName: SCRAMMechanismName.sha256, session: SCRAMState<SHA256>(nonceGenerator: { Self.clientNonce })
        )
        let auth = mechanism.start(authcid: "user", password: "pencil")

        // Verify client-first-message
        let authPayload = try #require(auth.textContent)
        let clientFirst = try #require(Base64.decodeString(authPayload))
        #expect(clientFirst == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")

        // Server sends challenge
        var challenge = XMLElement(name: "challenge", namespace: saslNamespace)
        challenge.addText(Base64.encode(Self.serverFirstMessage))

        let challengeResponse = mechanism.handleChallenge(challenge)
        guard case let .continueWith(responseElement) = challengeResponse else {
            Issue.record("Expected continueWith, got \(challengeResponse)")
            return
        }

        // Verify client-final-message
        let responsePayload = try #require(responseElement.textContent)
        let clientFinal = try #require(Base64.decodeString(responsePayload))
        #expect(clientFinal.hasPrefix("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p="))

        // Server sends success
        var success = XMLElement(name: "success", namespace: saslNamespace)
        success.addText(Base64.encode("v=\(Self.expectedServerSignature)"))

        let successResponse = mechanism.handleSuccess(success)
        guard case .success = successResponse else {
            Issue.record("Expected success, got \(successResponse)")
            return
        }
    }

    @Test
    func `Client-final-message proof matches RFC 7677 §3`() throws {
        var state = SCRAMState<SHA256>(nonceGenerator: { Self.clientNonce })
        _ = state.clientFirstMessage(authcid: "user", password: "pencil")
        let result = state.clientFinalMessage(serverFirstMessage: Self.serverFirstMessage)
        let clientFinal = try result.get()
        #expect(
            clientFinal
                == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
        )
    }

    @Test
    func `Invalid base64 in challenge rejected`() {
        var mechanism = SCRAM(
            mechanismName: SCRAMMechanismName.sha256, session: SCRAMState<SHA256>(nonceGenerator: { Self.clientNonce })
        )
        _ = mechanism.start(authcid: "user", password: "pencil")

        var challenge = XMLElement(name: "challenge", namespace: saslNamespace)
        challenge.addText("!!!invalid!!!")

        let response = mechanism.handleChallenge(challenge)
        guard case .failure(.invalidBase64) = response else {
            Issue.record("Expected invalidBase64, got \(response)")
            return
        }
    }

    @Test
    func `Malformed challenge rejected`() {
        var state = SCRAMState<SHA256>(nonceGenerator: { Self.clientNonce })
        _ = state.clientFirstMessage(authcid: "user", password: "pencil")
        let result = state.clientFinalMessage(serverFirstMessage: "garbage")
        guard case .failure(.malformedChallenge) = result else {
            Issue.record("Expected malformedChallenge, got \(result)")
            return
        }
    }
}

// MARK: - SCRAM Iteration Bounds Tests (RFC 5802 §5.1, §9)

struct SCRAMIterationBoundsTests {
    @Test(arguments: [
        (SCRAMMechanismName.sha3_512, 600_000), (SCRAMMechanismName.sha512, 600_000),
        (SCRAMMechanismName.sha256, 600_000), (SCRAMMechanismName.sha1, 1_400_000)
    ])
    func `Each mechanism accepts 4096 through its own hash's cap`(mechanism: String, cap: Int) throws {
        // The salt isn't base64, so a count within the bounds fails on the salt before any key is derived.
        let cases: [(Int, SASLAuthError)] = [
            (4095, .iterationCountTooLow(4095)), (4096, .invalidBase64), (cap, .invalidBase64), (cap + 1, .iterationCountTooHigh(cap + 1))
        ]
        for (iterations, error) in cases {
            var session = try #require(makeSCRAMSession(mechanism, channelBinding: .none, downgradeContext: .empty))
            let nonce = try #require(session.clientFirstMessage(authcid: "user", password: "pencil").components(separatedBy: ",r=").last)
            let result = session.clientFinalMessage(serverFirstMessage: "r=\(nonce)srv,s=!!!,i=\(iterations)")
            #expect(throws: error) { try result.get() }
        }
    }
}

// MARK: - SASL Failure Tests (RFC 6120 §6.5)

struct SASLFailureTests {
    @Test(arguments: [
        ("aborted", AuthenticationFailure.Kind.other, "Aborted by the server"),
        ("account-disabled", .other, "The account is disabled"),
        ("credentials-expired", .other, "The password has expired"),
        ("encryption-required", .other, "The server requires an encrypted connection"),
        ("incorrect-encoding", .other, "The server rejected a malformed authentication request"),
        ("invalid-authzid", .other, "The server rejected the authorization identity"),
        ("invalid-mechanism", .other, "The server rejected the authentication mechanism"),
        ("malformed-request", .other, "The server rejected a malformed authentication request"),
        ("mechanism-too-weak", .other, "The server requires a stronger authentication mechanism"),
        ("not-authorized", .credentialsRejected, "Incorrect username or password"),
        ("temporary-auth-failure", .temporary, "Temporary server failure, try again later"),
        ("x-unknown", .other, "The server refused the sign-in")
    ])
    func `Each failure condition has its kind and reason, and keeps the raw condition`(
        condition: String, kind: AuthenticationFailure.Kind, message: String
    ) {
        let failure = AuthenticationFailure(SASLAuthError.serverFailure(condition: condition, text: nil))
        #expect(failure.kind == kind)
        #expect(failure.message == message)
        #expect(failure.serverCondition == condition)
    }

    @Test
    func `An application-specific child does not replace the failure condition`() {
        var failure = XMLElement(name: "failure", namespace: XMPPNamespaces.sasl2)
        failure.addChild(XMLElement(name: "not-authorized", namespace: "urn:ietf:params:xml:ns:xmpp-sasl"))
        failure.addChild(XMLElement(name: "lockout", namespace: "urn:example:app"))

        #expect(SASLAuthError.parse(failure: failure) == .serverFailure(condition: "not-authorized", text: nil))
    }
}

// MARK: - SCRAM Server Error Tests (RFC 5802 §7)

struct SCRAMServerErrorTests {
    private static let tampering = ", which can mean the connection is being tampered with"

    @Test(arguments: [
        ("invalid-proof", AuthenticationFailure.Kind.credentialsRejected, "Incorrect username or password"),
        ("unknown-user", .credentialsRejected, "Incorrect username or password"),
        ("no-resources", .temporary, "Temporary server failure, try again later"),
        ("invalid-encoding", .other, "The server rejected a malformed authentication request"),
        ("invalid-username-encoding", .other, "The server rejected a malformed authentication request"),
        ("extensions-not-supported", .other, "The server does not support a required sign-in extension"),
        ("channel-binding-not-supported", .other, "The server does not support the sign-in protection this client used"),
        ("unsupported-channel-binding-type", .other, "The server does not support the sign-in protection this client used"),
        ("channel-bindings-dont-match", .other, "The server saw different connection security details than this client sent" + tampering),
        ("server-does-support-channel-binding", .other, "The server supports sign-in protection that its sign-in options did not offer" + tampering),
        ("other-error", .other, "The server refused the sign-in"),
        ("x-unknown", .other, "The server refused the sign-in")
    ])
    func `Each server error value has its kind and reason, and keeps the raw value`(
        value: String, kind: AuthenticationFailure.Kind, message: String
    ) {
        let failure = AuthenticationFailure(SASLAuthError.scramServerError(value))
        #expect(failure.kind == kind)
        #expect(failure.message == message)
        #expect(failure.serverCondition == value)
    }
}
