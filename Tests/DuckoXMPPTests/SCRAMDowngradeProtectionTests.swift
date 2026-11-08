import CryptoKit
import DuckoTestSupport
import NIOSSL
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private let bindingData: [UInt8] = Array(repeating: 0xCD, count: 32)

/// Stream features offering `mechanisms` over SASL1 and, with Bind 2, `sasl2Mechanisms` (by default the same) over
/// SASL2, plus `types` in `<sasl-channel-binding>` when given.
private func offer(_ mechanisms: [String], sasl2Mechanisms: [String]? = nil, types: [String]? = nil) -> String {
    let names = { (mechanisms: [String]) in mechanisms.map { "<mechanism>\($0)</mechanism>" }.joined() }
    let binding = types.map { types in
        "<sasl-channel-binding xmlns='urn:xmpp:sasl-cb:0'>"
            + types.map { "<channel-binding type='\($0)'/>" }.joined() + "</sasl-channel-binding>"
    } ?? ""
    return """
    <features xmlns='http://etherx.jabber.org/streams'>\
    <mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(names(mechanisms))</mechanisms>\
    <authentication xmlns='urn:xmpp:sasl:2'>\(names(sasl2Mechanisms ?? mechanisms))<inline><bind xmlns='urn:xmpp:bind:0'/></inline></authentication>\
    \(binding)</features>
    """
}

private func makeClient(_ mock: MockTransport) -> XMPPClient {
    XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "pencil"), transport: mock, requireTLS: false)
}

private func sent(_ mock: MockTransport, _ prefix: String) async -> Bool {
    await mock.sentBytes.contains { String(decoding: $0, as: UTF8.self).hasPrefix(prefix) }
}

/// The message a sign-in that failed with `error` reports.
private func failureMessage(_ error: (any Error)?) -> String? {
    guard case let .authenticationFailed(failure) = error as? XMPPClientError else { return nil }
    return failure.message
}

/// What a sign-in run sent first, whether the client sent its proof, and what its connect threw.
private struct SignInRun {
    let start: String
    let sentProof: Bool
    let error: (any Error)?
}

/// The next stanza `mock` sends that matches `predicate`, or `nil` once `connect` ends without one.
private func nextSent(
    _ mock: MockTransport, before connect: Task<Void, any Error>, matching predicate: @escaping @Sendable (String) -> Bool
) async -> String? {
    let (stream, continuation) = AsyncStream.makeStream(of: String?.self)
    let watcher = Task { await continuation.yield(mock.waitForSent(matching: predicate)) }
    let finisher = Task {
        _ = await connect.result
        continuation.yield(nil)
    }
    defer {
        watcher.cancel()
        finisher.cancel()
    }
    for await stanza in stream {
        return stanza
    }
    return nil
}

/// Signs in on `mock` over SASL1 or SASL2 against `server`, offering `features`. A sign-in the server accepts then fails,
/// so every connect ends once the server has answered. Over SASL1 it fails at binding, and over SASL2 at its success,
/// which names no session.
private func signIn(
    _ client: XMPPClient, on mock: MockTransport, server: inout SCRAMTestServer, features: String, sasl2: Bool
) async throws -> SignInRun {
    let connect = Task {
        if sasl2 {
            try await client.connectWithTLS(host: "example.com", port: 5223)
        } else {
            try await client.connect(host: "example.com", port: 5222)
        }
    }
    await mock.waitForSent(count: 1) // stream opening
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(features)
    let start = try #require(await mock.waitForSent { $0.hasPrefix(sasl2 ? "<authenticate " : "<auth ") })
    let first = try server.serverFirst(answering: #require(SCRAMTestServer.payload(in: start)))
    let namespace = sasl2 ? XMPPNamespaces.sasl2 : saslNamespace
    await mock.simulateReceive("<challenge xmlns='\(namespace)'>\(first)</challenge>")
    let response = await nextSent(mock, before: connect, matching: { $0.hasPrefix("<response ") })
    if let response {
        let verifier = try server.serverFinal(answering: #require(SCRAMTestServer.payload(in: response)))
        await mock.clearSentBytes()
        if sasl2 {
            await mock.simulateReceive("<success xmlns='urn:xmpp:sasl:2'><additional-data>\(verifier)</additional-data></success>")
        } else {
            await mock.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(verifier)</success>")
            if await nextSent(mock, before: connect, matching: { $0.contains("<stream:stream") }) != nil {
                await mock.simulateReceive(testServerStreamOpen + testFeaturesBind)
                _ = await nextSent(mock, before: connect) { $0.contains("urn:ietf:params:xml:ns:xmpp-bind") }
                await mock.simulateReceive("<iq type='error' id='bind'><error type='cancel'><not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
            }
        }
    }
    return try await SignInRun(start: start, sentProof: response != nil, error: boundedFailure(of: connect))
}

// MARK: - Tests

enum SCRAMDowngradeProtectionTests {
    struct HashInput {
        @Test
        func `The XEP-0474 example hashes to its published value`() {
            let context = SCRAMDowngradeContext(
                advertisedMechanisms: ["SCRAM-SHA-1-PLUS", "SCRAM-SHA-1"],
                channelBindingTypes: ["tls-server-end-point", "tls-exporter"],
                tlsVersion: nil
            )
            #expect(Base64.encode(Array(Insecure.SHA1.hash(data: xep0474HashInput(context)))) == "G6k/rBLDqgOhRRaCuuatSDFkJ08=")
        }

        @Test
        func `Mechanisms are hashed as received and sorted bytewise`() {
            let context = SCRAMDowngradeContext(advertisedMechanisms: ["scram-sha-1", "PLAIN"], channelBindingTypes: nil, tlsVersion: nil)
            #expect(xep0474HashInput(context) == Array("PLAIN\u{1E}scram-sha-1".utf8))
        }

        @Test(arguments: [(nil, "SCRAM-SHA-1"), ([], "SCRAM-SHA-1\u{1F}")] as [([String]?, String)])
        func `Only a listed channel-binding element adds its separator`(types: [String]?, expected: String) {
            let context = SCRAMDowngradeContext(advertisedMechanisms: ["SCRAM-SHA-1"], channelBindingTypes: types, tlsVersion: nil)
            #expect(xep0474HashInput(context) == Array(expected.utf8))
        }

        @Test
        func `The raw parsers keep each name as received`() throws {
            let features = try stanza(offer(["scram-sha-1", "PLAIN"], types: ["tls-exporter"]))
            #expect(advertisedSASL1Mechanisms(features) == ["scram-sha-1", "PLAIN"])
            #expect(advertisedSASL2Mechanisms(features) == ["scram-sha-1", "PLAIN"])
            #expect(advertisedChannelBindingTypeList(features) == ["tls-exporter"])
            #expect(try advertisedChannelBindingTypeList(stanza(offer(["PLAIN"]))) == nil)
        }

        @Test(arguments: [(UInt16(0x0304), "0304"), (0x0303, "0303"), (0x0A0B, "0a0b")])
        func `A TLS version is four lowercase hex digits`(version: UInt16, expected: String) {
            #expect(xep0515VersionAttribute(version) == expected)
        }

        @Test(arguments: [(NIOSSL.TLSVersion.tlsv1, UInt16(0x0301)), (.tlsv11, 0x0302), (.tlsv12, 0x0303), (.tlsv13, 0x0304)])
        func `Each negotiated TLS version has its wire code`(version: NIOSSL.TLSVersion, code: UInt16) {
            #expect(tlsWireVersion(version) == code)
        }
    }

    struct OfferHash {
        private static let mechanisms = ["SCRAM-SHA-1", "SCRAM-SHA-1-PLUS"]
        private static let types = ["tls-exporter"]

        @Test(arguments: [false, true])
        func `A hash that does not match the offer fails before the proof goes out`(sasl2: Bool) async throws {
            let mock = MockTransport()
            await mock.setChannelBindingData(bindingData)
            let client = makeClient(mock)
            var server = SCRAMTestServer(password: "pencil", mechanism: "SCRAM-SHA-1", attributes: [.wrongOfferHash])

            let run = try await signIn(client, on: mock, server: &server, features: offer(Self.mechanisms, types: Self.types), sasl2: sasl2)

            #expect(failureMessage(run.error) == SASLAuthError.mechanismListTampered.displayText)
            #expect(!run.sentProof)
            #expect(await sent(mock, "<abort") == sasl2)
        }

        @Test
        func `A failed abort still reports the tampered offer`() async throws {
            let mock = MockTransport()
            await mock.setChannelBindingData(bindingData)
            await mock.failNextSend(matching: "<abort", error: XMPPClientError.sendFailed("Broken pipe"))
            let client = makeClient(mock)
            var server = SCRAMTestServer(password: "pencil", mechanism: "SCRAM-SHA-1", attributes: [.wrongOfferHash])

            let run = try await signIn(client, on: mock, server: &server, features: offer(Self.mechanisms, types: Self.types), sasl2: true)

            #expect(failureMessage(run.error) == SASLAuthError.mechanismListTampered.displayText)
        }

        @Test(arguments: [false, true])
        func `The hash covers the mechanisms of the profile in use as received`(sasl2: Bool) async throws {
            let sasl1Mechanisms = ["SCRAM-SHA-1", "plain"]
            let sasl2Mechanisms = ["SCRAM-SHA-1"]
            let mock = MockTransport()
            let client = makeClient(mock)
            var server = SCRAMTestServer(
                password: "pencil", mechanism: "SCRAM-SHA-1",
                attributes: [.offerHash(mechanisms: sasl2 ? sasl2Mechanisms : sasl1Mechanisms, channelBindingTypes: nil)]
            )

            let features = offer(sasl1Mechanisms, sasl2Mechanisms: sasl2Mechanisms)
            let run = try await signIn(client, on: mock, server: &server, features: features, sasl2: sasl2)

            #expect(run.sentProof)
            #expect(client.verifiedSCRAMMechanism == "SCRAM-SHA-1")
        }

        @Test(arguments: [false, true])
        func `A matching hash accepts an offer whose only types the client cannot compute`(sasl2: Bool) async throws {
            let mock = MockTransport()
            await mock.setChannelBindingData(bindingData)
            let client = makeClient(mock)
            var server = SCRAMTestServer(
                password: "pencil", mechanism: "SCRAM-SHA-1",
                attributes: [.offerHash(mechanisms: Self.mechanisms, channelBindingTypes: Self.types)]
            )

            _ = try await signIn(client, on: mock, server: &server, features: offer(Self.mechanisms, types: Self.types), sasl2: sasl2)

            #expect(server.clientGS2Header == "n,,")
            #expect(client.verifiedSCRAMMechanism == "SCRAM-SHA-1")
        }
    }

    struct TLSVersion {
        @Test(arguments: [
            (UInt16?.some(0x0304), "0304", true, false), (0x0304, "0303", false, false), (nil, "0304", false, false),
            (0x0304, "0304", true, true), (0x0304, "0303", false, true), (nil, "0304", false, true)
        ])
        func `A TLS version the server names must be the negotiated one`(
            negotiated: UInt16?, named: String, proceeds: Bool, sasl2: Bool
        ) async throws {
            let mock = MockTransport()
            if let negotiated {
                await mock.setTLSInfo(TLSInfo(protocolVersion: "TLS 1.3", wireVersion: negotiated, cipherSuite: nil))
            }
            let client = makeClient(mock)
            var server = SCRAMTestServer(password: "pencil", attributes: [.tlsVersion(named)])

            let run = try await signIn(client, on: mock, server: &server, features: offer(["SCRAM-SHA-256"]), sasl2: sasl2)

            #expect(client.verifiedSCRAMMechanism == (proceeds ? "SCRAM-SHA-256" : nil))
            #expect(run.sentProof == proceeds)
            if !proceeds {
                #expect(failureMessage(run.error) == SASLAuthError.tlsVersionTampered.displayText)
                #expect(await sent(mock, "<abort") == sasl2)
            }
        }
    }

    struct AbortScope {
        @Test
        func `A success whose signature does not check out gets no abort`() async throws {
            let mock = MockTransport()
            let client = makeClient(mock)
            var server = SCRAMTestServer(password: "not the password")

            let run = try await signIn(client, on: mock, server: &server, features: offer(["SCRAM-SHA-256"]), sasl2: true)

            #expect(failureMessage(run.error) == SASLAuthError.serverSignatureMismatch.displayText)
            #expect(await !sent(mock, "<abort"))
        }
    }

    /// One case at a time: run in parallel, their 512-bit key derivations take every core and push other suites' short
    /// sign-in deadlines past their limit.
    @Suite(.serialized)
    struct StrongerHashes {
        struct Case: Sendable, CustomTestStringConvertible {
            let mechanism: String
            let bound: Bool
            let sasl2: Bool
            var testDescription: String {
                "\(mechanism) over \(sasl2 ? "SASL2" : "SASL1")"
            }
        }

        static let cases: [Case] = [SCRAMMechanismName.sha512, SCRAMMechanismName.sha3_512].flatMap { name in
            [false, true].flatMap { sasl2 in
                [Case(mechanism: name, bound: false, sasl2: sasl2), Case(mechanism: name + "-PLUS", bound: true, sasl2: sasl2)]
            }
        }

        @Test(arguments: cases)
        func `Signs in with the offered mechanism and verifies the server`(item: Case) async throws {
            let mock = MockTransport()
            if item.bound {
                await mock.setChannelBindingData(bindingData)
            }
            let client = makeClient(mock)
            var server = SCRAMTestServer(password: "pencil", mechanism: item.mechanism)
            let features = offer([item.mechanism, "SCRAM-SHA-256"], types: item.bound ? [tlsServerEndPointCBType] : nil)

            let run = try await signIn(client, on: mock, server: &server, features: features, sasl2: item.sasl2)

            #expect(run.start.contains("mechanism=\"\(item.mechanism)\""))
            #expect(client.verifiedSCRAMMechanism == item.mechanism)
            if item.bound {
                #expect(server.clientGS2Header == "p=tls-server-end-point,,")
                #expect(server.clientBindingData == bindingData)
            } else {
                #expect(server.clientGS2Header == "n,,")
            }
        }

        @Test(arguments: cases)
        func `A server signature made with another password fails`(item: Case) async throws {
            let mock = MockTransport()
            if item.bound {
                await mock.setChannelBindingData(bindingData)
            }
            let client = makeClient(mock)
            var server = SCRAMTestServer(password: "not the password", mechanism: item.mechanism)
            let features = offer([item.mechanism], types: item.bound ? [tlsServerEndPointCBType] : nil)

            let run = try await signIn(client, on: mock, server: &server, features: features, sasl2: item.sasl2)

            #expect(failureMessage(run.error) == SASLAuthError.serverSignatureMismatch.displayText)
            #expect(client.verifiedSCRAMMechanism == nil)
        }

        @Test(arguments: [
            (SCRAMMechanismName.sha512, "gMGXRcevScNtxZ6/8lQYpGtnsNAc3mGcmNomv+xnoOMw+3R2xNJdMNnzMlTN8PPC6wdp6dybEmDYXYTxwnYPJQ==",
             "ZQnYEgWQMFmmsM8aQMF0nDDCy/AgCzkwk8CmMZYcMg0vSVlKDanekLtifDSeVGT4+5ZxXnJq199RVG2rR7N7Zw=="),
            (SCRAMMechanismName.sha3_512, "37RsC22bKqUDfdmJ5ojfviHvJllSdNm2pyi9QVvIdOiHyF0wT3YozEvf3gshtz82VmdOVhubuDdqfxM+xQZ5hg==",
             "edmhgVenO1ZjN28/CvW/bI1M7pSbZXyvB7z136xUDz/Do6nvzXZoBNJx5pQQ+Vt/7PT3yGAf9Yv6CyHFeT9wIA==")
        ])
        func `Proof and server signature match vectors from Python's hashlib`(mechanism: String, proof: String, signature: String) throws {
            // RFC 7677's inputs, run through Python's `hashlib.pbkdf2_hmac` and `hmac` with each hash.
            let serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
            var session: any SCRAMSession = mechanism == SCRAMMechanismName.sha512
                ? SCRAMState<SHA512>(nonceGenerator: { "rOprNGfwEbeRWgbNEkqO" })
                : SCRAMState<SHA3_512>(nonceGenerator: { "rOprNGfwEbeRWgbNEkqO" })
            #expect(session.clientFirstMessage(authcid: "user", password: "pencil") == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
            let clientFinal = try session.clientFinalMessage(serverFirstMessage: serverFirst).get()
            #expect(clientFinal == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=\(proof)")
            try session.verifyServerFinal(serverFinalMessage: "v=\(signature)").get()
        }
    }

    struct Selection {
        @Test(arguments: [
            (ChannelBindingMode.none, [
                SCRAMMechanismName.sha3_512, SCRAMMechanismName.sha512, SCRAMMechanismName.sha256, SCRAMMechanismName.sha1
            ]),
            (.bound(type: tlsServerEndPointCBType, data: bindingData), [
                SCRAMMechanismName.sha3_512Plus, SCRAMMechanismName.sha512Plus, SCRAMMechanismName.sha256Plus, SCRAMMechanismName.sha1Plus
            ])
        ])
        func `Picks SHA3-512, then SHA-512, then SHA-256, then SHA-1`(binding: ChannelBindingMode, order: [String]) throws {
            for index in order.indices {
                let selected = try selectSASLMechanism(offered: Set(order[index...]), channelBinding: binding, allowsPLAIN: false)
                #expect(selected == order[index])
            }
        }

        @Test
        func `By default an offer of only PLAIN is refused`() {
            #expect(throws: SASLAuthError.plainRefused) {
                try selectSASLMechanism(offered: ["PLAIN"], channelBinding: .none, allowsPLAIN: false)
            }
        }
    }
}
