import AppKit
import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoUI

@MainActor
struct RosterOutcomeTests {
    @Test func `the contact info removal preserves a partial notice with account and contact context`() async throws {
        let fixture = try await RosterUIFixture.connected()
        let state = ContactInfoWindowState(ref: ContactInfoRef(accountID: fixture.accountID, jid: "bob@example.com"), environment: fixture.environment)
        await state.load()
        let action = Task { await state.remove() }

        try await fixture.completeRemovalWithFailedReadback()

        await action.value
        #expect(state.contact == nil)
        #expect(!state.isRemoving)
        #expect(state.rosterNotice?.contains("alice@example.com") == true)
        #expect(state.rosterNotice?.contains("bob@example.com") == true)
        #expect(state.rosterNotice?.contains("sync") == true)
        await fixture.tearDown()
    }

    @Test func `the contact list removal confirms first and preserves a partial notice`() async throws {
        let fixture = try await RosterUIFixture.connected()
        let contact = try #require(fixture.environment.rosterService.contact(jidString: "bob@example.com", accountID: fixture.accountID))
        let windowState = ContactListWindowState()
        let builder = ContactListMenuBuilder(
            openChat: OpenChatAction { _, _ in }, openWindow: nil, transcriptScope: nil, presentSheet: { _ in },
            requestRemoval: { windowState.requestRemoval(of: $0) }, target: NSView(), action: Selector(("unused:"))
        )
        let menu = try #require(builder.menu(for: .contact(sectionName: "Ungrouped", contact: contact), environment: fixture.environment))
        let item = try #require(menu.items.first { $0.accessibilityIdentifier() == "contact-context-remove" })
        try #require(item.representedObject as? MenuCommand).run()

        // The context item only asks for confirmation; nothing reaches the server yet.
        let requested = try #require(windowState.pendingRemoval)
        #expect(requested.jid == contact.jid)
        #expect(requested.accountID == contact.accountID)
        let sent = await fixture.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        #expect(!sent.contains { $0.contains("jabber:iq:roster") })

        // Dismissing the confirmation dialog clears the pending removal before the confirmed removal runs.
        windowState.pendingRemoval = nil
        let action = Task { await windowState.confirmRemoval(requested, environment: fixture.environment) }

        try await fixture.completeRemovalWithFailedReadback()

        await action.value
        #expect(windowState.rosterNotice?.contains("alice@example.com") == true)
        #expect(windowState.rosterNotice?.contains("bob@example.com") == true)
        // Only the confirmed removal reached the server, not a second one started by the context item itself.
        let rosterSets = await fixture.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            .filter { $0.contains("jabber:iq:roster") && $0.contains("type=\"set\"") }
        #expect(rosterSets.count == 1)
        await fixture.tearDown()
    }
}

@MainActor
private final class RosterUIFixture {
    let transport: MockTransport
    let environment: AppEnvironment
    let accountID: UUID
    private let server: MockServerSession

    private init(server: MockServerSession, environment: AppEnvironment, accountID: UUID) {
        self.transport = server.transport
        self.server = server
        self.environment = environment
        self.accountID = accountID
    }

    static func connected() async throws -> RosterUIFixture {
        let transport = MockTransport()
        let environment = AppEnvironment(
            store: MockPersistenceStore(), transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore(),
            clientFactory: MockXMPPClientFactory(transport: transport, modules: [RosterModule()])
        )
        let id = try await environment.accountService.createAccount(jidString: "alice@example.com")
        let server = MockServerSession(transport: transport)
        try await server.connect(environment, accountID: id) { server in
            let initial = try await server.next("jabber:iq:roster")
            await server.reply(to: initial, contents: "<query xmlns='jabber:iq:roster'><item jid='bob@example.com'/></query>")
        }
        try await waitUntil { environment.rosterService.contact(jidString: "bob@example.com", accountID: id) != nil }
        await transport.clearSentBytes()
        return RosterUIFixture(server: server, environment: environment, accountID: id)
    }

    /// Acknowledges the removal, then removes the contact by push while its readback is still pending, so the
    /// confirmed removal ends with an incomplete outcome.
    func completeRemovalWithFailedReadback() async throws {
        let mutation = try await server.next("type=\"set\"")
        await server.reply(to: mutation)
        let readback = try await server.next("type=\"get\"")
        await transport.simulateReceive("<iq type='set' id='removed'><query xmlns='jabber:iq:roster'><item jid='bob@example.com' subscription='remove'/></query></iq>")
        try await waitUntil { self.environment.rosterService.contact(jidString: "bob@example.com", accountID: self.accountID) == nil }
        await server.reply(to: readback)
    }

    func tearDown() async {
        await environment.accountService.disconnect(accountID: accountID)
        await environment.shutdown(within: .seconds(2))
    }
}
