import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

extension OMEMOModuleTests {
    /// A new device takes an id the account's list does not hold (XEP-0384), so it reads that list before it exists.
    struct DeviceIDCollisionTests {
        private let mock = MockTransport()
        private let pepModule = PEPModule()

        private func startConnect(_ omemoModule: OMEMOModule) async -> (XMPPClient, Task<Void, any Error>) {
            let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "pass"), transport: mock, requireTLS: false, allowsPLAIN: true)
            await client.register(pepModule)
            await client.register(omemoModule)
            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            return (client, connectTask)
        }

        private func sentStanza(_ count: Int) async -> String {
            await mock.waitForSent(count: count)
            return await String(decoding: mock.sentBytes[count - 1], as: UTF8.self)
        }

        private func nextPubSubRequest(_ type: XMPPIQ.IQType, matching predicate: @escaping @Sendable (String) -> Bool) async throws -> String {
            try await awaitOutgoingIQ(on: mock, type: type, namespace: XMPPNamespaces.pubsub, matching: predicate).xml
        }

        private func acknowledge(_ stanza: String) async throws {
            let id = try #require(extractIQID(from: stanza))
            await mock.simulateReceive("<iq type=\"result\" id=\"\(id)\"/>")
        }

        @Test
        func `A new device draws its id again while the account's list holds the drawn one`() async throws {
            let draws = OSAllocatedUnfairLock(initialState: [UInt32(99), 4242])
            let omemoModule = OMEMOModule(pepModule: pepModule, registrationRetryDelays: []) {
                OMEMODeviceID(value: draws.withLock { $0.removeFirst() })
            }
            let (client, connectTask) = await startConnect(omemoModule)

            let read = await sentStanza(5)
            let id = try #require(extractIQID(from: read))
            await mock.simulateReceive("""
            <iq type="result" id="\(id)"><pubsub xmlns="http://jabber.org/protocol/pubsub">\
            <items node="\(XMPPNamespaces.omemoDevices)"><item id="current">\
            <devices xmlns="urn:xmpp:omemo:2"><device id="99"/></devices></item></items></pubsub></iq>
            """)
            let listPublish = try await nextPubSubRequest(.set) { $0.contains("node=\"\(XMPPNamespaces.omemoDevices)\"") }
            try await acknowledge(listPublish)
            try await acknowledge(nextPubSubRequest(.set) { $0.contains(XMPPNamespaces.omemoBundles) })
            // The stale-bundle check probes the other listed device.
            try await acknowledge(nextPubSubRequest(.get) { $0.contains(XMPPNamespaces.omemoBundles) })
            try await connectTask.value

            #expect(omemoModule.ownIdentityData?.deviceID == 4242)
            #expect(listPublish.contains("<device id=\"99\"/><device id=\"4242\"/>"))
            await disconnectFast(client)
        }

        @Test
        func `A new device is not created when the account's list cannot be read`() async throws {
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let (client, connectTask) = await startConnect(omemoModule)

            let read = await sentStanza(5)
            let id = try #require(extractIQID(from: read))
            await mock.simulateReceive("""
            <iq type="error" id="\(id)"><error type="wait">\
            <internal-server-error xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/></error></iq>
            """)
            try await Task.sleep(for: .milliseconds(200))

            #expect(omemoModule.ownIdentityData == nil)
            #expect(await mock.sentBytes.count == 5)
            await disconnectFast(client)
            try await connectTask.value
        }
    }
}
