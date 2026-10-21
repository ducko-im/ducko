import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

@MainActor
private func makeProfileService(accountService: AccountService) -> ProfileService {
    let service = ProfileService()
    service.setAccountService(accountService)
    return service
}

@MainActor
private struct ConnectedProfileService {
    let service: ProfileService
    let accountService: AccountService
    let transport: MockTransport
    let accountID: UUID
}

/// Connects a `ProfileService` against a mock transport with a real `VCardModule`. The connect handshake
/// sends 4 stanzas, so the first publish-driven IQ lands at sent index 4.
@MainActor
private func connectProfileService() async throws -> ConnectedProfileService {
    let store = makeStore()
    let transport = MockTransport()
    let factory = MockXMPPClientFactory(transport: transport, modules: [VCardModule()])
    let accountService = makeAccountService(store: store, clientFactory: factory)
    let service = makeProfileService(accountService: accountService)

    let connectTask = Task { @MainActor in
        try await accountService.createAndConnect(
            jidString: testJIDString, password: "secret", host: "example.com", port: 5222
        )
    }
    await simulateNoTLSConnect(transport)
    let accountID = try await connectTask.value
    return ConnectedProfileService(service: service, accountService: accountService, transport: transport, accountID: accountID)
}

/// Answers the vCard `get` at `sentIndex` with a server vCard so the publish path has a raw element to merge.
@MainActor
private func respondToVCardFetch(_ transport: MockTransport, sentIndex: Int, serverVCard: String) async throws {
    await transport.waitForSent(count: sentIndex + 1)
    let sent = await transport.sentBytes
    let getIQ = String(decoding: sent[sentIndex], as: UTF8.self)
    let id = try #require(extractIQID(from: getIQ))
    await transport.simulateReceive("<iq type='result' id='\(id)'>\(serverVCard)</iq>")
}

/// Answers the vCard `get` at `sentIndex` with a stanza error carrying `condition`.
@MainActor
private func respondToVCardFetchWithError(_ transport: MockTransport, sentIndex: Int, condition: String) async throws {
    await transport.waitForSent(count: sentIndex + 1)
    let sent = await transport.sentBytes
    let getIQ = String(decoding: sent[sentIndex], as: UTF8.self)
    let id = try #require(extractIQID(from: getIQ))
    await transport.simulateReceive(
        "<iq type='error' id='\(id)'><error type='cancel'>"
            + "<\(condition) xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
    )
}

/// Captures the outgoing vCard `set` at `sentIndex`, acks it, and returns its raw XML.
@MainActor
private func captureAndAckPublish(_ transport: MockTransport, sentIndex: Int) async throws -> String {
    await transport.waitForSent(count: sentIndex + 1)
    let sent = await transport.sentBytes
    let setIQ = String(decoding: sent[sentIndex], as: UTF8.self)
    let id = try #require(extractIQID(from: setIQ))
    await transport.simulateReceive("<iq type='result' id='\(id)'/>")
    return setIQ
}

// MARK: - Tests

enum ProfileServiceTests {
    struct AccountIsolation {
        @Test
        @MainActor
        func `ownProfile is keyed per account and never leaks across accounts`() async throws {
            let connected = try await connectProfileService()
            let profileService = connected.service
            let transport = connected.transport
            let accountID = connected.accountID

            let publishTask = Task { @MainActor in
                try await profileService.publishProfile(ProfileInfo(fullName: "Alice"), accountID: accountID)
            }
            try await respondToVCardFetch(
                transport, sentIndex: 4, serverVCard: "<vCard xmlns='vcard-temp'><FN>Alice</FN></vCard>"
            )
            _ = try await captureAndAckPublish(transport, sentIndex: 5)
            try await publishTask.value

            // The published profile is retrievable for its own account…
            #expect(profileService.ownProfile(for: accountID)?.fullName == "Alice")
            // …and a different account ID never surfaces it.
            #expect(profileService.ownProfile(for: UUID()) == nil)

            await connected.accountService.disconnect(accountID: accountID)
        }
    }

    struct PeerProfileFetch {
        private static let peerJID = "peer@example.com"

        /// Answers the peer vCard `get` at `sentIndex`. The result must carry `from` set to
        /// the peer JID — unlike the own-vCard path (`to`-less), a peer-addressed IQ result
        /// is only matched to its request when the `from` matches the original `to`.
        @MainActor
        private static func respondToPeerFetch(_ transport: MockTransport, sentIndex: Int, body: String) async throws {
            await transport.waitForSent(count: sentIndex + 1)
            let sent = await transport.sentBytes
            let getIQ = String(decoding: sent[sentIndex], as: UTF8.self)
            let id = try #require(extractIQID(from: getIQ))
            await transport.simulateReceive("<iq type='result' from='\(peerJID)' id='\(id)'>\(body)</iq>")
        }

        @Test
        @MainActor
        func `fetchProfile maps a peer vCard into ProfileInfo`() async throws {
            let connected = try await connectProfileService()
            let profileService = connected.service
            let accountID = connected.accountID

            let fetchTask = Task { @MainActor in
                try await profileService.fetchProfile(for: Self.peerJID, accountID: accountID)
            }

            // The connect handshake sends 4 stanzas; the peer vCard get is the first IQ after.
            try await Self.respondToPeerFetch(
                connected.transport, sentIndex: 4,
                body: "<vCard xmlns='vcard-temp'><FN>Peer Person</FN>"
                    + "<EMAIL><USERID>peer@example.com</USERID></EMAIL>"
                    + "<ORG><ORGNAME>Acme</ORGNAME></ORG></vCard>"
            )

            let profile = try await fetchTask.value
            #expect(profile.fullName == "Peer Person")
            #expect(profile.emails.first?.address == "peer@example.com")
            #expect(profile.organization == "Acme")

            await connected.accountService.disconnect(accountID: accountID)
        }

        @Test
        @MainActor
        func `fetchProfile returns an empty profile when the peer has no vCard`() async throws {
            let connected = try await connectProfileService()
            let profileService = connected.service
            let transport = connected.transport
            let accountID = connected.accountID

            let fetchTask = Task { @MainActor in
                try await profileService.fetchProfile(for: Self.peerJID, accountID: accountID)
            }

            // item-not-found is the common "never published a vCard" case — fetchProfile
            // swallows it and returns an empty profile rather than throwing.
            await transport.waitForSent(count: 5)
            let sent = await transport.sentBytes
            let id = try #require(extractIQID(from: String(decoding: sent[4], as: UTF8.self)))
            await transport.simulateReceive(
                "<iq type='error' from='\(Self.peerJID)' id='\(id)'><error type='cancel'>"
                    + "<item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
            )

            let profile = try await fetchTask.value
            #expect(profile.fullName == nil)
            #expect(profile.emails.isEmpty)

            await connected.accountService.disconnect(accountID: accountID)
        }
    }

    struct PublishPreservesRawXML {
        @Test
        @MainActor
        func `publishProfile preserves unmodeled vCard XML across successive publishes`() async throws {
            let connected = try await connectProfileService()
            let profileService = connected.service
            let transport = connected.transport
            let accountID = connected.accountID

            // Model a server that stores vCard XML losslessly: every fetch returns a vCard carrying an
            // unmodeled X-DUCKO-TEST element that ProfileInfo can't represent.
            let serverVCard = "<vCard xmlns='vcard-temp'><FN>Alice</FN><X-DUCKO-TEST>keep-me</X-DUCKO-TEST></vCard>"

            let publishTask = Task { @MainActor in
                try await profileService.publishProfile(ProfileInfo(fullName: "Alice One"), accountID: accountID)
                try await profileService.publishProfile(ProfileInfo(fullName: "Alice Two"), accountID: accountID)
            }

            // Each publishProfile sends a vCard get (re-fetch) followed by a vCard set (publish).
            try await respondToVCardFetch(transport, sentIndex: 4, serverVCard: serverVCard)
            let firstPublish = try await captureAndAckPublish(transport, sentIndex: 5)
            try await respondToVCardFetch(transport, sentIndex: 6, serverVCard: serverVCard)
            let secondPublish = try await captureAndAckPublish(transport, sentIndex: 7)

            try await publishTask.value

            // Both outgoing publishes carry the server's unmodeled element, including the second — the
            // per-publish re-fetch is what keeps it from being dropped across successive publishes.
            #expect(firstPublish.contains("X-DUCKO-TEST"))
            #expect(firstPublish.contains("keep-me"))
            #expect(secondPublish.contains("X-DUCKO-TEST"))
            #expect(secondPublish.contains("keep-me"))

            await connected.accountService.disconnect(accountID: accountID)
        }

        @Test
        @MainActor
        func `publishProfile keeps the vCard's current photo rather than the one the profile was loaded with`() async throws {
            let connected = try await connectProfileService()
            let current = Data("photo from another device".utf8)
            let loaded = Data("photo the window loaded".utf8)
            let serverVCard = "<vCard xmlns='vcard-temp'><PHOTO><TYPE>image/png</TYPE><BINVAL>\(current.base64EncodedString())</BINVAL></PHOTO></vCard>"

            let publishTask = Task { @MainActor in
                try await connected.service.publishProfile(
                    ProfileInfo(fullName: "Alice", photoData: loaded, photoType: "image/jpeg"), accountID: connected.accountID
                )
            }
            try await respondToVCardFetch(connected.transport, sentIndex: 4, serverVCard: serverVCard)
            let publish = try await captureAndAckPublish(connected.transport, sentIndex: 5)
            try await publishTask.value

            #expect(publish.contains("<BINVAL>\(current.base64EncodedString())</BINVAL>"))
            #expect(publish.contains("<TYPE>image/png</TYPE>"))
            #expect(!publish.contains(loaded.base64EncodedString()))
            #expect(connected.service.ownProfile(for: connected.accountID)?.photoData == current)

            await connected.accountService.disconnect(accountID: connected.accountID)
        }
    }

    struct PublishFetchErrorHandling {
        @Test
        @MainActor
        func `publishProfile proceeds when the pre-publish fetch returns item-not-found`() async throws {
            let connected = try await connectProfileService()
            let profileService = connected.service
            let transport = connected.transport
            let accountID = connected.accountID

            let publishTask = Task { @MainActor in
                try await profileService.publishProfile(ProfileInfo(fullName: "Fresh Account"), accountID: accountID)
            }

            // Fresh account with no published vCard — the re-fetch fails with item-not-found, which is
            // swallowed so the publish still proceeds (with no raw element to preserve).
            try await respondToVCardFetchWithError(transport, sentIndex: 4, condition: "item-not-found")
            let publishIQ = try await captureAndAckPublish(transport, sentIndex: 5)

            try await publishTask.value
            #expect(publishIQ.contains("vcard-temp"))
            #expect(publishIQ.contains("Fresh Account"))

            await connected.accountService.disconnect(accountID: accountID)
        }

        @Test
        @MainActor
        func `publishProfile fails the publish when the pre-publish fetch errors with another condition`() async throws {
            let connected = try await connectProfileService()
            let profileService = connected.service
            let transport = connected.transport
            let accountID = connected.accountID

            let publishTask = Task { @MainActor in
                try await profileService.publishProfile(ProfileInfo(fullName: "Nope"), accountID: accountID)
            }

            // A non-item-not-found fetch error must abort the publish rather than silently drop unmodeled XML.
            try await respondToVCardFetchWithError(transport, sentIndex: 4, condition: "service-unavailable")
            await #expect(throws: (any Error).self) {
                try await publishTask.value
            }

            // The publish was aborted — only the failed fetch get was sent, no vCard set.
            let sent = await transport.sentBytes
            #expect(sent.count == 5)

            await connected.accountService.disconnect(accountID: accountID)
        }
    }
}
