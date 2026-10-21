import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(VCardModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

/// Waits for a vcard-temp IQ and returns its ID.
/// After `simulateNoTLSConnect`, sent count is 4. The next stanza (vCard IQ) is count 5.
private func awaitVCardIQID(mock: MockTransport, sentCount: Int = 5) async -> String? {
    await mock.waitForSent(count: sentCount)
    let sentData = await mock.sentBytes
    let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
    let vcardIQ = sentStrings.last { $0.contains("vcard-temp") }
    guard let iqStr = vcardIQ else { return nil }
    return extractIQID(from: iqStr)
}

// MARK: - Tests

enum VCardModuleTests {
    struct VCardParsing {
        @Test
        func `Parses FN and NICKNAME from vCard response`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: VCardModule.self))

            let fetchTask = Task {
                try await module.fetchVCard(for: BareJID.parse("contact@example.com")!)
            }

            let iqID = try #require(await awaitVCardIQID(mock: mock))

            await mock.simulateReceive("""
            <iq type='result' id='\(iqID)' from='contact@example.com'>\
            <vCard xmlns='vcard-temp'>\
            <FN>Alice Smith</FN>\
            <NICKNAME>alice</NICKNAME>\
            </vCard>\
            </iq>
            """)

            let vcard = try await fetchTask.value
            #expect(vcard?.fullName == "Alice Smith")
            #expect(vcard?.nickname == "alice")
            #expect(vcard?.photoData == nil)

            await disconnectFast(client)
        }

        @Test
        func `Parses PHOTO/BINVAL and computes SHA-1 hash`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: VCardModule.self))

            // Base64 of "test photo data"
            let photoBase64 = Base64.encode(Array("test photo data".utf8))

            let fetchTask = Task {
                try await module.fetchVCard(for: BareJID.parse("contact@example.com")!)
            }

            let iqID = try #require(await awaitVCardIQID(mock: mock))

            await mock.simulateReceive("""
            <iq type='result' id='\(iqID)' from='contact@example.com'>\
            <vCard xmlns='vcard-temp'>\
            <FN>Alice</FN>\
            <PHOTO>\
            <TYPE>image/png</TYPE>\
            <BINVAL>\(photoBase64)</BINVAL>\
            </PHOTO>\
            </vCard>\
            </iq>
            """)

            let vcard = try await fetchTask.value
            #expect(vcard?.photoData == Array("test photo data".utf8))
            #expect(vcard?.photoType == "image/png")
            #expect(vcard?.photoHash != nil)
            let hashIsNotEmpty = vcard?.photoHash?.isEmpty == false
            #expect(hashIsNotEmpty)

            await disconnectFast(client)
        }
    }

    struct VCardCaching {
        @Test
        func `Cache hit returns without IQ`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: VCardModule.self))

            let jid = try #require(BareJID.parse("contact@example.com"))

            // First fetch — will send IQ
            let fetchTask = Task {
                try await module.fetchVCard(for: jid)
            }

            let iqID = try #require(await awaitVCardIQID(mock: mock))

            await mock.simulateReceive("""
            <iq type='result' id='\(iqID)' from='contact@example.com'>\
            <vCard xmlns='vcard-temp'><FN>Alice</FN></vCard>\
            </iq>
            """)

            _ = try await fetchTask.value

            // Clear sent bytes and do second fetch — should not send IQ
            await mock.clearSentBytes()

            let cachedResult = try await module.fetchVCard(for: jid)
            #expect(cachedResult?.fullName == "Alice")

            let newSentData = await mock.sentBytes
            let hasVCardIQ = newSentData.map { String(decoding: $0, as: UTF8.self) }.contains { $0.contains("vcard-temp") }
            #expect(!hasVCardIQ)

            await disconnectFast(client)
        }

        @Test
        func `forceRefresh bypasses cache`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: VCardModule.self))

            let jid = try #require(BareJID.parse("contact@example.com"))

            // First fetch
            let fetchTask1 = Task {
                try await module.fetchVCard(for: jid)
            }

            var iqID = try #require(await awaitVCardIQID(mock: mock))

            await mock.simulateReceive("""
            <iq type='result' id='\(iqID)' from='contact@example.com'>\
            <vCard xmlns='vcard-temp'><FN>Alice</FN></vCard>\
            </iq>
            """)

            _ = try await fetchTask1.value

            // Force refresh — should send new IQ
            await mock.clearSentBytes()

            let fetchTask2 = Task {
                try await module.fetchVCard(for: jid, forceRefresh: true)
            }

            iqID = try #require(await awaitVCardIQID(mock: mock, sentCount: 1))

            await mock.simulateReceive("""
            <iq type='result' id='\(iqID)' from='contact@example.com'>\
            <vCard xmlns='vcard-temp'><FN>Alice Updated</FN></vCard>\
            </iq>
            """)

            let vcard = try await fetchTask2.value
            #expect(vcard?.fullName == "Alice Updated")

            await disconnectFast(client)
        }
    }

    // MARK: - Full Field Parsing

    struct VCardFullParsing {
        /// Connects a client, fetches a vCard with the given XML body, and returns the result.
        private func fetchVCard(respondingWith vcardBody: String) async throws -> VCardModule.VCard? {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: VCardModule.self))

            let fetchTask = Task {
                try await module.fetchVCard(for: BareJID.parse("contact@example.com")!)
            }

            let iqID = try #require(await awaitVCardIQID(mock: mock))

            await mock.simulateReceive("""
            <iq type='result' id='\(iqID)' from='contact@example.com'>\
            <vCard xmlns='vcard-temp'>\(vcardBody)</vCard>\
            </iq>
            """)

            let vcard = try await fetchTask.value
            await disconnectFast(client)
            return vcard
        }

        @Test
        func `Parses structured name fields`() async throws {
            let vcard = try await fetchVCard(respondingWith: """
            <FN>Dr. Alice B. Smith Jr.</FN>\
            <N>\
            <FAMILY>Smith</FAMILY>\
            <GIVEN>Alice</GIVEN>\
            <MIDDLE>B.</MIDDLE>\
            <PREFIX>Dr.</PREFIX>\
            <SUFFIX>Jr.</SUFFIX>\
            </N>
            """)

            #expect(vcard?.fullName == "Dr. Alice B. Smith Jr.")
            #expect(vcard?.name?.familyName == "Smith")
            #expect(vcard?.name?.givenName == "Alice")
            #expect(vcard?.name?.middleName == "B.")
            #expect(vcard?.name?.prefix == "Dr.")
            #expect(vcard?.name?.suffix == "Jr.")
        }

        @Test
        func `Parses emails with type markers`() async throws {
            let vcard = try await fetchVCard(respondingWith: """
            <EMAIL><HOME/><USERID>alice@home.com</USERID></EMAIL>\
            <EMAIL><WORK/><USERID>alice@work.com</USERID></EMAIL>
            """)

            let emailCount = vcard?.emails.count ?? 0
            #expect(emailCount == 2)
            #expect(vcard?.emails[0].address == "alice@home.com")
            #expect(vcard?.emails[0].types == [.home])
            #expect(vcard?.emails[1].address == "alice@work.com")
            #expect(vcard?.emails[1].types == [.work])
        }

        @Test
        func `Parses telephones with type markers`() async throws {
            let vcard = try await fetchVCard(respondingWith: """
            <TEL><HOME/><NUMBER>+1-555-0100</NUMBER></TEL>\
            <TEL><WORK/><NUMBER>+1-555-0200</NUMBER></TEL>
            """)

            let telCount = vcard?.telephones.count ?? 0
            #expect(telCount == 2)
            #expect(vcard?.telephones[0].number == "+1-555-0100")
            #expect(vcard?.telephones[0].types == [.home])
            #expect(vcard?.telephones[1].number == "+1-555-0200")
            #expect(vcard?.telephones[1].types == [.work])
        }

        @Test
        func `Parses addresses with all subfields`() async throws {
            let vcard = try await fetchVCard(respondingWith: """
            <ADR><HOME/>\
            <STREET>123 Main St</STREET>\
            <LOCALITY>Springfield</LOCALITY>\
            <REGION>IL</REGION>\
            <PCODE>62701</PCODE>\
            <CTRY>US</CTRY>\
            </ADR>
            """)

            let adrCount = vcard?.addresses.count ?? 0
            #expect(adrCount == 1)
            let adr = try #require(vcard?.addresses.first)
            #expect(adr.street == "123 Main St")
            #expect(adr.locality == "Springfield")
            #expect(adr.region == "IL")
            #expect(adr.postalCode == "62701")
            #expect(adr.country == "US")
            #expect(adr.types == [.home])
        }

        @Test
        func `Parses organization and miscellaneous fields`() async throws {
            let vcard = try await fetchVCard(respondingWith: """
            <ORG><ORGNAME>Acme Corp</ORGNAME></ORG>\
            <TITLE>Engineer</TITLE>\
            <ROLE>Developer</ROLE>\
            <URL>https://example.com</URL>\
            <BDAY>1990-01-15</BDAY>\
            <DESC>Hello world</DESC>
            """)

            #expect(vcard?.organization == "Acme Corp")
            #expect(vcard?.title == "Engineer")
            #expect(vcard?.role == "Developer")
            #expect(vcard?.url == "https://example.com")
            #expect(vcard?.birthday == "1990-01-15")
            #expect(vcard?.note == "Hello world")
        }

        @Test
        func `Handles missing fields gracefully`() async throws {
            let vcard = try await fetchVCard(respondingWith: "")

            #expect(vcard?.fullName == nil)
            #expect(vcard?.nickname == nil)
            #expect(vcard?.name == nil)
            let emailCount = vcard?.emails.count ?? 0
            #expect(emailCount == 0)
            let telCount = vcard?.telephones.count ?? 0
            #expect(telCount == 0)
            let adrCount = vcard?.addresses.count ?? 0
            #expect(adrCount == 0)
            #expect(vcard?.organization == nil)
            #expect(vcard?.photoData == nil)
        }

        @Test
        func `A BINVAL holding only whitespace is no photo`() async throws {
            let vcard = try await fetchVCard(respondingWith: "<PHOTO><TYPE>image/png</TYPE><BINVAL> \n\t </BINVAL></PHOTO>")

            #expect(vcard?.photoData == nil)
            #expect(vcard?.photoHash == nil)
        }
    }

    // MARK: - Serialization Round-Trip

    struct VCardSerialization {
        @Test
        func `Serialized XML contains all fields`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: VCardModule.self))

            let publishTask = Task {
                try await module.publishVCard(makeFullVCard())
            }

            let iqStr = try #require(await awaitPublishIQ(mock: mock))
            let iqID = try #require(extractIQID(from: iqStr))

            verifyXMLStructure(iqStr)

            await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")
            try await publishTask.value
            await disconnectFast(client)
        }

        @Test
        func `Cache preserves all fields after publish`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: VCardModule.self))

            let publishTask = Task {
                try await module.publishVCard(makeFullVCard())
            }

            let iqStr = try #require(await awaitPublishIQ(mock: mock))
            let iqID = try #require(extractIQID(from: iqStr))
            await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")
            try await publishTask.value

            await mock.clearSentBytes()
            let jid = try #require(BareJID.parse("user@example.com"))
            let cached = try await module.fetchVCard(for: jid)

            verifyCachedFields(cached)
            await disconnectFast(client)
        }

        // MARK: - Helpers

        private func makeFullVCard() -> VCardModule.VCard {
            VCardModule.VCard(
                fullName: "Alice Smith",
                nickname: "alice",
                name: .init(familyName: "Smith", givenName: "Alice", middleName: "B.", prefix: "Dr.", suffix: "Jr."),
                emails: [.init(address: "alice@home.com", types: [.home]), .init(address: "alice@work.com", types: [.work])],
                telephones: [.init(number: "+1-555-0100", types: [.home])],
                addresses: [.init(street: "123 Main St", locality: "Springfield", region: "IL", postalCode: "62701", country: "US", types: [.home])],
                organization: "Acme Corp",
                title: "Engineer",
                role: "Developer",
                url: "https://example.com",
                birthday: "1990-01-15",
                note: "Hello world",
                photoData: Array("test".utf8),
                photoType: "image/png"
            )
        }

        private func awaitPublishIQ(mock: MockTransport) async -> String? {
            await mock.waitForSent(count: 5)
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            return sentStrings.last { $0.contains("vcard-temp") && $0.contains("type=\"set\"") }
        }

        private func verifyXMLStructure(_ iqStr: String) {
            #expect(iqStr.contains("<vCard xmlns=\"vcard-temp\">"))
            #expect(iqStr.contains("<FN>Alice Smith</FN>"))
            #expect(iqStr.contains("<NICKNAME>alice</NICKNAME>"))
            #expect(iqStr.contains("<FAMILY>Smith</FAMILY>"))
            #expect(iqStr.contains("<GIVEN>Alice</GIVEN>"))
            #expect(iqStr.contains("<USERID>alice@home.com</USERID>"))
            #expect(iqStr.contains("<HOME/>"))
            #expect(iqStr.contains("<NUMBER>+1-555-0100</NUMBER>"))
            #expect(iqStr.contains("<STREET>123 Main St</STREET>"))
            #expect(iqStr.contains("<ORGNAME>Acme Corp</ORGNAME>"))
            #expect(iqStr.contains("<TITLE>Engineer</TITLE>"))
            #expect(iqStr.contains("<URL>https://example.com</URL>"))
            #expect(iqStr.contains("<BDAY>1990-01-15</BDAY>"))
            #expect(iqStr.contains("<DESC>Hello world</DESC>"))
            #expect(iqStr.contains("<TYPE>image/png</TYPE>"))
            #expect(iqStr.contains("<BINVAL>"))
        }

        private func verifyCachedFields(_ cached: VCardModule.VCard?) {
            #expect(cached?.fullName == "Alice Smith")
            #expect(cached?.nickname == "alice")
            #expect(cached?.name?.familyName == "Smith")
            #expect(cached?.name?.givenName == "Alice")
            #expect(cached?.organization == "Acme Corp")
            #expect(cached?.title == "Engineer")
            #expect(cached?.url == "https://example.com")
            #expect(cached?.birthday == "1990-01-15")
            #expect(cached?.note == "Hello world")
        }
    }

    // MARK: - Publishing

    struct VCardPublishing {
        @Test
        func `publishVCard sends IQ set with no to attribute`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: VCardModule.self))

            let vcard = VCardModule.VCard(fullName: "Test User", nickname: "test")

            let publishTask = Task {
                try await module.publishVCard(vcard)
            }

            await mock.waitForSent(count: 5)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let publishIQ = sentStrings.last { $0.contains("vcard-temp") && $0.contains("type=\"set\"") }

            let iqStr = try #require(publishIQ)
            // Should NOT contain a 'to' attribute (own vCard)
            let hasToAttr = iqStr.contains("to=\"")
            #expect(!hasToAttr)

            let iqID = try #require(extractIQID(from: iqStr))
            await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")

            try await publishTask.value

            await disconnectFast(client)
        }

        @Test
        func `fetchOwnVCard sends IQ get with no to attribute`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: VCardModule.self))

            let fetchTask = Task {
                try await module.fetchOwnVCard(forceRefresh: true)
            }

            await mock.waitForSent(count: 5)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let vcardIQ = sentStrings.last { $0.contains("vcard-temp") && $0.contains("type=\"get\"") }

            let iqStr = try #require(vcardIQ)
            // Should NOT contain a 'to' attribute (own vCard)
            let hasToAttr = iqStr.contains("to=\"")
            #expect(!hasToAttr)

            let iqID = try #require(extractIQID(from: iqStr))
            await mock.simulateReceive("""
            <iq type='result' id='\(iqID)'>\
            <vCard xmlns='vcard-temp'><FN>My Name</FN></vCard>\
            </iq>
            """)

            let vcard = try await fetchTask.value
            #expect(vcard?.fullName == "My Name")

            await disconnectFast(client)
        }

        @Test
        func `publishVCard updates cache`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: VCardModule.self))

            let vcard = VCardModule.VCard(fullName: "Updated Name")

            let publishTask = Task {
                try await module.publishVCard(vcard)
            }

            await mock.waitForSent(count: 5)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let publishIQ = sentStrings.last { $0.contains("vcard-temp") }
            let iqStr = try #require(publishIQ)
            let iqID = try #require(extractIQID(from: iqStr))
            await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")

            try await publishTask.value

            // Fetch own vCard — should hit cache
            await mock.clearSentBytes()
            let cached = try await module.fetchOwnVCard()
            #expect(cached?.fullName == "Updated Name")

            // Verify no IQ was sent (cache hit)
            let newSentData = await mock.sentBytes
            let hasVCardIQ = newSentData.map { String(decoding: $0, as: UTF8.self) }.contains { $0.contains("vcard-temp") }
            #expect(!hasVCardIQ)

            await disconnectFast(client)
        }
    }
}
