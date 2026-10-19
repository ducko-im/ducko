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
    await client.register(ServiceDiscoveryModule())
    await client.register(HTTPUploadModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

/// Responds to the disco#items query with a single upload service item.
private func respondToDiscoItems(mock: MockTransport) async throws {
    let iqID = try await awaitOutgoingIQ(on: mock, type: .get, namespace: "http://jabber.org/protocol/disco#items") {
        $0.contains("to=\"example.com\"")
    }.id
    await mock.simulateReceive("""
    <iq type='result' id='\(iqID)' from='example.com'>\
    <query xmlns='http://jabber.org/protocol/disco#items'>\
    <item jid='upload.example.com' name='HTTP Upload'/>\
    </query>\
    </iq>
    """)
}

/// Responds to the disco#info query for the upload service with the upload feature.
private func respondToDiscoInfo(mock: MockTransport, maxFileSize: Int64? = nil) async throws {
    let iqID = try await awaitOutgoingIQ(on: mock, type: .get, namespace: "http://jabber.org/protocol/disco#info") {
        $0.contains("to=\"upload.example.com\"")
    }.id
    var xml = """
    <iq type='result' id='\(iqID)' from='upload.example.com'>\
    <query xmlns='http://jabber.org/protocol/disco#info'>\
    <identity category='store' type='file'/>\
    <feature var='urn:xmpp:http:upload:0'/>
    """
    if let maxFileSize {
        xml += """
        <x xmlns='jabber:x:data' type='result'>\
        <field var='FORM_TYPE' type='hidden'><value>urn:xmpp:http:upload:0</value></field>\
        <field var='max-file-size'><value>\(maxFileSize)</value></field>\
        </x>
        """
    }
    xml += "</query></iq>"
    await mock.simulateReceive(xml)
}

/// Responds to a slot request with PUT and GET URLs.
private func respondToSlotRequest(
    mock: MockTransport,
    putURL: String = "https://upload.example.com/put/abc",
    getURL: String = "https://upload.example.com/get/abc",
    headers: [(name: String, value: String)] = []
) async throws {
    let iqID = try await awaitOutgoingIQ(on: mock, type: .get, namespace: "urn:xmpp:http:upload:0") {
        $0.contains("to=\"upload.example.com\"")
    }.id
    var putElement = "<put url='\(putURL)'>"
    for header in headers {
        putElement += "<header name='\(header.name)'>\(header.value)</header>"
    }
    putElement += "</put>"

    await mock.simulateReceive("""
    <iq type='result' id='\(iqID)' from='upload.example.com'>\
    <slot xmlns='urn:xmpp:http:upload:0'>\
    \(putElement)\
    <get url='\(getURL)'/>\
    </slot>\
    </iq>
    """)
}

/// Requests a slot from a connected client whose server answers with `headers` on the PUT URL.
private func requestSlot(headers: [(name: String, value: String)] = []) async throws -> HTTPUploadModule.UploadSlot {
    let mock = MockTransport()
    let client = try await makeConnectedClient(mock: mock)
    let module = try #require(await client.module(ofType: HTTPUploadModule.self))

    await mock.clearSentBytes()

    let slot = try await withIQOperation(client: client, operation: {
        try await module.requestSlot(filename: "doc.pdf", size: 5000, contentType: "application/pdf")
    }, respond: {
        try await respondToDiscoItems(mock: mock)
        try await respondToDiscoInfo(mock: mock)
        try await respondToSlotRequest(mock: mock, headers: headers)
    })
    await disconnectFast(client)
    return slot
}

// MARK: - Tests

enum HTTPUploadModuleTests {
    struct DiscoverUploadService {
        @Test
        func `Discovers upload service via disco`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: HTTPUploadModule.self))

            await mock.clearSentBytes()

            let result = try await withIQOperation(client: client, operation: {
                try await module.discoverUploadService()
            }, respond: {
                try await respondToDiscoItems(mock: mock)
                try await respondToDiscoInfo(mock: mock)
            })
            #expect(result?.jid == "upload.example.com")
            #expect(result?.maxFileSize == nil)

            await disconnectFast(client)
        }
    }

    struct DiscoverMaxFileSize {
        @Test
        func `Parses max-file-size from extended disco info`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: HTTPUploadModule.self))

            await mock.clearSentBytes()

            let result = try await withIQOperation(client: client, operation: {
                try await module.discoverUploadService()
            }, respond: {
                try await respondToDiscoItems(mock: mock)
                try await respondToDiscoInfo(mock: mock, maxFileSize: 10_485_760)
            })
            #expect(result?.jid == "upload.example.com")
            let maxSize = try #require(result?.maxFileSize)
            #expect(maxSize == 10_485_760)

            await disconnectFast(client)
        }
    }

    struct RequestSlot {
        @Test
        func `Requests and parses upload slot`() async throws {
            let slot = try await requestSlot()
            #expect(slot.putURL == "https://upload.example.com/put/abc")
            #expect(slot.getURL == "https://upload.example.com/get/abc")
            #expect(slot.putHeaders.isEmpty)
        }
    }

    struct RequestSlotWithHeaders {
        @Test
        func `Keeps only the allowed PUT headers, matched without regard to case`() async throws {
            let slot = try await requestSlot(headers: [
                ("authorization", "Basic dXNlcjpwYXNz"), ("eXpires", "Fri, 03 Mar 2017 11:28:38 GMT"),
                ("X-Custom", "value123"), ("Host", "evil.example.com")
            ])
            #expect(slot.putHeaders == [
                "Authorization": "Basic dXNlcjpwYXNz",
                "Expires": "Fri, 03 Mar 2017 11:28:38 GMT"
            ])
        }

        @Test
        func `Strips newlines from PUT header names and values`() async throws {
            let slot = try await requestSlot(headers: [("Auth&#13;&#10;orization", "Basic&#13;&#10;X-Injected: 1")])
            #expect(slot.putHeaders == ["Authorization": "BasicX-Injected: 1"])
        }

        @Test
        func `Joins repeated PUT header values in their order`() async throws {
            let slot = try await requestSlot(headers: [
                ("Cookie", "foo=bar"), ("Cookie", "user=romeo"), ("Expires", "a"), ("Expires", "b")
            ])
            #expect(slot.putHeaders == ["Cookie": "foo=bar; user=romeo", "Expires": "a, b"])
        }
    }

    struct FileTooLarge {
        @Test
        func `Throws fileTooLarge when size exceeds max`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: HTTPUploadModule.self))

            await mock.clearSentBytes()

            do {
                _ = try await withIQOperation(client: client, operation: {
                    try await module.requestSlot(filename: "big.zip", size: 20_000_000, contentType: "application/zip")
                }, respond: {
                    try await respondToDiscoItems(mock: mock)
                    try await respondToDiscoInfo(mock: mock, maxFileSize: 10_000_000)
                })
                Issue.record("Expected fileTooLarge error")
            } catch let error as HTTPUploadModule.HTTPUploadError {
                if case let .fileTooLarge(maxSize) = error {
                    #expect(maxSize == 10_000_000)
                } else {
                    Issue.record("Expected fileTooLarge, got \(error)")
                }
            }

            await disconnectFast(client)
        }
    }

    struct NoUploadService {
        @Test
        func `Throws noUploadServiceFound when no upload component exists`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: HTTPUploadModule.self))

            await mock.clearSentBytes()

            do {
                _ = try await withIQOperation(client: client, operation: {
                    try await module.requestSlot(filename: "test.txt", size: 100, contentType: "text/plain")
                }, respond: {
                    // Respond with items that have no upload service
                    let itemsID = try await awaitOutgoingIQ(on: mock, type: .get, namespace: "http://jabber.org/protocol/disco#items") {
                        $0.contains("to=\"example.com\"")
                    }.id
                    await mock.simulateReceive("""
                    <iq type='result' id='\(itemsID)' from='example.com'>\
                    <query xmlns='http://jabber.org/protocol/disco#items'>\
                    <item jid='conference.example.com' name='Chat Rooms'/>\
                    </query>\
                    </iq>
                    """)

                    // Respond to disco#info for conference (no upload feature)
                    let infoID = try await awaitOutgoingIQ(on: mock, type: .get, namespace: "http://jabber.org/protocol/disco#info") {
                        $0.contains("to=\"conference.example.com\"")
                    }.id
                    await mock.simulateReceive("""
                    <iq type='result' id='\(infoID)' from='conference.example.com'>\
                    <query xmlns='http://jabber.org/protocol/disco#info'>\
                    <identity category='conference' type='text'/>\
                    <feature var='http://jabber.org/protocol/muc'/>\
                    </query>\
                    </iq>
                    """)
                })
                Issue.record("Expected noUploadServiceFound error")
            } catch is HTTPUploadModule.HTTPUploadError {
                // Expected
            }

            await disconnectFast(client)
        }
    }

    struct CacheClearing {
        @Test
        func `handleDisconnect clears cached service`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: HTTPUploadModule.self))

            await mock.clearSentBytes()

            // Discover service to populate cache
            let result1 = try await withIQOperation(client: client, operation: {
                try await module.discoverUploadService()
            }, respond: {
                try await respondToDiscoItems(mock: mock)
                try await respondToDiscoInfo(mock: mock, maxFileSize: 5_000_000)
            })
            #expect(result1?.jid == "upload.example.com")

            // Disconnect clears cache
            await module.handleDisconnect()

            await mock.clearSentBytes()

            // Next discovery should query again (not use cache)
            let result2 = try await withIQOperation(client: client, operation: {
                try await module.discoverUploadService()
            }, respond: {
                try await respondToDiscoItems(mock: mock)
                try await respondToDiscoInfo(mock: mock, maxFileSize: 8_000_000)
            })
            #expect(result2?.maxFileSize == 8_000_000)

            await disconnectFast(client)
        }
    }
}
