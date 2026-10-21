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
