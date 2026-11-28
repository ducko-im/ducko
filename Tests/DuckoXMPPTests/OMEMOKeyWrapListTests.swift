import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

private let bob = BareJID(localPart: "bob", domainPart: "example.com")!
private let carol = BareJID(localPart: "carol", domainPart: "example.com")!

/// A message carries keys only for devices still on their owner's list once every key is wrapped, since a list
/// notification, or a fetch that finds the list's node missing, can remove a device while bundles are fetched (XEP-0384).
struct OMEMOKeyWrapListTests {
    /// Bob's device 201's bundle fetch is held while a notification leaves `removed` off bob's list: 201 itself, or 200,
    /// whose key is already wrapped by then.
    @Test(arguments: [UInt32(201), 200])
    func `a device a list notification removes while bundles are fetched gets no key`(removed: UInt32) async throws {
        let devices = try [200, 201].map { try makeTestOMEMOIdentity(deviceID: $0, preKeyIDs: [7]) }
        let heldFetch = AsyncSemaphore()
        let releaseFetch = AsyncSemaphore()
        let context = makeStubModuleContext(sendIQ: { iq, _ in
            let itemID = iq.element.child(named: "pubsub")?.child(named: "items")?.child(named: "item")?.attribute("id")
            guard let device = devices.first(where: { itemID == "\($0.data.deviceID)" }) else { return nil }
            if device.data.deviceID == 201 {
                await heldFetch.signal()
                await releaseFetch.wait()
            }
            return bundleItems(for: device)
        })
        let module = try makeInstalledOMEMOModule(identity: makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1]).data, context: context)
        try notifyBobsList([200, 201], to: module)

        let encryption = Task {
            try await module.encryptMessage(plaintext: "hi", to: bob, recipientDeviceIDs: [200, 201], ownDeviceIDs: [])
        }
        await heldFetch.wait()
        try await eventually { module.exportSession(jid: bob, deviceID: 200, version: .omemo2) != nil }
        try notifyBobsList([200, 201].filter { $0 != removed }, to: module)
        await releaseFetch.signal()
        let elements = try await encryption.value

        let keys = try elements.omemo2.child(named: "header")?.child(named: "keys")?.children(named: "key") ?? []
        #expect(keys.map { $0.attribute("rid") } == ["\(removed == 200 ? 201 : 200)"])
        #expect(elements.droppedRecipients == [DroppedOMEMORecipient(jid: bob, deviceID: removed)])
    }

    /// Bob's device 201's bundle fetch is held while a forced fetch finds bob's device-list node missing, after device
    /// 200's key is wrapped. Neither gets a key, and carol, whose list the module has not cached, keeps hers.
    @Test func `a device whose list node a forced fetch finds missing while bundles are fetched gets no key`() async throws {
        let devices = try [200, 201, 300].map { try makeTestOMEMOIdentity(deviceID: $0, preKeyIDs: [7]) }
        let heldFetch = AsyncSemaphore()
        let releaseFetch = AsyncSemaphore()
        let context = makeStubModuleContext(sendIQ: { iq, _ in
            let items = iq.element.child(named: "pubsub")?.child(named: "items")
            if items?.attribute("node") == XMPPNamespaces.omemoDevices, iq.element.attribute("to") == bob.description {
                throw XMPPStanzaError(errorType: .cancel, condition: .itemNotFound)
            }
            let itemID = items?.child(named: "item")?.attribute("id")
            guard let device = devices.first(where: { itemID == "\($0.data.deviceID)" }) else { return nil }
            if device.data.deviceID == 201 {
                await heldFetch.signal()
                await releaseFetch.wait()
            }
            return bundleItems(for: device)
        })
        let module = try makeInstalledOMEMOModule(identity: makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1]).data, context: context)
        try notifyBobsList([200, 201], to: module)

        let encryption = Task {
            try await module.encryptGroupMessage(
                plaintext: "hi", roomJID: BareJID(localPart: "room", domainPart: "conference.example.com")!,
                recipients: [(jid: bob, deviceIDs: [200, 201]), (jid: carol, deviceIDs: [300])], ownDeviceIDs: []
            )
        }
        await heldFetch.wait()
        try await eventually { module.exportSession(jid: bob, deviceID: 200, version: .omemo2) != nil }
        #expect(try await module.fetchDeviceList(for: bob, forceRefresh: true, version: .omemo2) == [])
        await releaseFetch.signal()
        let elements = try await encryption.value

        let keys = try elements.omemo2.child(named: "header")?.child(named: "keys")?.children(named: "key") ?? []
        #expect(keys.map { $0.attribute("rid") } == ["300"])
        #expect(elements.droppedRecipients.sorted { $0.deviceID < $1.deviceID } == [200, 201].map {
            DroppedOMEMORecipient(jid: bob, deviceID: $0)
        })
    }
}

private func notifyBobsList(_ devices: [UInt32], to module: OMEMOModule) throws {
    try module.handleMessage(XMPPMessage(element: stanza("""
    <message from='\(bob)' to='user@example.com/res'><event xmlns='\(XMPPNamespaces.pubsubEvent)'>\
    <items node='\(XMPPNamespaces.omemoDevices)'><item id='current'><devices xmlns='\(XMPPNamespaces.omemo)'>\
    \(devices.map { "<device id='\($0)'/>" }.joined())</devices></item></items></event></message>
    """)))
}
