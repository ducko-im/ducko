import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct AuthenticationTests {
        @Test @MainActor func `Alice connects via SASL and binds a resource`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                let client = try #require(harness.environment.accountService.client(for: alice.accountID))

                // setUp awaits initial roster response, which proves SASL + resource bind succeeded.
                // Additionally verify TLS was negotiated.
                #expect(client.tlsInfo != nil)

                guard case .connected = harness.environment.accountService.connectionStates[alice.accountID] else {
                    Issue.record("Expected .connected state")
                    return
                }
            }
        }

        @Test @MainActor func `Authentication fails with wrong password`() async throws {
            try await TestHarness.withHarness { harness in
                let accountID = try await harness.environment.accountService.createAccount(
                    jidString: TestCredentials.alice.jid
                )
                try await harness.environment.accountService.loadAccounts()

                // Register cleanup before the failing connect so a hang still triggers teardown.
                harness.addCleanup {
                    await harness.environment.accountService.disconnect(accountID: accountID)
                    try? await harness.environment.accountService.deleteAccount(accountID)
                }

                await #expect(throws: (any Error).self) {
                    try await harness.environment.accountService.connect(
                        accountID: accountID,
                        password: "wrong-password"
                    )
                }

                guard case .error = harness.environment.accountService.connectionStates[accountID] else {
                    Issue.record("Expected .error state after wrong password")
                    return
                }
            }
        }

        @Test @MainActor func `TLS fingerprint is captured on connect`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                let client = try #require(harness.environment.accountService.client(for: alice.accountID))

                #expect(client.tlsInfo?.certificateSHA256 != nil)
            }
        }

        @Test @MainActor func `Sign-in is bound to the TLS channel`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                let client = try #require(harness.environment.accountService.client(for: alice.accountID))

                #expect(client.verifiedSCRAMMechanism?.hasSuffix("-PLUS") == true)
            }
        }

        @Test @MainActor func `Service discovery returns server info`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let aliceBareJID = try harness.jid(for: TestCredentials.alice)
                let serverJID = try #require(BareJID.parse(aliceBareJID.domainPart))

                let disco = try await harness.module(ServiceDiscoveryModule.self, for: "alice")
                let info = try await disco.queryInfo(for: .bare(serverJID))

                #expect(info.features.contains("http://jabber.org/protocol/disco#info"))
            }
        }

        @Test @MainActor func `Stream Management is enabled after connect`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                let sm = try await harness.module(StreamManagementModule.self, for: "alice")

                try await alice.waitForCondition(
                    { @MainActor in sm.isResumable },
                    timeout: TestTimeout.event
                )
            }
        }

        @Test @MainActor func `Alice disconnects cleanly via service`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                await harness.environment.accountService.disconnect(accountID: alice.accountID)
                try await harness.waitUntilDisconnected("alice")
            }
        }

        @Test @MainActor func `Multi-account connect brings both accounts online`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])

                guard case .connected = harness.environment.accountService.connectionStates[alice.accountID] else {
                    Issue.record("Expected alice .connected state")
                    return
                }

                guard case .connected = harness.environment.accountService.connectionStates[bob.accountID] else {
                    Issue.record("Expected bob .connected state")
                    return
                }
            }
        }
    }
}
