import DuckoTestSupport
import os
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private let testFeaturesBindWithCSI = """
<features xmlns='http://etherx.jabber.org/streams'>\
<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>\
<csi xmlns='urn:xmpp:csi:0'/>\
</features>
"""

private func makeConnectedClient(mock: MockTransport, withCSI: Bool = true) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(CSIModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock, postAuthFeatures: withCSI ? testFeaturesBindWithCSI : testFeaturesBind)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum CSIModuleTests {
    struct SendInactive {
        @Test
        func `Sends <inactive/> nonza when server supports CSI`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            let csiModule = try #require(await client.module(ofType: CSIModule.self))
            try await csiModule.sendInactive()

            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let inactive = sentStrings.first { $0.contains("<inactive") && $0.contains("urn:xmpp:csi:0") }
            #expect(inactive != nil)

            await disconnectFast(client)
        }
    }

    struct SendActive {
        @Test
        func `Sends <active/> nonza after becoming inactive`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let csiModule = try #require(await client.module(ofType: CSIModule.self))
            try await csiModule.sendInactive()

            await mock.clearSentBytes()

            try await csiModule.sendActive()

            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let active = sentStrings.first { $0.contains("<active") && $0.contains("urn:xmpp:csi:0") }
            #expect(active != nil)

            await disconnectFast(client)
        }
    }

    struct DuplicateSuppression {
        @Test
        func `Does not send <active/> when already active`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            // Default state after connect is active — sending active again should be a no-op
            let csiModule = try #require(await client.module(ofType: CSIModule.self))
            try await csiModule.sendActive()

            // Brief wait to ensure nothing is sent
            try? await Task.sleep(for: .milliseconds(50))

            let sentData = await mock.sentBytes
            #expect(sentData.isEmpty)

            await disconnectFast(client)
        }

        @Test
        func `Does not send <inactive/> when already inactive`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let csiModule = try #require(await client.module(ofType: CSIModule.self))
            try await csiModule.sendInactive()

            await mock.clearSentBytes()

            // Sending inactive again should be a no-op
            try await csiModule.sendInactive()

            // Brief wait to ensure nothing is sent
            try? await Task.sleep(for: .milliseconds(50))

            let sentData = await mock.sentBytes
            #expect(sentData.isEmpty)

            await disconnectFast(client)
        }
    }

    struct NoServerSupport {
        @Test
        func `Does not send when server does not advertise CSI`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock, withCSI: false)

            await mock.clearSentBytes()

            let csiModule = try #require(await client.module(ofType: CSIModule.self))
            try await csiModule.sendInactive()

            // Brief wait to ensure nothing is sent
            try? await Task.sleep(for: .milliseconds(50))

            let sentData = await mock.sentBytes
            #expect(sentData.isEmpty)

            await disconnectFast(client)
        }
    }

    struct StreamResume {
        @Test
        func `Detects server support via handleResume`() async throws {
            let module = CSIModule()
            var features = XMLElement(name: "features", namespace: "http://etherx.jabber.org/streams")
            features.addChild(XMLElement(name: "csi", namespace: XMPPNamespaces.csi))
            let csiFeatures = features

            let sendCount = OSAllocatedUnfairLock(initialState: 0)
            let context = makeStubModuleContext(
                sendElement: { _ in sendCount.withLock { $0 += 1 } },
                serverStreamFeatures: { csiFeatures }
            )
            module.setUp(context)

            // Before handleResume, sendInactive should be a no-op (serverSupported is false)
            try await module.sendInactive()
            #expect(sendCount.withLock { $0 } == 0)

            // After handleResume, CSI should be detected and sendInactive should work
            try await module.handleResume()
            try await module.sendInactive()
            #expect(sendCount.withLock { $0 } == 1)
        }

        /// The module built for the resumed stream does not know what the server last heard, so it says active again.
        @Test
        func `Sends active after a resume, whatever the state before the drop`() async throws {
            let module = CSIModule()
            var features = XMLElement(name: "features", namespace: "http://etherx.jabber.org/streams")
            features.addChild(XMLElement(name: "csi", namespace: XMPPNamespaces.csi))
            let csiFeatures = features
            let sent = OSAllocatedUnfairLock<[String]>(initialState: [])
            module.setUp(makeStubModuleContext(
                sendElement: { element in sent.withLock { $0.append(element.name) } },
                serverStreamFeatures: { csiFeatures }
            ))

            try await module.handleResume()
            try await module.sendActive()
            try await module.sendActive()

            #expect(sent.withLock { $0 } == ["active"])
        }
    }

    struct DiscoFeature {
        @Test
        func `Does not advertise CSI in disco features`() {
            let module = CSIModule()
            #expect(module.features.isEmpty)
        }
    }
}
