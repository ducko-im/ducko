import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

/// Delivers a device-list notification from `sender` (none when nil) and returns the devices announced, keyed by JID.
private func announcedDeviceLists(sender: String?) throws -> [String: [UInt32]] {
    let events = OSAllocatedUnfairLock<[XMPPEvent]>(initialState: [])
    let module = OMEMOModule(pepModule: PEPModule())
    module.setUp(makeStubModuleContext(emitEvent: { event in events.withLock { $0.append(event) } }))
    let from = sender.map { " from='\($0)'" } ?? ""

    try module.handleMessage(XMPPMessage(element: stanza("""
    <message\(from) to='user@example.com/res'>\
    <event xmlns='http://jabber.org/protocol/pubsub#event'>\
    <items node='urn:xmpp:omemo:2:devices'>\
    <item id='current'><devices xmlns='urn:xmpp:omemo:2'><device id='7'/></devices></item>\
    </items></event></message>
    """)))

    var lists: [String: [UInt32]] = [:]
    for case let .omemoDeviceListReceived(jid, devices) in events.withLock({ $0 }) {
        lists[jid.description] = devices
    }
    return lists
}

struct OMEMODeviceListNotificationTests {
    @Test
    func `A device list from a bare JID is announced for that JID`() throws {
        #expect(try announcedDeviceLists(sender: "peer@example.com") == ["peer@example.com": [7]])
    }

    @Test
    func `A device list without a sender is the account's own`() throws {
        #expect(try announcedDeviceLists(sender: nil) == ["user@example.com": [7]])
    }

    @Test(arguments: ["room@conference.example.com/nick", "@@"])
    func `A device list from anything but a bare JID is ignored`(sender: String) throws {
        #expect(try announcedDeviceLists(sender: sender).isEmpty)
    }
}

private let ownDeviceID: UInt32 = 4242

/// A notification from the account itself of a device list holding `devices`.
private func ownDeviceListNotification(_ devices: [UInt32]) -> String {
    """
    <message from='user@example.com'><event xmlns='http://jabber.org/protocol/pubsub#event'>\
    <items node='\(XMPPNamespaces.omemoDevices)'><item id='current'><devices xmlns='urn:xmpp:omemo:2'>\
    \(devices.map { "<device id='\($0)'/>" }.joined())</devices></item></items></event></message>
    """
}

/// An account whose OMEMO module holds device 4242, signing in through a mock server that the test plays.
private struct OwnDeviceAccount {
    let mock = MockTransport()
    let pepModule = PEPModule()
    let module: OMEMOModule

    init(registrationRetryDelays: [Duration] = [.seconds(10)]) throws {
        self.module = OMEMOModule(pepModule: pepModule, registrationRetryDelays: registrationRetryDelays)
        try module.configureIdentity(makeTestOMEMOIdentity(deviceID: ownDeviceID, preKeyIDs: [1]).data)
    }

    func startConnect() async -> (XMPPClient, Task<Void, any Error>) {
        let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "pass"), transport: mock, requireTLS: false, allowsPLAIN: true)
        await client.register(pepModule)
        await client.register(module)
        let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
        await simulateNoTLSConnect(mock)
        return (client, connectTask)
    }

    /// Signs in with this device already on the account's list, so the connect publishes only the bundle.
    func connect() async throws -> XMPPClient {
        let (client, connectTask) = await startConnect()
        try await answer(deviceListRequest(.get, at: 0), devices: [ownDeviceID])
        try await acknowledge(bundlePublish())
        try await connectTask.value
        return client
    }

    /// The device-list reads (`.get`) or publishes (`.set`) sent so far, in order.
    func deviceListRequests(_ type: XMPPIQ.IQType) async -> [String] {
        await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }.filter {
            $0.hasPrefix("<iq ") && $0.contains("type=\"\(type.rawValue)\"") && $0.contains("node=\"\(XMPPNamespaces.omemoDevices)\"")
        }
    }

    /// Waits for the device-list read or publish numbered `index`, counted from 0.
    func deviceListRequest(_ type: XMPPIQ.IQType, at index: Int) async throws -> String {
        try await eventually { await deviceListRequests(type).count > index }
        return await deviceListRequests(type)[index]
    }

    func bundlePublish() async throws -> String {
        try await awaitOutgoingIQ(on: mock, type: .set, namespace: XMPPNamespaces.pubsub) { $0.contains(XMPPNamespaces.omemoBundles) }.xml
    }

    func answer(_ read: String, devices: [UInt32]) async throws {
        let id = try #require(extractIQID(from: read))
        await mock.simulateReceive("""
        <iq type="result" id="\(id)"><pubsub xmlns="http://jabber.org/protocol/pubsub">\
        <items node="\(XMPPNamespaces.omemoDevices)"><item id="current"><devices xmlns="urn:xmpp:omemo:2">\
        \(devices.map { "<device id=\"\($0)\"/>" }.joined())</devices></item></items></pubsub></iq>
        """)
    }

    func fail(_ read: String) async throws {
        let id = try #require(extractIQID(from: read))
        await mock.simulateReceive("""
        <iq type="error" id="\(id)"><error type="wait"><internal-server-error xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/></error></iq>
        """)
    }

    func acknowledge(_ stanza: String) async throws {
        let id = try #require(extractIQID(from: stanza))
        await mock.simulateReceive("<iq type=\"result\" id=\"\(id)\"/>")
    }

    func notify(_ devices: [UInt32]) async {
        await mock.simulateReceive(ownDeviceListNotification(devices))
    }
}

extension OMEMODeviceListNotificationTests {
    /// The account's list must hold this device, so a notification without it is answered by adding it back (XEP-0384).
    /// Only one task at a time reads, changes and publishes the list.
    struct ReannounceTests {
        @Test
        func `An own list without this device is published again with it, and one with it publishes nothing`() async throws {
            let account = try OwnDeviceAccount()
            let client = try await account.connect()

            await account.notify([7, ownDeviceID])
            await account.notify([7])
            try await account.answer(account.deviceListRequest(.get, at: 1), devices: [7])
            let publish = try await account.deviceListRequest(.set, at: 0)
            try await account.acknowledge(publish)
            try await Task.sleep(for: .milliseconds(200))

            #expect(publish.contains("<device id=\"7\"") && publish.contains("<device id=\"\(ownDeviceID)\""))
            #expect(await account.deviceListRequests(.get).count == 2)
            await disconnectFast(client)
        }

        /// The connect reads, changes and publishes the list itself, so a re-announce meanwhile could undo its changes.
        /// The connect's read may predate the notification, so the re-announce follows once the connect ends.
        @Test
        func `An own list without this device that comes during the connect is re-announced once the connect ends`() async throws {
            let account = try OwnDeviceAccount()
            let (client, connectTask) = await account.startConnect()
            try await account.answer(account.deviceListRequest(.get, at: 0), devices: [ownDeviceID])
            let bundlePublish = try await account.bundlePublish()

            await account.notify([])
            try await Task.sleep(for: .milliseconds(200))
            #expect(await account.deviceListRequests(.get).count == 1)
            try await account.acknowledge(bundlePublish)
            try await connectTask.value
            try await account.answer(account.deviceListRequest(.get, at: 1), devices: [])
            let publish = try await account.deviceListRequest(.set, at: 0)
            try await account.acknowledge(publish)
            try await Task.sleep(for: .milliseconds(200))

            #expect(publish.contains("<device id=\"\(ownDeviceID)\""))
            #expect(await account.deviceListRequests(.get).count == 2)
            #expect(await account.deviceListRequests(.set).count == 1)
            await disconnectFast(client)
        }

        @Test
        func `An own list without this device that comes during a registration retry is re-announced after it`() async throws {
            let account = try OwnDeviceAccount(registrationRetryDelays: [.zero])
            let (client, connectTask) = await account.startConnect()
            try await account.fail(account.deviceListRequest(.get, at: 0))
            try await account.acknowledge(account.bundlePublish())
            try await connectTask.value
            let retryRead = try await account.deviceListRequest(.get, at: 1)

            await account.notify([])
            try await Task.sleep(for: .milliseconds(200))
            #expect(await account.deviceListRequests(.get).count == 2)
            try await account.answer(retryRead, devices: [99])
            let retryPublish = try await account.deviceListRequest(.set, at: 0)
            try await Task.sleep(for: .milliseconds(200))
            #expect(await account.deviceListRequests(.get).count == 2)
            try await account.acknowledge(retryPublish)
            try await account.answer(account.deviceListRequest(.get, at: 2), devices: [99])
            let reannounce = try await account.deviceListRequest(.set, at: 1)
            try await account.acknowledge(reannounce)

            #expect(reannounce.contains("<device id=\"99\"") && reannounce.contains("<device id=\"\(ownDeviceID)\""))
            await disconnectFast(client)
        }

        @Test
        func `A later own list without this device is re-announced again`() async throws {
            let account = try OwnDeviceAccount()
            let client = try await account.connect()

            for round in 0 ..< 2 {
                await account.notify([])
                try await account.answer(account.deviceListRequest(.get, at: round + 1), devices: [])
                try await account.acknowledge(account.deviceListRequest(.set, at: round))
                // The next notification finds no re-announce running, rather than one that would take it up.
                try await eventually { account.module.state.withLock { $0.ownListTask == nil } }
            }

            #expect(await account.deviceListRequests(.set).count == 2)
            await disconnectFast(client)
        }

        /// A resumed session runs no connect of its own, so nothing holds a re-announce back.
        @Test
        func `A resumed session's module re-announces this device`() async throws {
            let iqs = OSAllocatedUnfairLock<[XMLElement]>(initialState: [])
            let context = makeStubModuleContext(sendIQ: { iq, _ in
                iqs.withLock { $0.append(iq.element) }
                guard iq.element.child(named: "pubsub")?.child(named: "items") != nil else { return nil }
                return try stanza("""
                <pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='\(XMPPNamespaces.omemoDevices)'>\
                <item id='current'><devices xmlns='urn:xmpp:omemo:2'><device id='7'/></devices></item></items></pubsub>
                """)
            })
            let module = try makeInstalledOMEMOModule(identity: makeTestOMEMOIdentity(deviceID: ownDeviceID, preKeyIDs: [1]).data, context: context)

            try module.handleMessage(XMPPMessage(element: stanza(ownDeviceListNotification([7]))))

            try await eventually { iqs.withLock { $0.contains { $0.child(named: "pubsub")?.child(named: "publish") != nil } } }
            let publish = try #require(iqs.withLock { $0.first { $0.child(named: "pubsub")?.child(named: "publish") != nil } })
            #expect(publish.xmlString.contains("<device id=\"\(ownDeviceID)\""))
        }
    }
}
