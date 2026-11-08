import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false, allowsPLAIN: true
    )
    await client.register(ChatModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum ChatModuleOOBTests {
    struct OutgoingOOB {
        @Test
        func `Sends OOB element via additionalElements`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: ChatModule.self))

            await mock.clearSentBytes()

            let downloadURL = "https://upload.example.com/files/photo.jpg"
            var oobX = XMLElement(name: "x", namespace: XMPPNamespaces.oob)
            var urlElement = XMLElement(name: "url")
            urlElement.addText(downloadURL)
            oobX.addChild(urlElement)

            let recipient = try #require(JID.parse("contact@example.com"))
            try await module.sendMessage(to: recipient, body: downloadURL, additionalElements: [oobX])

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let msg = sentStrings.first { $0.contains("jabber:x:oob") }
            #expect(msg != nil)
            if let msg {
                #expect(msg.contains("<url>https://upload.example.com/files/photo.jpg</url>"))
                #expect(msg.contains("<body>https://upload.example.com/files/photo.jpg</body>"))
            }

            await disconnectFast(client)
        }
    }
}
