import DuckoTestSupport
import Testing
@testable import DuckoXMPP

extension OMEMOModuleTests {
    struct DeviceListFetchFailureTests {
        private let mock = MockTransport()
        private let pepModule = PEPModule()
        private let omemoModule: OMEMOModule

        init() {
            self.omemoModule = OMEMOModule(pepModule: pepModule, setupRetryDelays: [.zero, .zero, .zero])
        }

        private func startConnect() async -> (XMPPClient, Task<Void, any Error>) {
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

        private func nextBundlePublish() async throws -> String {
            try await awaitOutgoingIQ(on: mock, type: .set, namespace: XMPPNamespaces.pubsub) {
                $0.contains("node=\"\(XMPPNamespaces.omemoBundles)\"")
            }.xml
        }

        private func publishedDeviceID(in bundlePublish: String) throws -> Substring {
            let itemStart = try #require(bundlePublish.range(of: "<item id=\""))
            return bundlePublish[itemStart.upperBound...].prefix { $0.isNumber }
        }

        /// A fetch that fails for any reason but a missing node leaves the setup incomplete, and publishes nothing over
        /// the unread list. The next attempt adds the device from a fresh read, then publishes the bundle. Only an
        /// existing device gets this far: a new one is not created over an unread list.
        @Test(arguments: [false, true])
        func `A failed own device-list fetch registers the device from a fresh read`(failsAtSend: Bool) async throws {
            try omemoModule.configureIdentity(OMEMO2Fixtures.device("bob").identityData)
            if failsAtSend {
                // The connect's read fails at the send, so the first read the test answers is the retry's.
                await mock.failNextSend(matching: XMPPNamespaces.omemoDevices, error: XMPPClientError.sendFailed("The connection was closed"))
            }
            let (client, connectTask) = await startConnect()
            let statuses = SetupStatusRecorder(client: client)
            try await connectTask.value

            var answered: Set<String> = []
            if !failsAtSend {
                let id = try #require(await extractIQID(from: sentStanza(5)))
                await failDeviceListRead(id: id)
                answered.insert(id)
            }
            try await answerDeviceListRead(id: nextDeviceListRead(after: answered))
            let listPublish = try await nextDeviceListPublish()
            try await acknowledge(listPublish)
            let bundlePublish = try await nextBundlePublish()
            let deviceID = try publishedDeviceID(in: bundlePublish)
            #expect(listPublish.contains("<device id=\"99\"") && listPublish.contains("<device id=\"\(deviceID)\""))
            try await acknowledge(bundlePublish)

            try await eventually { statuses.recorded == [.incomplete, .complete] }
            await disconnectFast(client)
        }

        /// An attempt whose read fails waits for the next delay. Attempts stop after the first that completes, or after
        /// the last delay.
        @Test(arguments: [1, 3])
        func `Setup retries stop after completion or the last delay`(failedRetries: Int) async throws {
            try omemoModule.configureIdentity(OMEMO2Fixtures.device("bob").identityData)
            let (client, connectTask) = await startConnect()
            let statuses = SetupStatusRecorder(client: client)
            let connectReadID = try #require(await extractIQID(from: sentStanza(5)))
            await failDeviceListRead(id: connectReadID)
            try await connectTask.value

            var answered: Set<String> = [connectReadID]
            for attempt in 1 ... 3 {
                let id = try await nextDeviceListRead(after: answered)
                answered.insert(id)
                if attempt > failedRetries {
                    await answerDeviceListRead(id: id)
                    try await acknowledge(nextDeviceListPublish())
                    try await acknowledge(nextBundlePublish())
                    break
                }
                await failDeviceListRead(id: id)
            }

            let completes = failedRetries < 3
            let expected = Array(repeating: OMEMOSetupStatus.incomplete, count: min(failedRetries, 3) + 1) + (completes ? [.complete] : [])
            try await eventually { statuses.recorded == expected }
            try await Task.sleep(for: .milliseconds(200))
            let reads = await mock.sentBytes.count {
                let stanza = String(decoding: $0, as: UTF8.self)
                return stanza.contains("type=\"get\"") && stanza.contains(XMPPNamespaces.omemoDevices)
            }
            #expect(reads == 1 + min(failedRetries + 1, 3))
            #expect(statuses.recorded == expected)

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
