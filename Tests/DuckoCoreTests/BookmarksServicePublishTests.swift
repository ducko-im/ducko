import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let pepIdentity = "<identity category='pubsub' type='pep'/>"
private let publishOptionsFeature = "<feature var='http://jabber.org/protocol/pubsub#publish-options'/>"

/// A connected account whose server answers its own disco#info with `ownInfo` and accepts every publish.
@MainActor
private struct PublishHarness {
    let service: BookmarksService
    // periphery:ignore - Held only to keep BookmarksService.accountService (a weak ref) alive
    let accountService: AccountService
    let transport: MockTransport
    let accountID: UUID

    func published() async -> Bool {
        await transport.sentBytes.contains { String(decoding: $0, as: UTF8.self).contains("<publish ") }
    }
}

@MainActor
private func makePublishHarness(ownInfo: String) async throws -> PublishHarness {
    let transport = MockTransport()
    await transport.autoReply { stanza in
        guard let id = extractIQID(from: stanza) else { return nil }
        if stanza.contains("disco#info"), stanza.contains("to=\"\(testJIDString)\"") {
            return "<iq type='result' id='\(id)'><query xmlns='http://jabber.org/protocol/disco#info'>\(ownInfo)</query></iq>"
        }
        if stanza.contains("<publish ") {
            return "<iq type='result' id='\(id)'/>"
        }
        return nil
    }
    let factory = MockXMPPClientFactory(transport: transport, modules: [ServiceDiscoveryModule(), PEPModule()])
    let accountService = makeAccountService(store: MockPersistenceStore(), clientFactory: factory)
    let bookmarksService = BookmarksService()
    bookmarksService.setAccountService(accountService)

    let connectTask = Task { @MainActor in
        try await accountService.createAndConnect(
            jidString: testJIDString, password: "secret", host: "example.com", port: 5222
        )
    }
    await simulateNoTLSConnect(transport)
    let accountID = try await connectTask.value
    return PublishHarness(service: bookmarksService, accountService: accountService, transport: transport, accountID: accountID)
}

struct BookmarksServicePublishTests {
    @Test(arguments: [pepIdentity, publishOptionsFeature])
    @MainActor
    func `a bookmark is not stored where the server cannot keep it private`(ownInfo: String) async throws {
        let harness = try await makePublishHarness(ownInfo: ownInfo)

        let error = await #expect(throws: BookmarksError.self) {
            try await harness.service.addBookmark(
                RoomBookmark(jidString: "room@conference.example.com", password: "secret"), accountID: harness.accountID
            )
        }
        guard case .privateStorageUnsupported? = error else {
            Issue.record("Expected privateStorageUnsupported, got \(String(describing: error))")
            return
        }

        #expect(await !harness.published())
        #expect(harness.service.bookmarks.isEmpty)
    }

    @Test
    @MainActor
    func `a bookmark is stored where the server supports PEP publish options`() async throws {
        let harness = try await makePublishHarness(ownInfo: pepIdentity + publishOptionsFeature)

        try await harness.service.addBookmark(RoomBookmark(jidString: "room@conference.example.com"), accountID: harness.accountID)

        #expect(await harness.published())
        #expect(harness.service.bookmarks.map(\.jidString) == ["room@conference.example.com"])
    }
}
