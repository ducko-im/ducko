import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private let upgradeTask = "UPGR-SCRAM-SHA-256"

private func continueElement(additionalData: String?, tasks: [String] = [upgradeTask]) -> String {
    let data = additionalData.map { "<additional-data>\($0)</additional-data>" } ?? ""
    return "<continue xmlns='urn:xmpp:sasl:2'>\(data)<tasks>\(tasks.map { "<task>\($0)</task>" }.joined())</tasks></continue>"
}

private func saltTaskData(iterations: Int = 4096) -> String {
    "<task-data xmlns='urn:xmpp:sasl:2'><salt xmlns='urn:xmpp:scram-upgrade:0' iterations='\(iterations)'>\(capturedUpgradeSalt)</salt></task-data>"
}

/// A SASL2 success that starts a Bind 2 session, followed by the authenticated stream's features.
private func successElement(additionalData: String?) -> String {
    let data = additionalData.map { "<additional-data>\($0)</additional-data>" } ?? ""
    return """
    <success xmlns='urn:xmpp:sasl:2'>\(data)\
    <authorization-identifier>user@example.com/ducko</authorization-identifier>\
    <bound xmlns='urn:xmpp:bind:0'/>\
    </success>
    """ + testPostSASL2Features
}

/// A SASL2 sign-in with SCRAM-SHA-1-PLUS that asks for the upgrade to SCRAM-SHA-256, played up to the client's proof.
private struct UpgradeSignIn {
    let mock: MockTransport
    let client: XMPPClient
    let connect: Task<Void, any Error>
    /// The base64 server-final message answering the client's proof, signed with the server's password.
    let serverFinal: String

    init(serverPassword: String = "pencil") async throws {
        self.mock = MockTransport()
        await mock.setChannelBindings(tls13Bindings)
        let client = XMPPClient(
            domain: "example.com", credentials: .init(username: "user", password: "pencil"), transport: mock, requireTLS: false
        )
        self.client = client
        self.connect = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
        var server = SCRAMTestServer(password: serverPassword, mechanism: SCRAMMechanismName.sha1Plus)

        await mock.waitForSent(count: 1) // stream opening
        await mock.simulateReceive(testServerStreamOpen)
        await mock.simulateReceive(offer(
            [SCRAMMechanismName.sha1Plus, SCRAMMechanismName.sha1], types: ["tls-exporter"], upgrades: [upgradeTask]
        ))
        let start = try #require(await nextSent(mock, before: connect) { $0.hasPrefix("<authenticate ") })
        let first = try server.serverFirst(answering: #require(SCRAMTestServer.payload(in: start)))
        await mock.simulateReceive("<challenge xmlns='urn:xmpp:sasl:2'>\(first)</challenge>")
        let response = try #require(await nextSent(mock, before: connect) { $0.hasPrefix("<response ") })
        self.serverFinal = try server.serverFinal(answering: #require(SCRAMTestServer.payload(in: response)))
    }

    /// The next SASL2 element named `name` the client sends, or `nil` once the sign-in ends without one.
    func awaitSent(_ name: String) async throws -> XMLElement? {
        try await nextSent(mock, before: connect) { sent in
            (try? stanza(sent)).map { $0.name == name && $0.namespace == XMPPNamespaces.sasl2 } ?? false
        }.map(stanza)
    }

    /// How many SASL2 elements named `name` the client sent.
    func sentCount(_ name: String) async -> Int {
        await sentElements(on: mock).count { $0.name == name && $0.namespace == XMPPNamespaces.sasl2 }
    }

    /// Answers the client's proof with a verified `<continue>` and the salt, and returns the client's `<hash>`.
    func playUpgrade() async throws -> XMLElement? {
        await mock.simulateReceive(continueElement(additionalData: serverFinal))
        let next = try #require(try await awaitSent("next"))
        #expect(next.attribute("task") == upgradeTask)
        await mock.simulateReceive(saltTaskData())
        return try await awaitSent("task-data")?.child(named: "hash", namespace: XMPPNamespaces.scramUpgrade)
    }

    /// Waits for the sign-in to connect, and disconnects.
    func expectConnected() async throws {
        let outcome = try await boundedOutcome { try await connect.value }
        try #require(outcome != nil)
        try outcome?.get()
        await disconnectFast(client)
    }
}

// MARK: - Tests

enum XMPPClientSASLUpgradeTests {
    struct Upgrade {
        @Test(arguments: [false, true])
        func `A verified continue gets the upgraded hash, and the sign-in connects`(finalCarriesData: Bool) async throws {
            let signIn = try await UpgradeSignIn()

            let hash = try await signIn.playUpgrade()
            #expect(hash?.textContent == capturedUpgradeSHA256Hash)
            await signIn.mock.simulateReceive(successElement(additionalData: finalCarriesData ? signIn.serverFinal : nil))

            try await signIn.expectConnected()
            #expect(signIn.client.verifiedSCRAMMechanism == SCRAMMechanismName.sha1Plus)
        }

        @Test
        func `A server that refuses the hash fails the sign-in with its own text`() async throws {
            let signIn = try await UpgradeSignIn()

            _ = try await signIn.playUpgrade()
            await signIn.mock.simulateReceive(
                "<failure xmlns='urn:xmpp:sasl:2'><malformed-request xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/><text>Bad hash</text></failure>"
            )

            #expect(try await failureMessage(boundedFailure(of: signIn.connect)) == "Bad hash")
            #expect(await signIn.sentCount("abort") == 0)
        }

        @Test
        func `A success instead of a continue connects once its signature verifies`() async throws {
            let signIn = try await UpgradeSignIn()

            await signIn.mock.simulateReceive(successElement(additionalData: signIn.serverFinal))

            try await signIn.expectConnected()
            #expect(signIn.client.verifiedSCRAMMechanism == SCRAMMechanismName.sha1Plus)
        }

        @Test
        func `A success with no continue before it still needs the signature`() async throws {
            let signIn = try await UpgradeSignIn()

            await signIn.mock.simulateReceive(successElement(additionalData: nil))

            #expect(try await failureMessage(boundedFailure(of: signIn.connect)) == SASLAuthError.serverProofMissing.displayText)
        }
    }

    /// Each refusal aborts, and no hash goes out that a verified `<continue>` and its salt did not ask for.
    struct RefusedTask {
        @Test(arguments: [
            ("not the password", true, SASLAuthError.serverSignatureMismatch),
            ("pencil", false, .serverProofMissing)
        ])
        func `A continue whose signature does not verify gets no next`(
            serverPassword: String, carriesSignature: Bool, error: SASLAuthError
        ) async throws {
            let signIn = try await UpgradeSignIn(serverPassword: serverPassword)

            await signIn.mock.simulateReceive(continueElement(additionalData: carriesSignature ? signIn.serverFinal : nil))

            #expect(try await failureMessage(boundedFailure(of: signIn.connect)) == error.displayText)
            #expect(await signIn.sentCount("abort") == 1)
            #expect(await signIn.sentCount("next") == 0)
        }

        @Test
        func `A continue naming another task is not supported, after its signature verifies`() async throws {
            let signIn = try await UpgradeSignIn()

            await signIn.mock.simulateReceive(continueElement(additionalData: signIn.serverFinal, tasks: ["HT-SHA-256"]))

            #expect(try await failureMessage(boundedFailure(of: signIn.connect)) == SASLAuthError.unsupportedSignInStep.displayText)
            #expect(await signIn.sentCount("abort") == 1)
            #expect(await signIn.sentCount("next") == 0)
            #expect(signIn.client.verifiedSCRAMMechanism == SCRAMMechanismName.sha1Plus)
        }

        @Test
        func `A salt that arrives instead of a continue gets no hash`() async throws {
            let signIn = try await UpgradeSignIn()

            await signIn.mock.simulateReceive(saltTaskData())

            #expect(try await failureMessage(boundedFailure(of: signIn.connect)) == SASLAuthError.unexpectedReply.displayText)
            #expect(await signIn.sentCount("abort") == 1)
            #expect(await signIn.sentCount("task-data") == 0)
        }

        @Test
        func `A second salt after the hash gets no second hash`() async throws {
            let signIn = try await UpgradeSignIn()

            _ = try #require(try await signIn.playUpgrade())
            await signIn.mock.simulateReceive(saltTaskData())

            #expect(try await failureMessage(boundedFailure(of: signIn.connect)) == SASLAuthError.unexpectedReply.displayText)
            #expect(await signIn.sentCount("abort") == 1)
            #expect(await signIn.sentCount("task-data") == 1)
        }

        @Test(arguments: [
            (saltTaskData(iterations: 4095), SASLAuthError.iterationCountTooLow(4095)),
            ("<task-data xmlns='urn:xmpp:sasl:2'/>", .malformedUpgradeTask)
        ])
        func `A salt that can't be used gets no hash`(taskData: String, error: SASLAuthError) async throws {
            let signIn = try await UpgradeSignIn()

            await signIn.mock.simulateReceive(continueElement(additionalData: signIn.serverFinal))
            _ = try #require(try await signIn.awaitSent("next"))
            await signIn.mock.simulateReceive(taskData)

            #expect(try await failureMessage(boundedFailure(of: signIn.connect)) == error.displayText)
            #expect(await signIn.sentCount("abort") == 1)
            #expect(await signIn.sentCount("task-data") == 0)
        }
    }
}
