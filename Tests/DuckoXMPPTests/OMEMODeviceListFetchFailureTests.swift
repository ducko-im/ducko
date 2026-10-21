import DuckoTestSupport
import Testing
@testable import DuckoXMPP

extension OMEMOModuleTests {
    struct DeviceListFetchFailureTests {
        private typealias SeenDevices = PruneStaleBundlesTests.StubSeenDeviceClassificationProvider

        private let mock = MockTransport()
        private let pepModule = PEPModule()
        private let omemoModule: OMEMOModule

        init() {
            self.omemoModule = OMEMOModule(pepModule: pepModule, registrationRetryDelays: [.zero, .zero, .zero])
        }

        private func startConnect() async -> (XMPPClient, Task<Void, any Error>) {
            let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "pass"), transport: mock, requireTLS: false)
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

        private func acknowledge(_ stanza: String) async throws {
            let id = try #require(extractIQID(from: stanza))
            await mock.simulateReceive("<iq type=\"result\" id=\"\(id)\"/>")
        }

        private func failDeviceListRead(id: String) async {
            await mock.simulateReceive("""
            <iq type="error" id="\(id)"><error type="wait">\
            <internal-server-error xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/></error></iq>
            """)
        }

        private func answerDeviceListRead(id: String) async {
            await mock.simulateReceive("""
            <iq type="result" id="\(id)"><pubsub xmlns="http://jabber.org/protocol/pubsub">\
            <items node="\(XMPPNamespaces.omemoDevices)"><item id="current">\
            <devices xmlns="urn:xmpp:omemo:2"><device id="99"/></devices></item></items></pubsub></iq>
            """)
        }

        /// Returns the ID of the next device-list read whose ID is not in `answered`.
        private func nextDeviceListRead(after answered: Set<String>) async throws -> String {
            try await awaitOutgoingIQ(on: mock, type: .get, namespace: XMPPNamespaces.pubsub) { stanza in
                stanza.contains(XMPPNamespaces.omemoDevices) && (extractIQID(from: stanza).map { !answered.contains($0) } ?? false)
            }.id
        }

        private func nextDeviceListPublish() async throws -> String {
            try await awaitOutgoingIQ(on: mock, type: .set, namespace: XMPPNamespaces.pubsub) {
                $0.contains("node=\"\(XMPPNamespaces.omemoDevices)\"")
            }.xml
        }

        private func publishedDeviceID(in bundlePublish: String) throws -> Substring {
            let itemStart = try #require(bundlePublish.range(of: "<item id=\""))
            return bundlePublish[itemStart.upperBound...].prefix { $0.isNumber }
        }

        /// A fetch that fails for any reason but a missing node publishes only the bundle and skips pruning. The device
        /// is added afterwards from a fresh read, never over the unread list.
        @Test(arguments: [false, true])
        func `A failed own device-list fetch registers the device from a fresh read`(failsAtSend: Bool) async throws {
            let seenDevices = SeenDevices(initial: [99])
            omemoModule.configureSeenDeviceClassificationProvider(seenDevices, accountID: "acct-1")
            if failsAtSend {
                // The failed send is never recorded, so the bundle publish becomes stanza 5.
                await mock.failNextSend(matching: XMPPNamespaces.omemoDevices, error: XMPPClientError.sendFailed("The connection was closed"))
            }
            let (client, connectTask) = await startConnect()

            var bundleIndex = 5
            var answered: Set<String> = []
            if !failsAtSend {
                let id = try #require(await extractIQID(from: sentStanza(5)))
                await failDeviceListRead(id: id)
                answered.insert(id)
                bundleIndex = 6
            }
            let bundlePublish = await sentStanza(bundleIndex)
            #expect(bundlePublish.contains("<publish") && bundlePublish.contains(XMPPNamespaces.omemoBundles))
            try await acknowledge(bundlePublish)
            try await connectTask.value

            try await answerDeviceListRead(id: nextDeviceListRead(after: answered))
            let listPublish = try await nextDeviceListPublish()
            let deviceID = try publishedDeviceID(in: bundlePublish)
            #expect(listPublish.contains("<device id=\"99\"") && listPublish.contains("<device id=\"\(deviceID)\""))
            try await acknowledge(listPublish)

            #expect(await seenDevices.lastUpdate == nil)
            #expect(await Set(seenDevices.snapshot.keys) == [99])

            await disconnectFast(client)
        }

        /// A retry whose read fails waits for the next delay. Retries stop after the first successful registration or
        /// after the last delay.
        @Test(arguments: [1, 3])
        func `Registration retries stop after success or the last delay`(failedRetries: Int) async throws {
            let (client, connectTask) = await startConnect()
            let connectReadID = try #require(await extractIQID(from: sentStanza(5)))
            await failDeviceListRead(id: connectReadID)
            try await acknowledge(sentStanza(6))
            try await connectTask.value

            var answered: Set<String> = [connectReadID]
            for attempt in 1 ... 3 {
                let id = try await nextDeviceListRead(after: answered)
                answered.insert(id)
                if attempt > failedRetries {
                    await answerDeviceListRead(id: id)
                    try await acknowledge(nextDeviceListPublish())
                    break
                }
                await failDeviceListRead(id: id)
            }

            try await Task.sleep(for: .milliseconds(200))
            let reads = await mock.sentBytes.count {
                let stanza = String(decoding: $0, as: UTF8.self)
                return stanza.contains("type=\"get\"") && stanza.contains(XMPPNamespaces.omemoDevices)
            }
            #expect(reads == 1 + min(failedRetries + 1, 3))

            await disconnectFast(client)
        }

        @Test
        func `A missing own device-list node publishes a list with this device`() async throws {
            let (client, connectTask) = await startConnect()

            let retrieve = await sentStanza(5)
            let id = try #require(extractIQID(from: retrieve))
            await mock.simulateReceive("""
            <iq type="error" id="\(id)"><error type="cancel">\
            <item-not-found xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/></error></iq>
            """)
            let listPublish = await sentStanza(6)
            #expect(listPublish.contains("<publish") && listPublish.contains("node=\"\(XMPPNamespaces.omemoDevices)\""))
            try await acknowledge(listPublish)
            let bundlePublish = await sentStanza(7)
            let deviceID = try publishedDeviceID(in: bundlePublish)
            #expect(listPublish.contains("<device id=\"\(deviceID)\""))
            try await acknowledge(bundlePublish)
            try await connectTask.value

            await disconnectFast(client)
        }
    }
}
