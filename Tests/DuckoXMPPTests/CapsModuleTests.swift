import CryptoKit
import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Tests

enum CapsModuleTests {
    struct VerificationString {
        @Test
        func `Generates correct verification string from XEP-0115 example`() {
            // XEP-0115 §5.2 test vector (simplified)
            let identities = [
                ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "Exodus 0.9.1")
            ]
            let features: Set = [
                "http://jabber.org/protocol/caps",
                "http://jabber.org/protocol/disco#info",
                "http://jabber.org/protocol/disco#items",
                "http://jabber.org/protocol/muc"
            ]

            let ver = CapsModule.generateVerificationString(identities: identities, features: features)

            // The verification string is a base64-encoded SHA-1 hash.
            // We verify it's non-empty and deterministic.
            #expect(!ver.isEmpty)

            // Run again to verify determinism
            let ver2 = CapsModule.generateVerificationString(identities: identities, features: features)
            #expect(ver == ver2)
        }

        @Test
        func `Empty identities and features produce valid hash`() {
            let ver = CapsModule.generateVerificationString(identities: [], features: [])
            #expect(!ver.isEmpty)
        }

        @Test
        func `Identity lang is included in verification string`() {
            let identities = [
                ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "Test")
            ]
            let identitiesWithLang = [
                ServiceDiscoveryModule.Identity(category: "client", type: "pc", lang: "en", name: "Test")
            ]
            let features: Set = ["urn:xmpp:ping"]

            let ver1 = CapsModule.generateVerificationString(identities: identities, features: features)
            let ver2 = CapsModule.generateVerificationString(identities: identitiesWithLang, features: features)
            #expect(ver1 != ver2)
        }

        struct OctetOrderCase: Sendable, CustomTestStringConvertible {
            let testDescription: String
            var identities: [ServiceDiscoveryModule.Identity] = []
            var features: Set<String> = []
            var forms: [[DataFormField]] = []
            /// The verification string before it is hashed.
            let input: String
        }

        // The angstrom sign normalizes to U+00C5, which sorts before U+00D0, but its bytes sort after.
        private static let angstrom = "\u{212B}"
        private static let eth = "\u{00D0}"

        @Test(arguments: [
            OctetOrderCase(
                testDescription: "identities",
                identities: [.init(category: angstrom, type: "t"), .init(category: eth, type: "t")],
                input: "\(eth)/t//<\(angstrom)/t//<"
            ),
            OctetOrderCase(testDescription: "features", features: [angstrom, eth], input: "\(eth)<\(angstrom)<"),
            OctetOrderCase(
                testDescription: "forms",
                forms: [[DataFormField(variable: "FORM_TYPE", values: [angstrom])], [DataFormField(variable: "FORM_TYPE", values: [eth])]],
                input: "\(eth)<\(angstrom)<"
            ),
            OctetOrderCase(
                testDescription: "fields",
                forms: [[
                    DataFormField(variable: "FORM_TYPE", values: ["urn:x"]),
                    DataFormField(variable: angstrom, values: ["v"]),
                    DataFormField(variable: eth, values: ["v"])
                ]],
                input: "urn:x<\(eth)<v<\(angstrom)<v<"
            ),
            OctetOrderCase(
                testDescription: "values",
                forms: [[DataFormField(variable: "FORM_TYPE", values: ["urn:x"]), DataFormField(variable: "f", values: [angstrom, eth])]],
                input: "urn:x<f<\(eth)<\(angstrom)<"
            )
        ])
        func `Everything sorted is sorted by its bytes, not by its normalized characters`(sorted: OctetOrderCase) {
            let expected = Base64.encode(Array(Insecure.SHA1.hash(data: Array(sorted.input.utf8))))

            #expect(CapsModule.generateVerificationString(identities: sorted.identities, features: sorted.features, forms: sorted.forms) == expected)
        }

        @Test
        func `Different features produce different hashes`() {
            let identities = [
                ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "Test")
            ]
            let ver1 = CapsModule.generateVerificationString(identities: identities, features: ["feature-a"])
            let ver2 = CapsModule.generateVerificationString(identities: identities, features: ["feature-b"])
            #expect(ver1 != ver2)
        }
    }

    struct VerificationStringWithForms {
        @Test
        func `Forms produce different verification string than no forms`() {
            let identities = [
                ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "Test")
            ]
            let features: Set = ["urn:xmpp:ping"]
            let forms: [[DataFormField]] = [[
                DataFormField(variable: "FORM_TYPE", values: ["urn:xmpp:dataforms:softwareinfo"]),
                DataFormField(variable: "software", values: ["Ducko"])
            ]]
            let ver1 = CapsModule.generateVerificationString(identities: identities, features: features)
            let ver2 = CapsModule.generateVerificationString(identities: identities, features: features, forms: forms)
            #expect(ver1 != ver2)
        }

        @Test
        func `Empty forms produce same verification string`() {
            let identities = [
                ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "Test")
            ]
            let features: Set = ["urn:xmpp:ping"]
            let ver1 = CapsModule.generateVerificationString(identities: identities, features: features)
            let ver2 = CapsModule.generateVerificationString(identities: identities, features: features, forms: [])
            #expect(ver1 == ver2)
        }

        @Test
        func `Form order does not affect verification string`() {
            let formA: [DataFormField] = [
                DataFormField(variable: "FORM_TYPE", values: ["urn:a"]),
                DataFormField(variable: "field1", values: ["val1"])
            ]
            let formB: [DataFormField] = [
                DataFormField(variable: "FORM_TYPE", values: ["urn:b"]),
                DataFormField(variable: "field2", values: ["val2"])
            ]
            let ver1 = CapsModule.generateVerificationString(identities: [], features: [], forms: [formA, formB])
            let ver2 = CapsModule.generateVerificationString(identities: [], features: [], forms: [formB, formA])
            #expect(ver1 == ver2)
        }

        @Test
        func `Fields without var are left out of the verification string`() {
            let form: [DataFormField] = [
                DataFormField(variable: "FORM_TYPE", values: ["urn:a"]),
                DataFormField(variable: "field1", values: ["val1"])
            ]
            let fixedField = DataFormField(variable: nil, type: "fixed", values: ["Section"])
            let ver1 = CapsModule.generateVerificationString(identities: [], features: [], forms: [form])
            let ver2 = CapsModule.generateVerificationString(identities: [], features: [], forms: [form + [fixedField]])
            #expect(ver1 == ver2)
        }
    }

    struct PresenceHandling {
        @Test
        func `initial presence carries the caps element`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let capsModule = CapsModule()
            await client.register(PresenceModule(capsModule: capsModule))
            await client.register(capsModule)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let capsPresence = sentStrings.first { $0.contains("http://jabber.org/protocol/caps") }
            #expect(capsPresence != nil)
            #expect(capsPresence?.contains("hash=\"sha-1\"") == true)
            #expect(capsPresence?.contains("node=\"https://ducko.im\"") == true)
            #expect(capsPresence?.contains("ver=") == true)

            await disconnectFast(client)
        }
    }

    struct HashValidation {
        @Test
        func `Valid hash caches features`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let capsModule = CapsModule()
            await client.register(capsModule)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            // Compute a known ver hash
            let testIdentities = [
                ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "TestClient")
            ]
            let testFeatures: Set = ["urn:xmpp:ping", "urn:xmpp:receipts"]
            let expectedVer = CapsModule.generateVerificationString(
                identities: testIdentities, features: testFeatures
            )

            // Simulate presence with this ver
            await mock.simulateReceive(
                "<presence from='peer@example.com/res'><c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='http://test.example' ver='\(expectedVer)'/></presence>"
            )

            // Wait for disco#info IQ
            await mock.waitForSent(count: 5)
            let sentData = await mock.sentBytes
            let lastSent = try String(decoding: #require(sentData.last), as: UTF8.self)
            let iqID = try #require(extractIQID(from: lastSent))

            // Respond with matching identities and features
            await mock.simulateReceive("""
            <iq type='result' id='\(iqID)' from='peer@example.com/res'>\
            <query xmlns='http://jabber.org/protocol/disco#info' node='http://test.example#\(expectedVer)'>\
            <identity category='client' type='pc' name='TestClient'/>\
            <feature var='urn:xmpp:ping'/>\
            <feature var='urn:xmpp:receipts'/>\
            </query>\
            </iq>
            """)
            try? await Task.sleep(for: .milliseconds(200))

            let peerJID = try #require(JID.parse("peer@example.com/res"))
            #expect(capsModule.features(of: peerJID) == testFeatures)

            await disconnectFast(client)
        }

        @Test
        func `Invalid hash rejects features`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let capsModule = CapsModule()
            await client.register(capsModule)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            // Use a fabricated ver hash
            let fakeVer = "fakehash123"

            await mock.simulateReceive(
                "<presence from='evil@example.com/res'><c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='http://evil.example' ver='\(fakeVer)'/></presence>"
            )

            // Wait for disco#info IQ
            await mock.waitForSent(count: 5)
            let sentData = await mock.sentBytes
            let lastSent = try String(decoding: #require(sentData.last), as: UTF8.self)
            let iqID = try #require(extractIQID(from: lastSent))

            // Respond with data that does NOT match the fakeVer hash
            await mock.simulateReceive("""
            <iq type='result' id='\(iqID)' from='evil@example.com/res'>\
            <query xmlns='http://jabber.org/protocol/disco#info' node='http://evil.example#\(fakeVer)'>\
            <identity category='client' type='pc' name='EvilClient'/>\
            <feature var='urn:xmpp:poisoned'/>\
            </query>\
            </iq>
            """)
            try? await Task.sleep(for: .milliseconds(200))

            let evilJID = try #require(JID.parse("evil@example.com/res"))
            #expect(capsModule.features(of: evilJID) == nil)

            await disconnectFast(client)
        }

        @Test
        func `Valid hash with data forms caches features`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let capsModule = CapsModule()
            await client.register(capsModule)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            // Compute a known ver hash that includes data forms
            let testIdentities = [
                ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "FormClient")
            ]
            let testFeatures: Set = ["urn:xmpp:ping"]
            let testForms: [[DataFormField]] = [[
                DataFormField(variable: "FORM_TYPE", values: ["urn:xmpp:dataforms:softwareinfo"]),
                DataFormField(variable: "software", values: ["TestApp"])
            ]]
            let expectedVer = CapsModule.generateVerificationString(
                identities: testIdentities, features: testFeatures, forms: testForms
            )

            // Simulate presence with this ver
            await mock.simulateReceive(
                "<presence from='form@example.com/res'><c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='http://form.example' ver='\(expectedVer)'/></presence>"
            )

            // Wait for disco#info IQ
            await mock.waitForSent(count: 5)
            let sentData = await mock.sentBytes
            let lastSent = try String(decoding: #require(sentData.last), as: UTF8.self)
            let iqID = try #require(extractIQID(from: lastSent))

            // Respond with matching identities, features, and data forms
            await mock.simulateReceive("""
            <iq type='result' id='\(iqID)' from='form@example.com/res'>\
            <query xmlns='http://jabber.org/protocol/disco#info' node='http://form.example#\(expectedVer)'>\
            <identity category='client' type='pc' name='FormClient'/>\
            <feature var='urn:xmpp:ping'/>\
            <x xmlns='jabber:x:data' type='result'>\
            <field var='FORM_TYPE' type='hidden'><value>urn:xmpp:dataforms:softwareinfo</value></field>\
            <field var='software'><value>TestApp</value></field>\
            </x>\
            </query>\
            </iq>
            """)
            try? await Task.sleep(for: .milliseconds(200))

            let peerJID = try #require(JID.parse("form@example.com/res"))
            #expect(capsModule.features(of: peerJID) == testFeatures)

            await disconnectFast(client)
        }
    }

    struct Reception {
        private static let identity = ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "Peer")
        private static let identityXML = "<identity category='client' type='pc' name='Peer'/>"
        private static let ver = CapsModule.generateVerificationString(identities: [identity], features: ["urn:xmpp:ping"])

        private static func capsPresence(from resource: String, hash: String? = "sha-1", ver: String = ver) -> String {
            let hashAttribute = hash.map { " hash='\($0)'" } ?? ""
            return "<presence from='peer@example.com/\(resource)'>"
                + "<c xmlns='\(XMPPNamespaces.caps)'\(hashAttribute) node='https://peer.example' ver='\(ver)'/></presence>"
        }

        private static func peer(_ resource: String) throws -> JID {
            try #require(JID.parse("peer@example.com/\(resource)"))
        }

        @Test
        func `A repeat presence with a ver still being asked about sends no second question`() async throws {
            let gate = AsyncSemaphore()
            let peer = CapsPeer.make { iq in
                await gate.wait()
                return CapsPeer.result(to: iq, query: Self.identityXML + "<feature var='urn:xmpp:ping'/>")
            }
            try peer.receive(Self.capsPresence(from: "laptop"))
            try await peer.waitFor(questions: 1, answered: false)

            try peer.receive(Self.capsPresence(from: "phone"))
            await gate.signal()
            try await peer.waitFor(questions: 1)

            #expect(await peer.questions.count == 1)
            #expect(try peer.module.features(of: Self.peer("phone")) == ["urn:xmpp:ping"])
        }

        enum FailedAnswer: CaseIterable {
            case error
            case noQuery
            case duplicateFeature
            case otherFeatures
        }

        @Test(arguments: FailedAnswer.allCases)
        func `After a question fails, the next presence with its ver asks again`(failure: FailedAnswer) async throws {
            let peer = CapsPeer.make { iq in
                switch failure {
                case .error:
                    .failure(XMPPStanzaError(errorType: .cancel, condition: .itemNotFound))
                case .noQuery:
                    Result { try XMPPIQ(element: stanza("<iq type='result' id='\(iq.id ?? "")' from='\(iq.to?.description ?? "")'/>")) }
                case .duplicateFeature:
                    CapsPeer.result(to: iq, query: Self.identityXML + "<feature var='urn:xmpp:ping'/><feature var='urn:xmpp:ping'/>")
                case .otherFeatures:
                    CapsPeer.result(to: iq, query: Self.identityXML + "<feature var='urn:xmpp:poisoned'/>")
                }
            }
            try peer.receive(Self.capsPresence(from: "laptop"))
            try await peer.waitFor(questions: 1)
            #expect(try peer.module.features(of: Self.peer("laptop")) == nil)

            try peer.receive(Self.capsPresence(from: "phone"))
            try await peer.waitFor(questions: 2)
            #expect(await peer.questions.count == 2)
        }

        @Test(arguments: [nil, "md5"])
        func `A ver without a supported hash holds only for the session that sent it`(hash: String?) async throws {
            let peer = CapsPeer.make { CapsPeer.result(to: $0, query: "<feature var='urn:xmpp:ping'/>") }
            try peer.receive(Self.capsPresence(from: "laptop", hash: hash, ver: "unverifiable"))
            try await peer.waitFor(questions: 1)
            #expect(try peer.module.features(of: Self.peer("laptop")) == ["urn:xmpp:ping"])

            try peer.receive(Self.capsPresence(from: "phone", hash: hash, ver: "unverifiable"))
            try await peer.waitFor(questions: 2)
            #expect(await peer.questions.count == 2)
        }

        @Test
        func `A session repeating a ver without a supported hash is not asked again`() async throws {
            let peer = CapsPeer.make { CapsPeer.result(to: $0, query: "<feature var='urn:xmpp:ping'/>") }
            try peer.receive(Self.capsPresence(from: "laptop", hash: nil, ver: "unverifiable"))
            try await peer.waitFor(questions: 1)
            try #require(try peer.module.features(of: Self.peer("laptop")) == ["urn:xmpp:ping"])

            try peer.receive(Self.capsPresence(from: "laptop", hash: nil, ver: "unverifiable"))
            try peer.receive(Self.capsPresence(from: "phone", hash: nil, ver: "unverifiable"))
            try await peer.waitFor(questions: 2)
            try await Task.sleep(for: .milliseconds(50))

            #expect(await peer.questions.map(\.to?.description) == ["peer@example.com/laptop", "peer@example.com/phone"])
        }

        @Test
        func `A session whose ver without a supported hash got no answer is asked again`() async throws {
            let failures = Counter()
            let peer = CapsPeer.make { iq in
                guard await failures.next() > 1 else { return .failure(XMPPStanzaError(errorType: .wait, condition: .resourceConstraint)) }
                return CapsPeer.result(to: iq, query: "<feature var='urn:xmpp:ping'/>")
            }
            try peer.receive(Self.capsPresence(from: "laptop", hash: nil, ver: "unverifiable"))
            try await peer.waitFor(questions: 1)
            #expect(try peer.module.features(of: Self.peer("laptop")) == nil)

            try peer.receive(Self.capsPresence(from: "laptop", hash: nil, ver: "unverifiable"))
            try await peer.waitFor(questions: 2)

            #expect(try peer.module.features(of: Self.peer("laptop")) == ["urn:xmpp:ping"])
        }

        @Test
        func `A hash set whose first algorithm is unsupported verifies with the next`() async throws {
            let input = Caps2Hash.generateHashInput(identities: [Self.identity], features: ["urn:xmpp:ping"])
            let value = Base64.encode(Caps2HashAlgorithm.sha256.hash(input))
            let peer = CapsPeer.make { CapsPeer.result(to: $0, query: Self.identityXML + "<feature var='urn:xmpp:ping'/>") }

            try peer.receive("""
            <presence from='peer@example.com/laptop'><c xmlns='\(XMPPNamespaces.caps2)'>\
            <hash xmlns='\(XMPPNamespaces.hashes2)' algo='sha3-256'>AAAA</hash>\
            <hash xmlns='\(XMPPNamespaces.hashes2)' algo='sha-256'>\(value)</hash>\
            </c></presence>
            """)
            try await peer.waitFor(questions: 1)

            #expect(await peer.questionNodes == ["urn:xmpp:caps#sha-256.\(value)"])
            #expect(try peer.module.features(of: Self.peer("laptop")) == ["urn:xmpp:ping"])
        }

        @Test
        func `An identity in a reply whose iq carries xml:lang is hashed with it`() async throws {
            let identity = ServiceDiscoveryModule.Identity(category: "client", type: "pc", lang: "en", name: "Peer")
            let input = Caps2Hash.generateHashInput(identities: [identity], features: ["urn:xmpp:ping"])
            let value = Base64.encode(Caps2HashAlgorithm.sha256.hash(input))
            let peer = CapsPeer.make { iq in
                Result {
                    try XMPPIQ(element: stanza(
                        "<iq type='result' id='\(iq.id ?? "")' from='\(iq.to?.description ?? "")' xml:lang='en'>"
                            + "<query xmlns='\(XMPPNamespaces.discoInfo)'>\(Self.identityXML)<feature var='urn:xmpp:ping'/></query></iq>"
                    ))
                }
            }

            try peer.receive("""
            <presence from='peer@example.com/laptop'><c xmlns='\(XMPPNamespaces.caps2)'>\
            <hash xmlns='\(XMPPNamespaces.hashes2)' algo='sha-256'>\(value)</hash>\
            </c></presence>
            """)
            try await peer.waitFor(questions: 1)

            #expect(try peer.module.features(of: Self.peer("laptop")) == ["urn:xmpp:ping"])
        }

        /// XEP-0390 §4.1.
        @Test
        func `An identity in a reply without xml:lang on it, its query or its iq is hashed with the stream's`() async throws {
            let identity = ServiceDiscoveryModule.Identity(category: "client", type: "pc", lang: "de", name: "Peer")
            let value = Base64.encode(Caps2HashAlgorithm.sha256.hash(Caps2Hash.generateHashInput(identities: [identity], features: ["urn:xmpp:ping"])))
            let transport = MockTransport()
            let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "unused"), transport: transport, requireTLS: false)
            let caps = CapsModule()
            await client.register(caps)
            let connection = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(
                transport,
                serverStreamOpen: "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' from='example.com' version='1.0' xml:lang='de'>"
            )
            try await connection.value

            await transport.simulateReceive("""
            <presence from='peer@example.com/laptop'><c xmlns='\(XMPPNamespaces.caps2)'>\
            <hash xmlns='\(XMPPNamespaces.hashes2)' algo='sha-256'>\(value)</hash>\
            </c></presence>
            """)
            let question = try XMPPIQ(element: stanza(#require(await transport.waitForSent { $0.contains(XMPPNamespaces.discoInfo) })))
            await transport.simulateReceive(
                "<iq type='result' id='\(question.id ?? "")' from='peer@example.com/laptop'>"
                    + "<query xmlns='\(XMPPNamespaces.discoInfo)'>\(Self.identityXML)<feature var='urn:xmpp:ping'/></query></iq>"
            )

            try await eventually { try caps.features(of: Self.peer("laptop")) == ["urn:xmpp:ping"] }
            await disconnectFast(client)
        }

        @Test(arguments: [true, false])
        func `What a session advertised is forgotten when it goes offline or the connection ends`(unavailable: Bool) async throws {
            let peer = CapsPeer.make { CapsPeer.result(to: $0, query: Self.identityXML + "<feature var='urn:xmpp:ping'/>") }
            try peer.receive(Self.capsPresence(from: "laptop"))
            try await peer.waitFor(questions: 1)
            try #require(try peer.module.features(of: Self.peer("laptop")) != nil)

            if unavailable {
                try peer.receive("<presence from='peer@example.com/laptop' type='unavailable'/>")
            } else {
                await peer.module.handleDisconnect()
            }

            #expect(try peer.module.features(of: Self.peer("laptop")) == nil)
        }
    }

    struct DiscoReplyChecks {
        private static func info(
            _ queryChildren: String, queryLang: String? = nil, iqLang: String? = nil, streamLang: String? = nil
        ) throws -> CapsDiscoInfo {
            func lang(_ value: String?) -> String {
                value.map { " xml:lang='\($0)'" } ?? ""
            }
            let element = try stanza(
                "<iq type='result' id='q'\(lang(iqLang))><query xmlns='\(XMPPNamespaces.discoInfo)'\(lang(queryLang))>\(queryChildren)</query></iq>"
            )
            return try #require(CapsDiscoInfo(XMPPIQ(element: element), streamLang: streamLang))
        }

        private static func form(_ formTypeValues: String, type: String = "hidden", extra: String = "") -> String {
            "<x xmlns='\(XMPPNamespaces.dataForms)' type='result'><field var='FORM_TYPE' type='\(type)'>\(formTypeValues)</field>\(extra)</x>"
        }

        struct Case: Sendable, CustomTestStringConvertible {
            let testDescription: String
            let query: String
            let capsHashes: Bool
            let caps2Hashes: Bool
        }

        @Test(arguments: [
            Case(
                testDescription: "a repeated identity", query: "<identity category='client' type='pc'/><identity category='client' type='pc'/>",
                capsHashes: false, caps2Hashes: true
            ),
            Case(
                testDescription: "a repeated feature", query: "<feature var='a'/><feature var='a'/>",
                capsHashes: false, caps2Hashes: true
            ),
            Case(
                testDescription: "two forms of one FORM_TYPE", query: form("<value>urn:a</value>") + form("<value>urn:a</value>"),
                capsHashes: false, caps2Hashes: true
            ),
            Case(
                testDescription: "a FORM_TYPE with differing values", query: form("<value>urn:a</value><value>urn:b</value>"),
                capsHashes: false, caps2Hashes: true
            ),
            Case(
                testDescription: "an unexpected element", query: "<feature var='a'/><extra xmlns='urn:example'/>",
                capsHashes: true, caps2Hashes: false
            ),
            Case(
                testDescription: "a form with reported fields", query: form("<value>urn:a</value>", extra: "<reported/>"),
                capsHashes: true, caps2Hashes: false
            ),
            Case(
                testDescription: "a form without FORM_TYPE",
                query: "<x xmlns='\(XMPPNamespaces.dataForms)' type='result'><field var='a'><value>b</value></field></x>",
                capsHashes: true, caps2Hashes: false
            )
        ])
        func `A malformed reply cannot be hashed by the spec that rejects it`(replyCase: Case) throws {
            let info = try Self.info(replyCase.query)
            #expect((info.capsInput != nil) == replyCase.capsHashes)
            #expect((info.caps2Input != nil) == replyCase.caps2Hashes)
        }

        @Test
        func `A form whose FORM_TYPE is not hidden is left out of the XEP-0115 hash`() throws {
            let input = try #require(try Self.info(Self.form("<value>urn:a</value>", type: "text-single")).capsInput)
            #expect(input.forms.isEmpty)
        }

        struct LangCase: Sendable, CustomTestStringConvertible {
            let testDescription: String
            var identityLang: String?
            var queryLang: String?
            var iqLang: String?
            var streamLang: String?
            let hashedLang: String
        }

        @Test(arguments: [
            LangCase(testDescription: "the query's over the iq's", queryLang: "de", iqLang: "en", hashedLang: "de"),
            LangCase(testDescription: "the iq's over the stream's", iqLang: "en", streamLang: "de", hashedLang: "en"),
            LangCase(testDescription: "the stream's", streamLang: "de", hashedLang: "de"),
            LangCase(testDescription: "its own over all", identityLang: "fr", queryLang: "de", iqLang: "en", streamLang: "it", hashedLang: "fr"),
            LangCase(testDescription: "none", hashedLang: "")
        ])
        func `An identity without xml:lang inherits the query's, else the iq's, else the stream's, for the XEP-0390 hash only`(lang: LangCase) throws {
            let identityLang = lang.identityLang.map { " xml:lang='\($0)'" } ?? ""
            let info = try Self.info(
                "<identity category='client' type='pc'\(identityLang)/>", queryLang: lang.queryLang, iqLang: lang.iqLang, streamLang: lang.streamLang
            )
            #expect(info.caps2Input?.identities.first?.lang == lang.hashedLang)
            #expect(info.capsInput?.identities.first?.lang == lang.identityLang ?? "")
        }

        @Test(arguments: ["caps", "caps2"])
        func `An empty value counts as an empty string in the hash input`(hash: String) throws {
            let info = try Self.info(Self.form("<value>urn:a</value>", extra: "<field var='f'><value/><value>b</value></field>"))
            let input = try #require(hash == "caps" ? info.capsInput : info.caps2Input)
            #expect(input.forms.first?.first { $0.variable == "f" }?.values == ["", "b"])
        }

        @Test(arguments: [String?.none, "en", "de"])
        func `This client's caps verify against its disco#info reply whatever xml:lang a server stamps on the iq`(stampedLang: String?) async throws {
            let replies = AsyncStream.makeStream(of: XMLElement.self)
            let disco = ServiceDiscoveryModule()
            disco.setUp(makeStubModuleContext(sendStanza: { stanza, onAccepted in
                replies.continuation.yield(stanza.element)
                onAccepted?()
            }))
            let caps = CapsModule()
            caps.setUp(makeStubModuleContext())
            let advertised = caps.capsElements()

            #expect(try disco.handleIQ(XMPPIQ(element: stanza(
                "<iq type='get' id='q' from='peer@example.com/res'><query xmlns='\(XMPPNamespaces.discoInfo)'/></iq>"
            ))))
            // Read back as it arrives, where the children take the query's namespace.
            var reply = try stanza(#require(await replies.stream.first { _ in true }).xmlString)
            if let stampedLang { reply.setAttribute("xml:lang", value: stampedLang) }
            let info = try #require(CapsDiscoInfo(XMPPIQ(element: reply)))

            let ver = advertised.first { $0.namespace == XMPPNamespaces.caps }?.attribute("ver")
            let capsInput = try #require(info.capsInput)
            #expect(CapsModule.generateVerificationString(identities: capsInput.identities, features: capsInput.features, forms: capsInput.forms) == ver)
            let sha256 = advertised.first { $0.namespace == XMPPNamespaces.caps2 }?
                .children(named: "hash").first { $0.attribute("algo") == Caps2HashAlgorithm.sha256.rawValue }?.textContent
            let caps2Input = try #require(info.caps2Input)
            let caps2Bytes = Caps2Hash.generateHashInput(identities: caps2Input.identities, features: caps2Input.features, forms: caps2Input.forms)
            #expect(Base64.encode(Caps2HashAlgorithm.sha256.hash(caps2Bytes)) == sha256)
        }
    }
}

/// A ``CapsModule`` run without a client: each disco#info question it asks is recorded and answered by `answer`.
actor CapsPeer {
    typealias Answer = @Sendable (XMPPIQ) async -> Result<XMPPIQ, any Error>

    let module = CapsModule()
    private let answer: Answer
    private(set) var questions: [XMPPIQ] = []
    private var answers = 0

    private init(answer: @escaping Answer) {
        self.answer = answer
    }

    static func make(answer: @escaping Answer) -> CapsPeer {
        let peer = CapsPeer(answer: answer)
        peer.module.setUp(makeStubModuleContext(sendIQ: { iq, onTerminal in try await peer.ask(iq, onTerminal: onTerminal) }))
        return peer
    }

    /// A disco#info result to `iq` whose query holds `query`.
    static func result(to iq: XMPPIQ, query: String) -> Result<XMPPIQ, any Error> {
        Result {
            try XMPPIQ(element: stanza(
                "<iq type='result' id='\(iq.id ?? "")' from='\(iq.to?.description ?? "")'>"
                    + "<query xmlns='\(XMPPNamespaces.discoInfo)'>\(query)</query></iq>"
            ))
        }
    }

    nonisolated func receive(_ presence: String) throws {
        try module.handlePresence(XMPPPresence(element: stanza(presence)))
    }

    var questionNodes: [String?] {
        questions.map { $0.childElement?.attribute("node") }
    }

    private func ask(_ iq: XMPPIQ, onTerminal: ModuleContext.IQTerminalHandler?) async throws -> XMLElement? {
        questions.append(iq)
        let outcome = await answer(iq)
        onTerminal?(outcome)
        answers += 1
        return try outcome.get().childElement
    }

    /// Waits up to two seconds for `count` questions to be answered, or only asked when `answered` is false.
    func waitFor(questions count: Int, answered: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while (answered ? answers : questions.count) < count {
            guard ContinuousClock.now < deadline else {
                Issue.record("\(questions.count) questions asked, \(answers) answered; expected \(count)", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor Counter {
    private var count = 0

    /// The number of this call, counting from one.
    func next() -> Int {
        count += 1
        return count
    }
}
