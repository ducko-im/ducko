import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Tests

enum Caps2HashTests {
    struct HashInput {
        @Test
        func `Generates deterministic hash input`() {
            let identities = [
                ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "Ducko")
            ]
            let features: Set = ["urn:xmpp:caps", "http://jabber.org/protocol/disco#info"]

            let input1 = Caps2Hash.generateHashInput(identities: identities, features: features)
            let input2 = Caps2Hash.generateHashInput(identities: identities, features: features)
            #expect(input1 == input2)
        }

        @Test
        func `Features are sorted by byte-wise comparison`() {
            let features: Set = ["z-feature", "a-feature", "m-feature"]
            let input = Caps2Hash.generateHashInput(identities: [], features: features)

            // Features section: each feature terminated by 0x1f, section terminated by 0x1c
            var expected: [UInt8] = []
            expected.append(contentsOf: Array("a-feature".utf8))
            expected.append(0x1F)
            expected.append(contentsOf: Array("m-feature".utf8))
            expected.append(0x1F)
            expected.append(contentsOf: Array("z-feature".utf8))
            expected.append(0x1F)
            expected.append(0x1C) // features section end
            expected.append(0x1C) // identities section end (empty)
            expected.append(0x1C) // extensions section end (empty)

            #expect(input == expected)
        }

        @Test
        func `Identity encoding uses correct separators`() {
            let identities = [
                ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "TestApp")
            ]
            let input = Caps2Hash.generateHashInput(identities: identities, features: [])

            var expected: [UInt8] = []
            expected.append(0x1C) // features section end (empty)
            expected.append(contentsOf: Array("client".utf8))
            expected.append(0x1F)
            expected.append(contentsOf: Array("pc".utf8))
            expected.append(0x1F)
            expected.append(0x1F) // empty lang
            expected.append(contentsOf: Array("TestApp".utf8))
            expected.append(0x1F)
            expected.append(0x1E) // identity end
            expected.append(0x1C) // identities section end
            expected.append(0x1C) // extensions section end

            #expect(input == expected)
        }

        @Test
        func `Empty input produces section terminators only`() {
            let input = Caps2Hash.generateHashInput(identities: [], features: [])
            let expected: [UInt8] = [0x1C, 0x1C, 0x1C]
            #expect(input == expected)
        }

        @Test
        func `Identity lang is included in hash input`() {
            let identities = [
                ServiceDiscoveryModule.Identity(category: "client", type: "pc", lang: "en", name: "TestApp")
            ]
            let input = Caps2Hash.generateHashInput(identities: identities, features: [])

            var expected: [UInt8] = []
            expected.append(0x1C) // features section end (empty)
            expected.append(contentsOf: Array("client".utf8))
            expected.append(0x1F)
            expected.append(contentsOf: Array("pc".utf8))
            expected.append(0x1F)
            expected.append(contentsOf: Array("en".utf8))
            expected.append(0x1F)
            expected.append(contentsOf: Array("TestApp".utf8))
            expected.append(0x1F)
            expected.append(0x1E) // identity end
            expected.append(0x1C) // identities section end
            expected.append(0x1C) // extensions section end

            #expect(input == expected)
        }

        @Test
        func `Different features produce different inputs`() {
            let identities = [
                ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "Test")
            ]
            let input1 = Caps2Hash.generateHashInput(identities: identities, features: ["feature-a"])
            let input2 = Caps2Hash.generateHashInput(identities: identities, features: ["feature-b"])
            #expect(input1 != input2)
        }
    }

    struct DataFormEncoding {
        @Test
        func `Forms without FORM_TYPE are excluded`() {
            let forms: [[DataFormField]] = [[
                DataFormField(variable: "some-field", values: ["value"])
            ]]
            let withForms = Caps2Hash.generateHashInput(identities: [], features: [], forms: forms)
            let withoutForms = Caps2Hash.generateHashInput(identities: [], features: [])
            #expect(withForms == withoutForms)
        }

        @Test
        func `Forms with FORM_TYPE are encoded in extensions section`() {
            let forms: [[DataFormField]] = [[
                DataFormField(variable: "FORM_TYPE", values: ["urn:xmpp:dataforms:softwareinfo"])
            ]]
            let withForms = Caps2Hash.generateHashInput(identities: [], features: [], forms: forms)
            let withoutForms = Caps2Hash.generateHashInput(identities: [], features: [])
            #expect(withForms != withoutForms)
        }

        @Test
        func `Form order does not affect hash input`() {
            let formA: [DataFormField] = [
                DataFormField(variable: "FORM_TYPE", values: ["urn:a"]),
                DataFormField(variable: "field1", values: ["val1"])
            ]
            let formB: [DataFormField] = [
                DataFormField(variable: "FORM_TYPE", values: ["urn:b"]),
                DataFormField(variable: "field2", values: ["val2"])
            ]
            let ab = Caps2Hash.generateHashInput(identities: [], features: [], forms: [formA, formB])
            let ba = Caps2Hash.generateHashInput(identities: [], features: [], forms: [formB, formA])
            #expect(ab == ba)
        }

        @Test
        func `Fields within a form are sorted by byte representation`() {
            let form: [DataFormField] = [
                DataFormField(variable: "FORM_TYPE", values: ["urn:test"]),
                DataFormField(variable: "z-field", values: ["z"]),
                DataFormField(variable: "a-field", values: ["a"])
            ]
            let input = Caps2Hash.generateHashInput(identities: [], features: [], forms: [form])

            // XEP-0390 §4.1: FORM_TYPE is a regular field, all fields sorted by bytes
            var expected: [UInt8] = []
            expected.append(0x1C) // features end
            expected.append(0x1C) // identities end
            // FORM_TYPE field (uppercase 'F' sorts before lowercase 'a')
            expected.append(contentsOf: Array("FORM_TYPE".utf8))
            expected.append(0x1F)
            expected.append(contentsOf: Array("urn:test".utf8))
            expected.append(0x1F)
            expected.append(0x1E)
            // a-field
            expected.append(contentsOf: Array("a-field".utf8))
            expected.append(0x1F)
            expected.append(contentsOf: Array("a".utf8))
            expected.append(0x1F)
            expected.append(0x1E)
            // z-field
            expected.append(contentsOf: Array("z-field".utf8))
            expected.append(0x1F)
            expected.append(contentsOf: Array("z".utf8))
            expected.append(0x1F)
            expected.append(0x1E)
            expected.append(0x1D) // end form
            expected.append(0x1C) // extensions end

            #expect(input == expected)
        }

        @Test
        func `Values within a field are sorted`() throws {
            let form: [DataFormField] = [
                DataFormField(variable: "FORM_TYPE", values: ["urn:test"]),
                DataFormField(variable: "multi", values: ["z-val", "a-val"])
            ]
            let input = Caps2Hash.generateHashInput(identities: [], features: [], forms: [form])
            let inputStr = String(decoding: input.filter { $0 >= 0x20 }, as: UTF8.self)
            let zIndex = inputStr.range(of: "z-val")
            let aIndex = inputStr.range(of: "a-val")
            #expect(aIndex != nil)
            #expect(zIndex != nil)
            // a-val should appear before z-val
            #expect(try #require(aIndex?.lowerBound) < #require(zIndex?.lowerBound))
        }

        @Test
        func `Backward compatibility: empty forms produce same hash as no forms parameter`() {
            let identities = [
                ServiceDiscoveryModule.Identity(category: "client", type: "pc", name: "Test")
            ]
            let features: Set = ["urn:xmpp:ping"]
            let withEmptyForms = Caps2Hash.generateHashInput(identities: identities, features: features, forms: [])
            let withoutForms = Caps2Hash.generateHashInput(identities: identities, features: features)
            #expect(withEmptyForms == withoutForms)
        }
    }

    struct HashAlgorithm {
        @Test
        func `SHA-256 produces 32-byte digest`() {
            let data = Array("test".utf8)
            let digest = Caps2HashAlgorithm.sha256.hash(data)
            #expect(digest.count == 32)
        }

        @Test
        func `SHA-512 produces 64-byte digest`() {
            let data = Array("test".utf8)
            let digest = Caps2HashAlgorithm.sha512.hash(data)
            #expect(digest.count == 64)
        }

        @Test
        func `Same input produces same hash`() {
            let data = Array("deterministic".utf8)
            let hash1 = Caps2HashAlgorithm.sha256.hash(data)
            let hash2 = Caps2HashAlgorithm.sha256.hash(data)
            #expect(hash1 == hash2)
        }

        @Test
        func `Different algorithms produce different hashes`() {
            let data = Array("test data".utf8)
            let sha256 = Caps2HashAlgorithm.sha256.hash(data)
            let sha512 = Caps2HashAlgorithm.sha512.hash(data)
            #expect(sha256.count != sha512.count)
        }

        @Test
        func `Raw values match XEP-0300 algorithm names`() {
            #expect(Caps2HashAlgorithm.sha256.rawValue == "sha-256")
            #expect(Caps2HashAlgorithm.sha512.rawValue == "sha-512")
        }
    }

    struct PresenceBroadcast {
        @Test
        func `handleConnect sends presence with both XEP-0115 and XEP-0390 caps`() async throws {
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

            // XEP-0115 classic caps
            #expect(capsPresence?.contains("hash=\"sha-1\"") == true)
            #expect(capsPresence?.contains("node=\"https://ducko.im\"") == true)

            // XEP-0390 caps 2.0
            #expect(capsPresence?.contains("urn:xmpp:caps") == true)
            #expect(capsPresence?.contains("urn:xmpp:hashes:2") == true)
            #expect(capsPresence?.contains("algo=\"sha-256\"") == true)

            await disconnectFast(client)
        }
    }

    struct PresenceReception {
        @Test
        func `Prefers XEP-0390 over XEP-0115 when both present`() async throws {
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

            // Cache features under the caps2 ver key
            let caps2Ver = "sha-256.dGVzdGhhc2g="
            capsModule.cacheFeatures(["caps2-feature"], for: caps2Ver)

            // Simulate presence with both XEP-0115 and XEP-0390 caps
            await mock.simulateReceive("""
            <presence from='peer@example.com/res'>\
            <c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='http://test' ver='oldver'/>\
            <c xmlns='urn:xmpp:caps'>\
            <hash xmlns='urn:xmpp:hashes:2' algo='sha-256'>dGVzdGhhc2g=</hash>\
            </c>\
            </presence>
            """)
            try? await Task.sleep(for: .milliseconds(100))

            let peerJID = try #require(BareJID.parse("peer@example.com"))
            // Should use caps2 ver, not the XEP-0115 ver
            #expect(capsModule.isFeatureSupported("caps2-feature", by: peerJID))

            await disconnectFast(client)
        }

        @Test
        func `Falls back to XEP-0115 when no XEP-0390 element`() async throws {
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

            capsModule.cacheFeatures(["legacy-feature"], for: "legacyver")

            await mock.simulateReceive(
                "<presence from='peer@example.com/res'><c xmlns='http://jabber.org/protocol/caps' hash='sha-1' node='http://test' ver='legacyver'/></presence>"
            )
            try? await Task.sleep(for: .milliseconds(100))

            let peerJID = try #require(BareJID.parse("peer@example.com"))
            #expect(capsModule.isFeatureSupported("legacy-feature", by: peerJID))

            await disconnectFast(client)
        }
    }
}
