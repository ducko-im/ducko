import DuckoTestSupport
import Foundation
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

@MainActor
private struct ConnectedAvatarService {
    let service: AvatarService
    let accountService: AccountService
    let transport: MockTransport
    let store: MockPersistenceStore
    let accountID: UUID
    let peerJID: BareJID
    // periphery:ignore - Held to keep AvatarService's weak rosterService/presenceService refs alive
    let rosterService: RosterService
    // periphery:ignore - Held to keep AvatarService's weak rosterService/presenceService refs alive
    let presenceService: PresenceService
}

/// Connects an `AvatarService` against a mock transport with real `VCardModule` + `PEPModule`, wired to a
/// `RosterService`/`PresenceService` over the same store, and seeds a peer contact for the ingestion paths.
/// The connect handshake sends 4 stanzas, so the first service-driven IQ lands at sent index 4.
@MainActor
private func connectAvatarService() async throws -> ConnectedAvatarService {
    let store = MockPersistenceStore()
    let transport = MockTransport()
    let factory = MockXMPPClientFactory(transport: transport, modules: [VCardModule(), PEPModule()])
    let accountService = makeAccountService(store: store, clientFactory: factory)

    let rosterService = RosterService(store: store)
    rosterService.setAccountService(accountService)
    let presenceService = PresenceService()
    presenceService.setAccountService(accountService)

    let service = AvatarService(store: store)
    service.setAccountService(accountService)
    service.setRosterService(rosterService)
    service.setPresenceService(presenceService)

    let connectTask = Task { @MainActor in
        try await accountService.createAndConnect(
            jidString: testJIDString, password: "secret", host: "example.com", port: 5222
        )
    }
    await simulateNoTLSConnect(transport)
    let accountID = try await connectTask.value

    let peerJID = try #require(BareJID.parse("peer@example.com"))
    try await store.upsertContact(Contact(
        id: UUID(), accountID: accountID, jid: peerJID,
        subscription: .both, groups: [], isBlocked: false, createdAt: Date()
    ))

    return ConnectedAvatarService(
        service: service, accountService: accountService, transport: transport,
        store: store, accountID: accountID, peerJID: peerJID,
        rosterService: rosterService, presenceService: presenceService
    )
}

// MARK: - IQ Response Helpers

/// Answers the `get` at `sentIndex` with a result IQ wrapping `body`. Peer-addressed fetches must echo `from`
/// (set to the peer JID) so `sendIQ` correlates the reply to its request; own-vCard fetches (`to`-less) pass
/// `from: nil`.
///
/// The result is delivered in ≤1 MiB chunks to mimic real chunked TCP delivery. Small stanzas arrive in a
/// single chunk (unchanged); the over-cap avatar payloads (~11 MiB of base64) would otherwise be fed to the
/// libxml2 push parser as one text node exceeding its 10 MB single-node limit, which aborts the parse.
@MainActor
private func answerGet(_ transport: MockTransport, sentIndex: Int, from: String? = nil, body: String) async throws {
    await transport.waitForSent(count: sentIndex + 1)
    let sent = await transport.sentBytes
    let id = try #require(extractIQID(from: String(decoding: sent[sentIndex], as: UTF8.self)))
    let fromAttr = from.map { " from='\($0)'" } ?? ""
    let bytes = Array("<iq type='result'\(fromAttr) id='\(id)'>\(body)</iq>".utf8)
    let chunkSize = 1024 * 1024
    var i = 0
    while i < bytes.count {
        let end = min(i + chunkSize, bytes.count)
        await transport.simulateReceive(String(decoding: bytes[i ..< end], as: UTF8.self))
        i = end
    }
}

/// A vCard result body, optionally carrying a `<PHOTO>` whose `<BINVAL>` is `binval`. A nil `binval` yields a
/// photo-less vCard (the on-demand fallback "no avatar" case).
private func vcardBody(binval: String?, type: String = "image/png") -> String {
    guard let binval else { return "<vCard xmlns='vcard-temp'/>" }
    return "<vCard xmlns='vcard-temp'><PHOTO><TYPE>\(type)</TYPE><BINVAL>\(binval)</BINVAL></PHOTO></vCard>"
}

/// A PubSub `items` result body for a PEP `retrieveItems`. A nil `payload` yields an empty `<items/>` (the "no
/// published item" case that makes a retrieve return nothing).
private func pepItemsBody(node: String, itemID: String? = nil, payload: String? = nil) -> String {
    let inner = if let itemID, let payload { "<item id='\(itemID)'>\(payload)</item>" } else { "" }
    return "<pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='\(node)'>\(inner)</items></pubsub>"
}

private func avatarDataElement(_ base64: String) -> String {
    "<data xmlns='urn:xmpp:avatar:data'>\(base64)</data>"
}

private func avatarMetadataElement(id: String, type: String = "image/png") -> String {
    "<metadata xmlns='urn:xmpp:avatar:metadata'><info id='\(id)' type='\(type)'/></metadata>"
}

/// A PEP avatar-metadata notification item, as delivered by `.pepItemsPublished`. Its payload is the
/// `<metadata><info id=…>` element `handleAvatarMetadataPublished` parses to drive the data fetch. A nil `id`
/// omits the `<info>` `id` attribute and an empty `id` emits `<info id=''/>` — both are the malformed cases
/// `handleAvatarMetadataPublished` ignores, since XEP-0084 requires the id.
private func avatarMetadataItem(id: String?, type: String = "image/png") -> PEPItem {
    var metadata = DuckoXMPP.XMLElement(name: "metadata", namespace: XMPPNamespaces.avatarMetadata)
    var attributes = ["type": type]
    if let id { attributes["id"] = id }
    metadata.addChild(DuckoXMPP.XMLElement(name: "info", attributes: attributes))
    return PEPItem(id: id ?? "current", payload: metadata)
}

@MainActor
private func fetchPeerContact(_ connected: ConnectedAvatarService) async throws -> Contact {
    let contacts = try await connected.store.fetchContacts(for: connected.accountID)
    return try #require(contacts.first(where: { $0.jid == connected.peerJID }))
}

// MARK: - Avatar Payload Fixtures

/// All over-cap payloads derive from `AvatarLimits.maxBytes` so the cap can move without rewriting the tests.
private enum AvatarPayloads {
    /// A minimal valid 1×1 PNG, base64-encoded — the accepted (under-cap) payload.
    static let validPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    /// The PEP outer pre-check threshold: `base64Text.utf8.count <= maxBytes / 3 * 4 + 4`.
    static let outerThreshold = AvatarLimits.maxBytes / 3 * 4 + 4

    /// Trips the PEP *outer* base64-length pre-check alone: the small valid PNG padded with ignorable newlines
    /// so the encoded length exceeds `outerThreshold` while the decoded bytes stay tiny. An inverted outer
    /// comparison would decode-and-accept this small payload, failing the expect-dropped assertion.
    static let outerOverCapBase64: String = {
        let padding = max(0, outerThreshold + 1 - validPNGBase64.utf8.count)
        return validPNGBase64 + String(repeating: "\n", count: padding)
    }()

    /// Trips the *inner* decoded-count guard alone: exactly `outerThreshold` characters (so it passes the PEP
    /// outer pre-check) but decodes to `maxBytes + 1` bytes. Also drives the vCard `photoData.count` guard.
    static let innerOverCapBase64 = Data(count: AvatarLimits.maxBytes + 1).base64EncodedString()
}

// MARK: - PresenceModule Harness

/// Vends a fresh transport per connect so a same-account reconnect lands on a new transport while the first
/// stays alive to answer an in-flight IQ. `@Sendable` because the factory closure may run off the main actor.
private final class TransportVendor: Sendable {
    private let transports: OSAllocatedUnfairLock<[MockTransport]>

    init(_ list: [MockTransport]) {
        self.transports = OSAllocatedUnfairLock(initialState: list)
    }

    func next() -> MockTransport {
        transports.withLock { $0.isEmpty ? MockTransport() : $0.removeFirst() }
    }
}

@MainActor
private struct PresenceModuleFixture {
    let service: AvatarService
    let accountService: AccountService
    let transport1: MockTransport
    let transport2: MockTransport
    let accountID: UUID
    let client1: XMPPClient
    // periphery:ignore - Held to keep AvatarService's weak rosterService/presenceService refs alive
    let rosterService: RosterService
    // periphery:ignore - Held to keep AvatarService's weak rosterService/presenceService refs alive
    let presenceService: PresenceService
}

/// Connects an `AvatarService` whose client also carries a `PresenceModule`, without which `publishAvatar`,
/// `removeAvatar` and the own-vCard reload on sign-in or resume return early.
/// Returns the first transport/client plus a second transport the reconnect will land on.
@MainActor
private func connectWithPresenceModule() async throws -> PresenceModuleFixture {
    let store = MockPersistenceStore()
    let transport1 = MockTransport()
    let transport2 = MockTransport()
    let vendor = TransportVendor([transport1, transport2])
    let factory = MockXMPPClientFactory(
        transportForAccount: { _ in vendor.next() },
        modulesForAccount: { _ in [VCardModule(), PEPModule(), PresenceModule()] }
    )
    let accountService = makeAccountService(store: store, clientFactory: factory)

    let rosterService = RosterService(store: store)
    rosterService.setAccountService(accountService)
    let presenceService = PresenceService()
    presenceService.setAccountService(accountService)

    let service = AvatarService(store: store)
    service.setAccountService(accountService)
    service.setRosterService(rosterService)
    service.setPresenceService(presenceService)

    let connectTask = Task { @MainActor in
        try await accountService.createAndConnect(
            jidString: testJIDString, password: "secret", host: "example.com", port: 5222
        )
    }
    await simulateNoTLSConnect(transport1)
    let accountID = try await connectTask.value
    let client1 = try #require(accountService.connectedClient(for: accountID))

    return PresenceModuleFixture(
        service: service, accountService: accountService,
        transport1: transport1, transport2: transport2,
        accountID: accountID, client1: client1,
        rosterService: rosterService, presenceService: presenceService
    )
}

/// Waits for the first sent stanza matching `predicate` and acks it with an empty result IQ.
@MainActor
private func ackMatchedSet(_ transport: MockTransport, where predicate: @escaping @Sendable (String) -> Bool) async throws {
    let stanza = try #require(await transport.waitForSent(matching: predicate))
    let id = try #require(extractIQID(from: stanza))
    await transport.simulateReceive("<iq type='result' id='\(id)'/>")
}

/// Drives a second connect of the same account onto `transport2` and waits until the account's connected client
/// is no longer `previousClient` (the reconnect has swapped it). Returns the new client.
@MainActor
private func reconnectOnto(
    _ accountService: AccountService, accountID: UUID, transport2: MockTransport, previousClient: XMPPClient
) async throws -> XMPPClient {
    let reconnectTask = Task { @MainActor in
        try await accountService.connect(accountID: accountID, password: "secret")
    }
    await simulateNoTLSConnect(transport2)
    try await reconnectTask.value
    for _ in 0 ..< 100 {
        if let current = accountService.connectedClient(for: accountID), current !== previousClient { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let current = try #require(accountService.connectedClient(for: accountID))
    #expect(current !== previousClient)
    return current
}

private func isVCardSet(_ stanza: String) -> Bool {
    stanza.contains("vcard-temp") && stanza.contains("type=\"set\"")
}

private func isOwnVCardGet(_ stanza: String) -> Bool {
    stanza.contains("vcard-temp") && stanza.contains("type=\"get\"")
}

// MARK: - Tests

enum AvatarServiceTests {
    struct OwnAvatarReload {
        @Test(arguments: [false, true])
        @MainActor
        func `signing in or resuming loads the own avatar hash and advertises it in presence`(resumed: Bool) async throws {
            let fixture = try await connectWithPresenceModule()
            let fullJID = try #require(FullJID.parse("\(testJIDString)/ducko"))
            let event: XMPPEvent = resumed ? .streamResumed(fullJID) : .connected(fullJID)

            let task = Task { @MainActor in
                await fixture.service.handleEvent(event, accountID: fixture.accountID)
            }
            let getStanza = try await sentStanza(on: fixture.transport1, matching: isOwnVCardGet)
            let getID = try #require(extractIQID(from: getStanza))
            await fixture.transport1.simulateReceive(
                "<iq type='result' id='\(getID)'>\(vcardBody(binval: AvatarPayloads.validPNGBase64))</iq>"
            )
            await task.value

            let hash = try #require(fixture.service.ownAvatarHash(for: fixture.accountID))
            let sent = await fixture.transport1.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(sent.contains { $0.contains("<presence") && $0.contains("<photo>\(hash)</photo>") })

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }
    }

    struct VCardHashIngestion {
        @Test
        @MainActor
        func `an under-cap vCard photo is stored with its hash`() async throws {
            let connected = try await connectAvatarService()
            let hash = "vcard-under-cap-hash"

            let task = Task { @MainActor in
                await connected.service.handleEvent(
                    .vcardAvatarHashReceived(from: connected.peerJID, hash: hash), accountID: connected.accountID
                )
            }
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: vcardBody(binval: AvatarPayloads.validPNGBase64)
            )
            await task.value

            let contact = try await fetchPeerContact(connected)
            #expect(contact.avatarData != nil)
            #expect(contact.avatarHash == hash)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }

        @Test
        @MainActor
        func `an over-cap vCard photo is dropped but its hash is recorded`() async throws {
            let connected = try await connectAvatarService()
            let hash = "vcard-over-cap-hash"

            let task = Task { @MainActor in
                await connected.service.handleEvent(
                    .vcardAvatarHashReceived(from: connected.peerJID, hash: hash), accountID: connected.accountID
                )
            }
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: vcardBody(binval: AvatarPayloads.innerOverCapBase64)
            )
            await task.value

            let contact = try await fetchPeerContact(connected)
            #expect(contact.avatarData == nil)
            #expect(contact.avatarHash == hash)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }

        @Test
        @MainActor
        func `re-delivering a matching vCard hash skips the re-fetch`() async throws {
            let connected = try await connectAvatarService()
            let hash = "vcard-stable-hash"

            let task = Task { @MainActor in
                await connected.service.handleEvent(
                    .vcardAvatarHashReceived(from: connected.peerJID, hash: hash), accountID: connected.accountID
                )
            }
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: vcardBody(binval: AvatarPayloads.validPNGBase64)
            )
            await task.value
            let contact = try await fetchPeerContact(connected)
            #expect(contact.avatarHash == hash)

            await connected.service.handleEvent(
                .vcardAvatarHashReceived(from: connected.peerJID, hash: hash), accountID: connected.accountID
            )
            // No second fetch: still just 4 handshake + 1 vCard get.
            let sentCount = await connected.transport.sentBytes.count
            #expect(sentCount == 5)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }

        @Test
        @MainActor
        func `re-delivering an over-cap vCard hash skips the re-fetch`() async throws {
            let connected = try await connectAvatarService()
            let hash = "vcard-over-cap-stable-hash"

            let task = Task { @MainActor in
                await connected.service.handleEvent(
                    .vcardAvatarHashReceived(from: connected.peerJID, hash: hash), accountID: connected.accountID
                )
            }
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: vcardBody(binval: AvatarPayloads.innerOverCapBase64)
            )
            await task.value
            // The oversized photo was dropped (data nil) but its hash recorded — the reason the drop path stores
            // the hash at all is so the next notification carrying it is suppressed rather than re-fetched.
            let contact = try await fetchPeerContact(connected)
            #expect(contact.avatarData == nil)
            #expect(contact.avatarHash == hash)

            await connected.service.handleEvent(
                .vcardAvatarHashReceived(from: connected.peerJID, hash: hash), accountID: connected.accountID
            )
            let sentCount = await connected.transport.sentBytes.count
            #expect(sentCount == 5)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }
    }

    struct PEPMetadataIngestion {
        @Test
        @MainActor
        func `an under-cap PEP avatar is stored with the metadata hash`() async throws {
            let connected = try await connectAvatarService()
            let hash = "pep-under-cap-hash"

            let task = Task { @MainActor in
                await connected.service.handleEvent(
                    .pepItemsPublished(
                        from: connected.peerJID, node: XMPPNamespaces.avatarMetadata,
                        items: [avatarMetadataItem(id: hash)]
                    ),
                    accountID: connected.accountID
                )
            }
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: pepItemsBody(
                    node: XMPPNamespaces.avatarData, itemID: hash,
                    payload: avatarDataElement(AvatarPayloads.validPNGBase64)
                )
            )
            await task.value

            let contact = try await fetchPeerContact(connected)
            #expect(contact.avatarData != nil)
            #expect(contact.avatarHash == hash)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }

        @Test
        @MainActor
        func `a PEP avatar over the outer base64-length pre-check is dropped`() async throws {
            let connected = try await connectAvatarService()
            let hash = "pep-outer-over-cap-hash"

            let task = Task { @MainActor in
                await connected.service.handleEvent(
                    .pepItemsPublished(
                        from: connected.peerJID, node: XMPPNamespaces.avatarMetadata,
                        items: [avatarMetadataItem(id: hash)]
                    ),
                    accountID: connected.accountID
                )
            }
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: pepItemsBody(
                    node: XMPPNamespaces.avatarData, itemID: hash,
                    payload: avatarDataElement(AvatarPayloads.outerOverCapBase64)
                )
            )
            await task.value

            let contact = try await fetchPeerContact(connected)
            #expect(contact.avatarData == nil)
            #expect(contact.avatarHash == hash)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }

        @Test
        @MainActor
        func `a PEP avatar over the inner decoded-count guard is dropped`() async throws {
            let connected = try await connectAvatarService()
            let hash = "pep-inner-over-cap-hash"

            let task = Task { @MainActor in
                await connected.service.handleEvent(
                    .pepItemsPublished(
                        from: connected.peerJID, node: XMPPNamespaces.avatarMetadata,
                        items: [avatarMetadataItem(id: hash)]
                    ),
                    accountID: connected.accountID
                )
            }
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: pepItemsBody(
                    node: XMPPNamespaces.avatarData, itemID: hash,
                    payload: avatarDataElement(AvatarPayloads.innerOverCapBase64)
                )
            )
            await task.value

            let contact = try await fetchPeerContact(connected)
            #expect(contact.avatarData == nil)
            #expect(contact.avatarHash == hash)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }

        @Test
        @MainActor
        func `re-delivering a matching PEP metadata hash skips the re-fetch`() async throws {
            let connected = try await connectAvatarService()
            let hash = "pep-stable-hash"

            let task = Task { @MainActor in
                await connected.service.handleEvent(
                    .pepItemsPublished(
                        from: connected.peerJID, node: XMPPNamespaces.avatarMetadata,
                        items: [avatarMetadataItem(id: hash)]
                    ),
                    accountID: connected.accountID
                )
            }
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: pepItemsBody(
                    node: XMPPNamespaces.avatarData, itemID: hash,
                    payload: avatarDataElement(AvatarPayloads.validPNGBase64)
                )
            )
            await task.value
            let contact = try await fetchPeerContact(connected)
            #expect(contact.avatarHash == hash)

            await connected.service.handleEvent(
                .pepItemsPublished(
                    from: connected.peerJID, node: XMPPNamespaces.avatarMetadata,
                    items: [avatarMetadataItem(id: hash)]
                ),
                accountID: connected.accountID
            )
            // No second fetch: still just 4 handshake + 1 data get.
            let sentCount = await connected.transport.sentBytes.count
            #expect(sentCount == 5)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }

        @Test(arguments: [nil, ""] as [String?])
        @MainActor
        func `malformed PEP metadata is ignored without disturbing an existing avatar`(malformedID: String?) async throws {
            // A missing (`nil`) and an empty (`""`) <info> id are the two malformed cases XEP-0084's required id
            // rules out; both must be ignored, not treated as an avatar-removal clear.
            let connected = try await connectAvatarService()
            let seededHash = "pep-seeded-hash"

            // Seed a valid avatar first so the malformed delivery can be shown to preserve it rather than clear it.
            let seedTask = Task { @MainActor in
                await connected.service.handleEvent(
                    .pepItemsPublished(
                        from: connected.peerJID, node: XMPPNamespaces.avatarMetadata,
                        items: [avatarMetadataItem(id: seededHash)]
                    ),
                    accountID: connected.accountID
                )
            }
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: pepItemsBody(
                    node: XMPPNamespaces.avatarData, itemID: seededHash,
                    payload: avatarDataElement(AvatarPayloads.validPNGBase64)
                )
            )
            await seedTask.value
            #expect(try await fetchPeerContact(connected).avatarHash == seededHash)

            await connected.service.handleEvent(
                .pepItemsPublished(
                    from: connected.peerJID, node: XMPPNamespaces.avatarMetadata,
                    items: [avatarMetadataItem(id: malformedID)]
                ),
                accountID: connected.accountID
            )
            // Malformed metadata is ignored: no data get goes out (still 4 handshake + 1 seed fetch) and the
            // seeded avatar survives untouched.
            let sentCount = await connected.transport.sentBytes.count
            #expect(sentCount == 5)
            let contact = try await fetchPeerContact(connected)
            #expect(contact.avatarData != nil)
            #expect(contact.avatarHash == seededHash)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }

        @Test
        @MainActor
        func `re-delivering an over-cap PEP metadata hash skips the re-fetch`() async throws {
            let connected = try await connectAvatarService()
            let hash = "pep-over-cap-stable-hash"

            let task = Task { @MainActor in
                await connected.service.handleEvent(
                    .pepItemsPublished(
                        from: connected.peerJID, node: XMPPNamespaces.avatarMetadata,
                        items: [avatarMetadataItem(id: hash)]
                    ),
                    accountID: connected.accountID
                )
            }
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: pepItemsBody(
                    node: XMPPNamespaces.avatarData, itemID: hash,
                    payload: avatarDataElement(AvatarPayloads.innerOverCapBase64)
                )
            )
            await task.value
            // The oversized payload was dropped (data nil) but its hash recorded, so the next notification carrying
            // the same hash is suppressed before any data get.
            let contact = try await fetchPeerContact(connected)
            #expect(contact.avatarData == nil)
            #expect(contact.avatarHash == hash)

            await connected.service.handleEvent(
                .pepItemsPublished(
                    from: connected.peerJID, node: XMPPNamespaces.avatarMetadata,
                    items: [avatarMetadataItem(id: hash)]
                ),
                accountID: connected.accountID
            )
            let sentCount = await connected.transport.sentBytes.count
            #expect(sentCount == 5)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }

        @Test
        @MainActor
        func `an over-cap update clears a previously stored PEP avatar`() async throws {
            let connected = try await connectAvatarService()

            let seedTask = Task { @MainActor in
                await connected.service.handleEvent(
                    .pepItemsPublished(
                        from: connected.peerJID, node: XMPPNamespaces.avatarMetadata,
                        items: [avatarMetadataItem(id: "pep-seed-hash")]
                    ),
                    accountID: connected.accountID
                )
            }
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: pepItemsBody(
                    node: XMPPNamespaces.avatarData, itemID: "pep-seed-hash",
                    payload: avatarDataElement(AvatarPayloads.validPNGBase64)
                )
            )
            await seedTask.value
            #expect(try await fetchPeerContact(connected).avatarData != nil)

            let dropTask = Task { @MainActor in
                await connected.service.handleEvent(
                    .pepItemsPublished(
                        from: connected.peerJID, node: XMPPNamespaces.avatarMetadata,
                        items: [avatarMetadataItem(id: "pep-over-cap-hash")]
                    ),
                    accountID: connected.accountID
                )
            }
            try await answerGet(
                connected.transport, sentIndex: 5, from: "peer@example.com",
                body: pepItemsBody(
                    node: XMPPNamespaces.avatarData, itemID: "pep-over-cap-hash",
                    payload: avatarDataElement(AvatarPayloads.innerOverCapBase64)
                )
            )
            await dropTask.value

            // The oversized update dropped the new bytes and recorded its hash, clearing the previously stored image
            // so a stale avatar isn't pinned behind the suppressing hash.
            let contact = try await fetchPeerContact(connected)
            #expect(contact.avatarData == nil)
            #expect(contact.avatarHash == "pep-over-cap-hash")

            await connected.accountService.disconnect(accountID: connected.accountID)
        }
    }

    struct FetchAvatar {
        @Test
        @MainActor
        func `fetchAvatar returns an under-cap PEP avatar without falling back to vCard`() async throws {
            let connected = try await connectAvatarService()

            let task = Task { @MainActor in
                await connected.service.fetchAvatar(for: connected.peerJID, accountID: connected.accountID)
            }
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: pepItemsBody(
                    node: XMPPNamespaces.avatarMetadata, itemID: "current",
                    payload: avatarMetadataElement(id: "fetch-pep-hash")
                )
            )
            try await answerGet(
                connected.transport, sentIndex: 5, from: "peer@example.com",
                body: pepItemsBody(
                    node: XMPPNamespaces.avatarData, itemID: "current",
                    payload: avatarDataElement(AvatarPayloads.validPNGBase64)
                )
            )
            let result = await task.value

            #expect(result != nil)
            #expect(result?.hash == "fetch-pep-hash")
            // The PEP avatar resolved, so no vCard fallback get was sent (4 handshake + 2 PEP gets).
            let sentCount = await connected.transport.sentBytes.count
            #expect(sentCount == 6)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }

        @Test
        @MainActor
        func `fetchAvatar drops an outer-over-cap PEP avatar and falls back to a photo-less vCard`() async throws {
            let connected = try await connectAvatarService()

            let task = Task { @MainActor in
                await connected.service.fetchAvatar(for: connected.peerJID, accountID: connected.accountID)
            }
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: pepItemsBody(
                    node: XMPPNamespaces.avatarMetadata, itemID: "current",
                    payload: avatarMetadataElement(id: "fetch-pep-outer-hash")
                )
            )
            try await answerGet(
                connected.transport, sentIndex: 5, from: "peer@example.com",
                body: pepItemsBody(
                    node: XMPPNamespaces.avatarData, itemID: "current",
                    payload: avatarDataElement(AvatarPayloads.outerOverCapBase64)
                )
            )
            // PEP yielded nil → fetchAvatar falls through to the vCard get; answer it photo-less so it too is nil.
            try await answerGet(
                connected.transport, sentIndex: 6, from: "peer@example.com", body: vcardBody(binval: nil)
            )
            let result = await task.value

            #expect(result == nil)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }

        @Test
        @MainActor
        func `fetchAvatar drops an inner-over-cap PEP avatar and falls back to a photo-less vCard`() async throws {
            let connected = try await connectAvatarService()

            let task = Task { @MainActor in
                await connected.service.fetchAvatar(for: connected.peerJID, accountID: connected.accountID)
            }
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: pepItemsBody(
                    node: XMPPNamespaces.avatarMetadata, itemID: "current",
                    payload: avatarMetadataElement(id: "fetch-pep-inner-hash")
                )
            )
            try await answerGet(
                connected.transport, sentIndex: 5, from: "peer@example.com",
                body: pepItemsBody(
                    node: XMPPNamespaces.avatarData, itemID: "current",
                    payload: avatarDataElement(AvatarPayloads.innerOverCapBase64)
                )
            )
            try await answerGet(
                connected.transport, sentIndex: 6, from: "peer@example.com", body: vcardBody(binval: nil)
            )
            let result = await task.value

            #expect(result == nil)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }

        @Test
        @MainActor
        func `fetchAvatar returns an under-cap vCard avatar when PEP has none`() async throws {
            let connected = try await connectAvatarService()

            let task = Task { @MainActor in
                await connected.service.fetchAvatar(for: connected.peerJID, accountID: connected.accountID)
            }
            // PEP metadata get returns no item → fetchPEPAvatar nil → vCard fallback runs.
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: pepItemsBody(node: XMPPNamespaces.avatarMetadata)
            )
            try await answerGet(
                connected.transport, sentIndex: 5, from: "peer@example.com",
                body: vcardBody(binval: AvatarPayloads.validPNGBase64)
            )
            let result = await task.value

            #expect(result != nil)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }

        @Test
        @MainActor
        func `fetchAvatar drops an over-cap vCard avatar when PEP has none`() async throws {
            let connected = try await connectAvatarService()

            let task = Task { @MainActor in
                await connected.service.fetchAvatar(for: connected.peerJID, accountID: connected.accountID)
            }
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: pepItemsBody(node: XMPPNamespaces.avatarMetadata)
            )
            try await answerGet(
                connected.transport, sentIndex: 5, from: "peer@example.com",
                body: vcardBody(binval: AvatarPayloads.innerOverCapBase64)
            )
            let result = await task.value

            #expect(result == nil)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }

        @Test
        @MainActor
        func `fetchAvatar falls back to vCard when PEP metadata has an empty id`() async throws {
            let connected = try await connectAvatarService()

            let task = Task { @MainActor in
                await connected.service.fetchAvatar(for: connected.peerJID, accountID: connected.accountID)
            }
            // PEP metadata carries an empty <info> id → fetchPEPAvatar rejects it as malformed → vCard fallback runs.
            try await answerGet(
                connected.transport, sentIndex: 4, from: "peer@example.com",
                body: pepItemsBody(
                    node: XMPPNamespaces.avatarMetadata, itemID: "current",
                    payload: avatarMetadataElement(id: "")
                )
            )
            try await answerGet(
                connected.transport, sentIndex: 5, from: "peer@example.com",
                body: vcardBody(binval: AvatarPayloads.validPNGBase64)
            )
            let result = await task.value

            #expect(result != nil)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }
    }

    /// A disconnect/client-swap while `fetchOwnVCard` is in flight must skip the follow-up `publishVCard` — the
    /// `connectedClient(for:) === client` guard in `updateVCardPhoto`/`clearVCardPhoto` protects against
    /// publishing a stale vCard onto a torn-down/replaced connection.
    struct PublishTeardownRace {
        private static let pngData = Data(base64Encoded: AvatarPayloads.validPNGBase64) ?? Data()

        @Test
        @MainActor
        func `publishAvatar skips the vCard publish when the client is swapped mid-fetch`() async throws {
            let fixture = try await connectWithPresenceModule()
            fixture.service.setOwnAvatarHashForTesting("preexisting-hash", accountID: fixture.accountID)

            let publishTask = Task { @MainActor in
                try await fixture.service.publishAvatar(
                    imageData: Self.pngData, mimeType: "image/png", accountID: fixture.accountID
                )
            }
            // Ack the two PEP publishes so the flow advances into updateVCardPhoto's fetchOwnVCard.
            try await ackMatchedSet(fixture.transport1) { $0.contains("publish") && $0.contains(XMPPNamespaces.avatarData) }
            try await ackMatchedSet(fixture.transport1) { $0.contains("publish") && $0.contains(XMPPNamespaces.avatarMetadata) }

            // Capture the in-flight own-vCard get but hold its answer until after the client is swapped.
            let getStanza = try #require(await fixture.transport1.waitForSent(matching: isOwnVCardGet))
            let getID = try #require(extractIQID(from: getStanza))

            _ = try await reconnectOnto(
                fixture.accountService, accountID: fixture.accountID,
                transport2: fixture.transport2, previousClient: fixture.client1
            )

            // Now answer the stale fetch: the captured client is no longer current, so the guard fires.
            await fixture.transport1.simulateReceive("<iq type='result' id='\(getID)'><vCard xmlns='vcard-temp'/></iq>")
            try await publishTask.value

            let sent1 = await fixture.transport1.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(!sent1.contains(where: isVCardSet))
            // The later public guard in publishAvatar leaves the swapped-away account's own-avatar hash alone.
            #expect(fixture.service.ownAvatarHash(for: fixture.accountID) == "preexisting-hash")

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }

        @Test
        @MainActor
        func `removeAvatar skips the vCard clear when the client is swapped mid-fetch`() async throws {
            let fixture = try await connectWithPresenceModule()
            fixture.service.setOwnAvatarHashForTesting("preexisting-hash", accountID: fixture.accountID)

            let removeTask = Task { @MainActor in
                try await fixture.service.removeAvatar(accountID: fixture.accountID)
            }
            // removeAvatar publishes a single empty metadata item before reaching clearVCardPhoto's fetchOwnVCard.
            try await ackMatchedSet(fixture.transport1) { $0.contains("publish") && $0.contains(XMPPNamespaces.avatarMetadata) }

            let getStanza = try #require(await fixture.transport1.waitForSent(matching: isOwnVCardGet))
            let getID = try #require(extractIQID(from: getStanza))

            _ = try await reconnectOnto(
                fixture.accountService, accountID: fixture.accountID,
                transport2: fixture.transport2, previousClient: fixture.client1
            )

            await fixture.transport1.simulateReceive("<iq type='result' id='\(getID)'><vCard xmlns='vcard-temp'/></iq>")
            try await removeTask.value

            let sent1 = await fixture.transport1.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(!sent1.contains(where: isVCardSet))
            // The later public guard in removeAvatar leaves the swapped-away account's own-avatar hash in place.
            #expect(fixture.service.ownAvatarHash(for: fixture.accountID) == "preexisting-hash")

            await fixture.accountService.disconnect(accountID: fixture.accountID)
        }
    }
}

extension AvatarServiceTests {
    @Test(arguments: [false, true])
    @MainActor
    static func `delayed avatar response cannot restore a removed contact identity`(readd: Bool) async throws {
        let connected = try await connectAvatarService()
        let original = try await fetchPeerContact(connected)
        let task = Task {
            await connected.service.handleEvent(.vcardAvatarHashReceived(from: connected.peerJID, hash: "delayed-hash"), accountID: connected.accountID)
        }
        let requested = try await boundedOutcome {
            _ = await connected.transport.waitForSent(matching: { $0.contains("vcard-temp") })
        }
        try #require(requested != nil)
        try await connected.store.deleteContact(original.id)
        if readd {
            var replacement = Contact(id: UUID(), accountID: connected.accountID, jid: connected.peerJID, name: "Replacement", subscription: .none, groups: [], isBlocked: false, createdAt: Date())
            replacement.avatarHash = "replacement-hash"
            try await connected.store.upsertContact(replacement)
        }
        try await answerGet(connected.transport, sentIndex: 4, from: "peer@example.com", body: vcardBody(binval: AvatarPayloads.validPNGBase64))
        await task.value
        let contacts = try await connected.store.fetchContacts(for: connected.accountID)
        #expect(contacts.count == (readd ? 1 : 0))
        #expect(!contacts.contains { $0.id == original.id })
        #expect(contacts.first?.avatarHash == (readd ? "replacement-hash" : nil))
        #expect(contacts.first?.avatarData == nil)
        await connected.accountService.disconnect(accountID: connected.accountID)
    }
}
