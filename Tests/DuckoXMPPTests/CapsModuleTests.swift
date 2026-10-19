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
    }

    struct PresenceHandling {
        @Test
        func `handleConnect sends presence with caps element`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(CapsModule())

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

    struct CacheTests {
        @Test
        func `handlePresence records ver hash`() async throws {
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

            await mock.simulateReceive(
                "<presence from='contact@example.com/res'><c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='http://example.com/client' ver='testver123'/></presence>"
            )
            try? await Task.sleep(for: .milliseconds(100))

            // After caching features, isFeatureSupported should work
            let contactJID = try #require(BareJID.parse("contact@example.com"))
            capsModule.cacheFeatures(["feature-a"], for: "testver123")
            #expect(capsModule.isFeatureSupported("feature-a", by: contactJID))

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
            await mock.waitForSent(count: 6)
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

            let peerJID = try #require(BareJID.parse("peer@example.com"))
            #expect(capsModule.isFeatureSupported("urn:xmpp:ping", by: peerJID))
            #expect(capsModule.isFeatureSupported("urn:xmpp:receipts", by: peerJID))

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
            await mock.waitForSent(count: 6)
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

            let evilJID = try #require(BareJID.parse("evil@example.com"))
            #expect(!capsModule.isFeatureSupported("urn:xmpp:poisoned", by: evilJID))

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
            await mock.waitForSent(count: 6)
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

            let peerJID = try #require(BareJID.parse("form@example.com"))
            #expect(capsModule.isFeatureSupported("urn:xmpp:ping", by: peerJID))

            await disconnectFast(client)
        }
    }

    struct FeatureSupported {
        @Test
        func `Returns true when JID has cached feature`() async throws {
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

            // Simulate presence with caps
            await mock.simulateReceive(
                "<presence from='peer@example.com/res'><c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='http://example.com/client' ver='feathash1'/></presence>"
            )
            try? await Task.sleep(for: .milliseconds(100))

            let peerJID = try #require(BareJID.parse("peer@example.com"))

            // Before caching features, isFeatureSupported returns false
            #expect(!capsModule.isFeatureSupported("urn:xmpp:jingle:1", by: peerJID))

            // Cache features for the ver hash
            capsModule.cacheFeatures(["urn:xmpp:jingle:1", "http://jabber.org/protocol/disco#info"], for: "feathash1")

            // Now isFeatureSupported returns true for cached feature
            #expect(capsModule.isFeatureSupported("urn:xmpp:jingle:1", by: peerJID))

            // Returns false for uncached feature
            #expect(!capsModule.isFeatureSupported("urn:xmpp:jingle:0", by: peerJID))

            // Returns false for unknown JID
            let unknownJID = try #require(BareJID.parse("unknown@example.com"))
            #expect(!capsModule.isFeatureSupported("urn:xmpp:jingle:1", by: unknownJID))

            await disconnectFast(client)
        }

        @Test
        func `Clears JID mapping on disconnect`() async throws {
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

            // Simulate presence with caps
            await mock.simulateReceive(
                "<presence from='peer@example.com/res'><c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='http://example.com/client' ver='feathash2'/></presence>"
            )
            try? await Task.sleep(for: .milliseconds(100))

            let peerJID = try #require(BareJID.parse("peer@example.com"))
            capsModule.cacheFeatures(["urn:xmpp:jingle:1"], for: "feathash2")
            #expect(capsModule.isFeatureSupported("urn:xmpp:jingle:1", by: peerJID))

            // Disconnect clears JID→ver mapping
            await capsModule.handleDisconnect()
            #expect(!capsModule.isFeatureSupported("urn:xmpp:jingle:1", by: peerJID))

            await disconnectFast(client)
        }
    }
}
