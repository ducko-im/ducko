import DuckoTestSupport
import Testing
@testable import DuckoXMPP

extension OMEMOModuleTests {
    /// Encrypted messages of a session can arrive before `handleConnect` runs, and a resumed session never runs it,
    /// so the configured identity has to be in place once the session is established.
    struct SessionIdentityTests {
        private let recipient: TestOMEMOIdentity

        init() throws {
            self.recipient = try makeTestOMEMOIdentity(deviceID: 200, preKeyIDs: [7])
        }

        @Test func `a resumed session decrypts with the configured identity and publishes nothing`() async throws {
            let message = try await makeKEXMessage(to: recipient, plaintext: "secret")
            let resumeState = try SMResumeState(
                resumptionId: "sm-resume-1", incomingCounter: 0, outgoingCounter: 0, outgoingQueue: [],
                connectedJID: #require(FullJID.parse("user@example.com/ducko")), location: nil
            )

            let mock = MockTransport()
            let sm = StreamManagementModule(previousState: resumeState)
            let omemo = OMEMOModule(pepModule: PEPModule())
            omemo.configureIdentity(recipient.data)
            let client = XMPPClient(
                domain: "example.com", credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(sm)
            await client.addInterceptor(sm)
            await client.register(omemo)
            let received = Task { try await collectEvents(from: client, until: isEncryptedMessage) }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateResumeConnect(mock, resumeResponse: "<resumed xmlns='urn:xmpp:sm:3' previd='sm-resume-1' h='0'/>")
            try await connectTask.value
            await mock.simulateReceive(message.xmlString)

            #expect(try await decryptedBody(in: received.value) == "secret")
            let sent = await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(!sent.contains { $0.contains("<publish") })

            await mock.simulateDisconnect()
        }

        @Test func `a key exchange replayed after a resume carries its stanza and records the pre-key it used`() async throws {
            var message = try await makeKEXMessage(to: recipient, plaintext: "secret")
            message.setAttribute("id", value: "kex-1")
            let resumeState = try SMResumeState(
                resumptionId: "sm-resume-1", incomingCounter: 0, outgoingCounter: 0, outgoingQueue: [],
                connectedJID: #require(FullJID.parse("user@example.com/ducko")), location: nil
            )

            let mock = MockTransport()
            let sm = StreamManagementModule(previousState: resumeState)
            let omemo = OMEMOModule(pepModule: PEPModule())
            omemo.configureIdentity(recipient.data)
            let client = XMPPClient(
                domain: "example.com", credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(sm)
            await client.addInterceptor(sm)
            await client.register(omemo)
            let received = Task { try await collectEvents(from: client, until: isEncryptedMessage) }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateResumeConnect(mock, resumeResponse: "<resumed xmlns='urn:xmpp:sm:3' previd='sm-resume-1' h='0'/>")
            try await connectTask.value
            await mock.simulateReceive(message.xmlString)

            guard case let .omemoEncryptedMessageReceived(stanza, _, _) = try await received.value.last else {
                Issue.record("Expected an encrypted message")
                return
            }
            #expect(stanza.id == "kex-1")
            #expect(omemo.consumedPreKeyIDs() == [7])

            await mock.simulateDisconnect()
        }

        @Test func `a fresh session decrypts a message that arrives before the caps presence is sent`() async throws {
            let message = try await makeKEXMessage(to: recipient, plaintext: "secret")

            let mock = MockTransport()
            let omemo = OMEMOModule(pepModule: PEPModule())
            omemo.configureIdentity(recipient.data)
            let client = XMPPClient(
                domain: "example.com", credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(PresenceModule())
            await client.register(CapsModule())
            await client.register(omemo)
            let received = Task { try await collectEvents(from: client, until: isEncryptedMessage) }

            // Holding the caps presence keeps `OMEMOModule.handleConnect`, which runs after it, from starting.
            await mock.blockSends { $0.contains(XMPPNamespaces.caps) }
            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            await mock.waitForBlockedSend()
            await mock.simulateReceive(message.xmlString)

            #expect(try await decryptedBody(in: received.value) == "secret")

            await mock.releaseBlockedSends()
            await disconnectFast(client)
            _ = await connectTask.result
        }
    }
}
