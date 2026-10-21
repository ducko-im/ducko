import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// Proves the PEP-reacting services suspend on `XMPPClient.awaitInitialPresenceSent()` before doing PEP work.
/// `BookmarksService` is the representative gate consumer — its `.connected` path issues a single bookmarks2
/// PEP retrieve — and the gate call is identical in `OMEMOService` and `AvatarService`. Without the gate, the
/// service would issue its retrieve immediately on `.connected` (before caps), which this test catches by
/// holding the caps-bearing presence off the wire.
enum PresenceReadinessGateTests {
    struct ServiceGating {
        @Test
        @MainActor
        func `BookmarksService waits for caps before issuing its PEP retrieve`() async throws {
            let store = MockPersistenceStore()
            let credentials = MockCredentialStore()
            let transport = MockTransport()
            let capsModule = CapsModule()
            let factory = MockXMPPClientFactory(
                transport: transport,
                modules: [PEPModule(), PresenceModule(capsModule: capsModule), capsModule]
            )
            let accountService = AccountService(store: store, credentialStore: credentials, clientFactory: factory)
            let bookmarksService = BookmarksService()
            bookmarksService.setAccountService(accountService)

            // Hold the caps-bearing presence off the wire, so the readiness gate never opens.
            await transport.blockSends { $0.contains(XMPPNamespaces.caps) }

            let accountID = try await accountService.createAccount(
                jidString: "alice@example.com", host: "example.com", port: 5222
            )
            let connectTask = Task { @MainActor in
                try await accountService.connect(accountID: accountID, password: "secret")
            }
            await simulateNoTLSConnect(transport)
            await transport.waitForBlockedSend()

            // AccountService records `.connected` from the event yielded before presence;
            // `connectedClient(for:)` (the same gate the service uses) returns non-nil only then.
            var connected = false
            for _ in 0 ..< 100 {
                if accountService.connectedClient(for: accountID) != nil { connected = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(connected)

            let boundJID = try #require(FullJID.parse("alice@example.com/ducko"))
            let driveTask = Task { @MainActor in
                await bookmarksService.handleEvent(.connected(boundJID), accountID: accountID)
            }

            // While caps is held the gated service must NOT issue its bookmarks2 retrieve.
            try await Task.sleep(for: .milliseconds(300))
            let sentWhileGated = await transport.sentBytes
            #expect(!sentWhileGated.contains { String(decoding: $0, as: UTF8.self).contains(XMPPNamespaces.bookmarks2) })

            // Releasing caps opens the gate; the service then issues its retrieve.
            await transport.releaseBlockedSends()
            var retrieved = false
            for _ in 0 ..< 150 {
                let sent = await transport.sentBytes
                if sent.contains(where: { String(decoding: $0, as: UTF8.self).contains(XMPPNamespaces.bookmarks2) }) {
                    retrieved = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(retrieved)

            driveTask.cancel()
            connectTask.cancel()
            await accountService.disconnect(accountID: accountID)
        }
    }
}
