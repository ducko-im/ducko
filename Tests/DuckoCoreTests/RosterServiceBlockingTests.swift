import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let bobJID = BareJID(localPart: "bob", domainPart: "example.com")!
private let bobLaptop = FullJID.parse("bob@example.com/laptop")!

@MainActor
struct RosterServiceBlockingTests {
    @Test(arguments: [
        ([JID.bare(bobJID), .full(bobLaptop)], true),
        ([.full(bobLaptop)], false)
    ])
    func `A contact reads as blocked only through the entry naming its bare JID`(blockList: [JID], isBlocked: Bool) async throws {
        let fixture = RosterServiceFixture(store: MockPersistenceStore())
        let accountID = UUID()
        await fixture.deliver(.snapshot([RosterItem(jid: bobJID, subscription: .both)]), accountID: accountID)

        await fixture.service.handleEvent(.blockListLoaded(blockList), accountID: accountID)

        let contact = try #require(fixture.service.contact(jidString: bobJID.description, accountID: accountID))
        #expect(contact.isBlocked == isBlocked)
        #expect(fixture.service.blockList(for: accountID).map(\.jidString) == blockList.map(\.description).sorted())
    }

    @Test
    func `A block pushed for one device of a contact leaves the contact unblocked`() async {
        let fixture = RosterServiceFixture(store: MockPersistenceStore())
        let accountID = UUID()
        await fixture.deliver(.snapshot([RosterItem(jid: bobJID, subscription: .both)]), accountID: accountID)

        await fixture.service.handleEvent(.contactBlocked(.full(bobLaptop)), accountID: accountID)

        #expect(fixture.service.contact(jidString: bobJID.description, accountID: accountID)?.isBlocked == false)
        #expect(fixture.service.blockList(for: accountID).map(\.jidString) == [bobLaptop.description])

        // Armed: a push for the contact itself blocks it.
        await fixture.service.handleEvent(.contactBlocked(.bare(bobJID)), accountID: accountID)
        #expect(fixture.service.contact(jidString: bobJID.description, accountID: accountID)?.isBlocked == true)
    }

    @Test
    func `Purging an account drops its block list`() async {
        let fixture = RosterServiceFixture(store: MockPersistenceStore())
        let accountID = UUID()
        await fixture.service.handleEvent(.blockListLoaded([.bare(bobJID)]), accountID: accountID)
        #expect(!fixture.service.blockList(for: accountID).isEmpty)

        fixture.service.purgeAccount(accountID)

        #expect(fixture.service.blockList(for: accountID).isEmpty)
    }

    @Test
    func `A contact's Unblock removes its bare entry and keeps the entry for one of its devices`() async throws {
        let store = MockPersistenceStore()
        let transport = MockTransport()
        let accountService = makeAccountService(store: store, clientFactory: MockXMPPClientFactory(transport: transport, modules: [BlockingModule()]))
        let service = RosterService(store: store)
        service.setAccountService(accountService)
        let connectTask = Task { @MainActor in
            try await accountService.createAndConnect(jidString: testJIDString, password: "secret", host: "example.com", port: 5222)
        }
        await simulateNoTLSConnect(transport)
        let disco = try await sentStanza(on: transport, containing: XMPPNamespaces.discoInfo)
        try await transport.simulateReceive("""
        <iq type='result' id='\(#require(extractIQID(from: disco)))' from='example.com'>\
        <query xmlns='http://jabber.org/protocol/disco#info'><feature var='urn:xmpp:blocking'/></query></iq>
        """)
        let listRequest = try await sentStanza(on: transport, containing: "<blocklist")
        try await transport.simulateReceive("<iq type='result' id='\(#require(extractIQID(from: listRequest)))'><blocklist xmlns='urn:xmpp:blocking'/></iq>")
        let accountID = try await connectTask.value
        let fixture = RosterServiceFixture(store: store, service: service)
        await fixture.deliver(.snapshot([RosterItem(jid: bobJID, subscription: .both)]), accountID: accountID)
        await service.handleEvent(.blockListLoaded([.bare(bobJID), .full(bobLaptop)]), accountID: accountID)
        let contact = try #require(service.contact(jidString: bobJID.description, accountID: accountID))
        #expect(contact.isBlocked)

        let unblock = Task { @MainActor in
            try await service.unblockContact(jidString: contact.jid.description, accountID: accountID)
        }
        let request = try await sentStanza(on: transport, containing: "<unblock")
        #expect(request.contains("jid=\"bob@example.com\""))
        #expect(!request.contains(bobLaptop.description))
        try await transport.simulateReceive("<iq type='result' id='\(#require(extractIQID(from: request)))'/>")
        try await unblock.value
        await service.handleEvent(.contactUnblocked(.bare(bobJID)), accountID: accountID)

        #expect(service.blockList(for: accountID).map(\.jidString) == [bobLaptop.description])
        #expect(service.contact(jidString: bobJID.description, accountID: accountID)?.isBlocked == false)
        await accountService.disconnect(accountID: accountID)
    }
}
