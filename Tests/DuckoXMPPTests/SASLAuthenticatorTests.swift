import CryptoKit
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

/// Builds a `<stream:features>` element with the given SASL mechanism names.
private func features(mechanisms: [String]) -> XMLElement {
    var mechanismsElement = XMLElement(name: "mechanisms", namespace: saslNamespace)
    for name in mechanisms {
        var mechanism = XMLElement(name: "mechanism")
        mechanism.addText(name)
        mechanismsElement.addChild(mechanism)
    }
    var features = XMLElement(name: "stream:features")
    features.addChild(mechanismsElement)
    return features
}

// MARK: - Tests

enum SASLAuthenticatorTests {
    struct MechanismSelection {
        @Test
        func `Selects SCRAM-SHA-256 when all offered`() throws {
            var auth = SASLAuthenticator()
            let element = try auth.begin(
                features: features(mechanisms: ["PLAIN", "SCRAM-SHA-1", "SCRAM-SHA-256"]),
                authcid: "user",
                password: "pencil"
            )
            #expect(element.attribute("mechanism") == "SCRAM-SHA-256")
        }

        @Test
        func `Selects SCRAM-SHA-1 when SHA-256 unavailable`() throws {
            var auth = SASLAuthenticator()
            let element = try auth.begin(
                features: features(mechanisms: ["PLAIN", "SCRAM-SHA-1"]),
                authcid: "user",
                password: "pencil"
            )
            #expect(element.attribute("mechanism") == "SCRAM-SHA-1")
        }

        @Test
        func `Falls back to PLAIN when no SCRAM available`() throws {
            var auth = SASLAuthenticator()
            let element = try auth.begin(
                features: features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil"
            )
            #expect(element.attribute("mechanism") == "PLAIN")
        }

        @Test
        func `Matches mechanism names case-insensitively`() throws {
            var auth = SASLAuthenticator()
            let element = try auth.begin(
                features: features(mechanisms: ["plain", "scram-sha-1"]),
                authcid: "user",
                password: "pencil"
            )
            #expect(element.attribute("mechanism") == "SCRAM-SHA-1")
        }

        @Test(arguments: [
            (["SCRAM-SHA-256", "PLAIN"], "SCRAM-SHA-256"),
            (["SCRAM-SHA-1"], "SCRAM-SHA-1")
        ])
        func `With SCRAM required, an offer that includes SCRAM signs in with it`(offered: [String], expected: String) throws {
            var auth = SASLAuthenticator()
            let element = try auth.begin(
                features: features(mechanisms: offered),
                authcid: "user",
                password: "pencil",
                requiresSCRAM: true
            )
            #expect(element.attribute("mechanism") == expected)
        }

        @Test
        func `Throws when no supported mechanism`() {
            var auth = SASLAuthenticator()
            #expect(throws: SASLAuthError.self) {
                try auth.begin(
                    features: features(mechanisms: ["EXTERNAL", "GSSAPI"]),
                    authcid: "user",
                    password: "pencil"
                )
            }
        }

        @Test
        func `Throws when no mechanisms element`() {
            var auth = SASLAuthenticator()
            let emptyFeatures = XMLElement(name: "stream:features")
            #expect(throws: SASLAuthError.self) {
                try auth.begin(features: emptyFeatures, authcid: "user", password: "pencil")
            }
        }
    }

    struct PLUSMechanismSelection {
        @Test
        func `Does not offer PLUS when no CB data`() throws {
            var auth = SASLAuthenticator()
            let element = try auth.begin(
                features: features(mechanisms: ["SCRAM-SHA-256-PLUS", "PLAIN"]),
                authcid: "user",
                password: "pencil"
            )
            // Without CB data, PLUS is not in preference list, so falls through to PLAIN
            #expect(element.attribute("mechanism") == "PLAIN")
        }

        @Test
        func `Skips the unsupported EXTERNAL mechanism`() throws {
            var auth = SASLAuthenticator()
            let element = try auth.begin(
                features: features(mechanisms: ["EXTERNAL", "SCRAM-SHA-256", "PLAIN"]),
                authcid: "user",
                password: "pencil"
            )
            #expect(element.attribute("mechanism") == "SCRAM-SHA-256")
        }

        @Test
        func `Throws when only EXTERNAL is offered`() {
            var auth = SASLAuthenticator()
            #expect(throws: SASLAuthError.self) {
                try auth.begin(
                    features: features(mechanisms: ["EXTERNAL"]),
                    authcid: "user",
                    password: "pencil"
                )
            }
        }
    }

    struct PLAINFlow {
        @Test
        func `Full PLAIN flow: begin → success`() throws {
            var auth = SASLAuthenticator()
            let authElement = try auth.begin(
                features: features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil"
            )

            #expect(authElement.name == "auth")
            #expect(authElement.namespace == saslNamespace)

            let success = XMLElement(name: "success", namespace: saslNamespace)
            let response = auth.receive(success)
            guard case .success = response else {
                Issue.record("Expected success, got \(response)")
                return
            }
        }
    }

    struct FailureHandling {
        @Test
        func `Server failure with condition and text`() throws {
            var auth = SASLAuthenticator()
            _ = try auth.begin(
                features: features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil"
            )

            var failure = XMLElement(name: "failure", namespace: saslNamespace)
            failure.addChild(XMLElement(name: "not-authorized"))
            var text = XMLElement(name: "text")
            text.addText("Invalid credentials")
            failure.addChild(text)

            let response = auth.receive(failure)
            guard case let .failure(.serverFailure(condition, errorText)) = response else {
                Issue.record("Expected serverFailure, got \(response)")
                return
            }
            #expect(condition == "not-authorized")
            #expect(errorText == "Invalid credentials")
        }

        @Test
        func `Server failure with condition only`() throws {
            var auth = SASLAuthenticator()
            _ = try auth.begin(
                features: features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil"
            )

            var failure = XMLElement(name: "failure", namespace: saslNamespace)
            failure.addChild(XMLElement(name: "temporary-auth-failure"))

            let response = auth.receive(failure)
            guard case let .failure(.serverFailure(condition, errorText)) = response else {
                Issue.record("Expected serverFailure, got \(response)")
                return
            }
            #expect(condition == "temporary-auth-failure")
            #expect(errorText == nil)
        }

        @Test(arguments: [
            (SASLAuthError.serverFailure(condition: "not-authorized", text: "Invalid credentials"), "Invalid credentials"),
            (SASLAuthError.serverFailure(condition: "not-authorized", text: nil), "Incorrect username or password"),
            (SASLAuthError.serverFailure(condition: "not-authorized", text: "  "), "Incorrect username or password"),
            (SASLAuthError.serverFailure(condition: "x-custom", text: nil), "The server refused the sign-in")
        ])
        func `Server failure display text prefers server text, then condition phrase, then a general refusal`(error: SASLAuthError, expected: String) {
            #expect(error.displayText == expected)
        }

        @Test
        func `Receive without begin returns invalidState`() {
            var auth = SASLAuthenticator()
            let response = auth.receive(XMLElement(name: "success", namespace: saslNamespace))
            guard case .failure(.invalidState) = response else {
                Issue.record("Expected invalidState, got \(response)")
                return
            }
        }

        @Test
        func `Unexpected element name returns invalidState`() throws {
            var auth = SASLAuthenticator()
            _ = try auth.begin(
                features: features(mechanisms: ["PLAIN"]),
                authcid: "user",
                password: "pencil"
            )

            let response = auth.receive(XMLElement(name: "unknown"))
            guard case .failure(.invalidState) = response else {
                Issue.record("Expected invalidState, got \(response)")
                return
            }
        }
    }

    struct SCRAMFlow {
        @Test
        func `Full SCRAM-SHA-256 flow through authenticator`() {
            let clientNonce = "rOprNGfwEbeRWgbNEkqO"
            var mech = SCRAM<SHA256>(
                mechanismName: SCRAMMechanismName.sha256, nonceGenerator: { clientNonce }
            )
            let authElement = mech.start(authcid: "user", password: "pencil")
            var auth = SASLAuthenticator(mechanism: .scram256(mech))

            #expect(authElement.name == "auth")

            // Server challenge
            let serverFirst =
                "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
            var challenge = XMLElement(name: "challenge", namespace: saslNamespace)
            challenge.addText(Base64.encode(serverFirst))

            let challengeResult = auth.receive(challenge)
            guard case let .continueWith(responseElement) = challengeResult else {
                Issue.record("Expected continueWith, got \(challengeResult)")
                return
            }
            #expect(responseElement.name == "response")
            #expect(responseElement.namespace == saslNamespace)

            // Server success
            let serverSignature = "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="
            var success = XMLElement(name: "success", namespace: saslNamespace)
            success.addText(Base64.encode("v=\(serverSignature)"))

            let successResult = auth.receive(success)
            guard case .success = successResult else {
                Issue.record("Expected success, got \(successResult)")
                return
            }
        }
    }
}
