import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private struct TestError: Error {}

private let testJID = BareJID(localPart: "alice", domainPart: "example.com")!

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

private func makeCredentials() -> MockCredentialStore {
    MockCredentialStore()
}

private func makeAccount(id: UUID = UUID(), jid: BareJID = testJID) -> Account {
    Account(id: id, jid: jid, isEnabled: true, connectOnLaunch: false, createdAt: Date())
}

private func makeConversation(accountID: UUID? = nil, jid: BareJID, importSourceJID: String? = nil) -> Conversation {
    Conversation(
        id: UUID(),
        accountID: accountID,
        importSourceJID: importSourceJID,
        jid: jid,
        type: .chat,
        isPinned: false,
        isMuted: false,
        unreadCount: 0,
        createdAt: Date()
    )
}

// MARK: - Tests

enum AccountServiceTests {
    struct CreateAccount {
        @Test
        @MainActor
        func `createAccount with valid JID persists account`() async throws {
            let store = makeStore()
            let service = makeAccountService(store: store)

            let accountID = try await service.createAccount(jidString: testJIDString)

            let accounts = try await store.fetchAccounts()
            #expect(accounts.count == 1)
            #expect(accounts[0].id == accountID)
            #expect(accounts[0].jid == testJID)
            #expect(accounts[0].isEnabled == true)
            #expect(accounts[0].requireTLS == true)
        }

        @Test
        @MainActor
        func `createAccount defaults connectOnLaunch to true`() async throws {
            let store = makeStore()
            let service = makeAccountService(store: store)

            _ = try await service.createAccount(jidString: testJIDString)

            let accounts = try await store.fetchAccounts()
            #expect(accounts[0].connectOnLaunch == true)
        }

        @Test
        @MainActor
        func `createAccount with invalid JID throws invalidJID`() async throws {
            let store = makeStore()
            let service = makeAccountService(store: store)

            await #expect(throws: AccountService.AccountServiceError.self) {
                _ = try await service.createAccount(jidString: "")
            }

            let accounts = try await store.fetchAccounts()
            #expect(accounts.isEmpty)
        }

        @Test
        @MainActor
        func `createAccount with duplicate JID throws duplicateJID`() async throws {
            let store = makeStore()
            let service = makeAccountService(store: store)

            _ = try await service.createAccount(jidString: testJIDString)

            // A case-variant collides: the guard compares parsed (case-folded)
            // BareJIDs, not the raw input strings.
            let error = await #expect(throws: AccountService.AccountServiceError.self) {
                _ = try await service.createAccount(jidString: "Alice@Example.COM")
            }
            let isDuplicate = if case .duplicateJID? = error { true } else { false }
            #expect(isDuplicate)

            let accounts = try await store.fetchAccounts()
            #expect(accounts.count == 1)
        }

        @Test
        @MainActor
        func `createAccount with a distinct JID succeeds alongside an existing account`() async throws {
            let store = makeStore()
            let service = makeAccountService(store: store)

            _ = try await service.createAccount(jidString: testJIDString)
            _ = try await service.createAccount(jidString: "bob@example.com")

            let accounts = try await store.fetchAccounts()
            #expect(accounts.count == 2)
        }

        @Test
        @MainActor
        func `createAccount auto-links imported conversations`() async throws {
            let store = makeStore()
            let contactJID = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
            let conv = makeConversation(jid: contactJID, importSourceJID: testJIDString)
            await store.addConversation(conv)

            let service = makeAccountService(store: store)
            let accountID = try await service.createAccount(jidString: testJIDString)

            let linked = try await store.fetchConversations(for: accountID)
            #expect(linked.count == 1)
            #expect(linked[0].accountID == accountID)
            #expect(linked[0].importSourceJID == nil)
        }

        @Test
        @MainActor
        func `createAccount with no matching imports links nothing`() async throws {
            let store = makeStore()
            let otherJID = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
            let conv = makeConversation(jid: otherJID, importSourceJID: "other@example.com")
            await store.addConversation(conv)

            let service = makeAccountService(store: store)
            let accountID = try await service.createAccount(jidString: testJIDString)

            let linked = try await store.fetchConversations(for: accountID)
            #expect(linked.isEmpty)

            // Verify the original conversation is unchanged
            let all = try await store.fetchAllConversations()
            #expect(all.count == 1)
            #expect(all[0].importSourceJID == "other@example.com")
        }

        @Test
        @MainActor
        func `createAccount passes optional fields to store`() async throws {
            let store = makeStore()
            let service = makeAccountService(store: store)

            _ = try await service.createAccount(
                jidString: testJIDString,
                displayName: "Alice",
                host: "xmpp.example.com",
                port: 5223,
                resource: "phone",
                requireTLS: false,
                connectOnLaunch: true,
                importedFrom: "Adium"
            )

            let accounts = try await store.fetchAccounts()
            #expect(accounts.count == 1)
            #expect(accounts[0].displayName == "Alice")
            #expect(accounts[0].host == "xmpp.example.com")
            #expect(accounts[0].port == 5223)
            #expect(accounts[0].resource == "phone")
            #expect(accounts[0].requireTLS == false)
            #expect(accounts[0].connectOnLaunch == true)
            #expect(accounts[0].importedFrom == "Adium")
        }
    }

    struct LoadAccounts {
        @Test
        @MainActor
        func `loadAccounts populates accounts and connectionStates`() async throws {
            let store = makeStore()
            let account = makeAccount()
            await store.addAccount(account)

            let service = makeAccountService(store: store)
            try await service.loadAccounts()

            #expect(service.accounts.count == 1)
            #expect(service.accounts[0].id == account.id)
            if case .disconnected = service.connectionStates[account.id] {
                // Expected
            } else {
                Issue.record("Expected .disconnected, got \(String(describing: service.connectionStates[account.id]))")
            }
        }
    }

    struct ConnectEnabledAccounts {
        @Test
        @MainActor
        func `connects an enabled connectOnLaunch account and skips one without the flag`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let flaggedJID = try #require(BareJID(localPart: "alice", domainPart: "example.com"))
            let unflaggedJID = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
            let flagged = Account(id: UUID(), jid: flaggedJID, isEnabled: true, connectOnLaunch: true, createdAt: Date())
            let unflagged = Account(id: UUID(), jid: unflaggedJID, isEnabled: true, connectOnLaunch: false, createdAt: Date())
            await store.addAccount(flagged)
            await store.addAccount(unflagged)
            credentials.savePassword("secret", for: flagged.jid.description)
            credentials.savePassword("secret", for: unflagged.jid.description)

            // A permanent connect error makes the attempted account land in `.error`
            // without driving a handshake; the skipped account stays `.disconnected`.
            let transport = MockTransport(connectError: TestError())
            let factory = MockXMPPClientFactory(transport: transport)
            let service = makeAccountService(store: store, credentials: credentials, clientFactory: factory)
            try await service.loadAccounts()

            await service.connectEnabledAccounts()

            if case .error = service.connectionStates[flagged.id] {
                // Expected — the flagged account was attempted.
            } else {
                Issue.record("Expected .error for the flagged account, got \(String(describing: service.connectionStates[flagged.id]))")
            }
            if case .disconnected = service.connectionStates[unflagged.id] {
                // Expected — the unflagged account was never attempted.
            } else {
                Issue.record("Expected .disconnected for the unflagged account, got \(String(describing: service.connectionStates[unflagged.id]))")
            }
        }

        @Test
        @MainActor
        func `connectEnabledAccounts skips an already-connected account`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let account = Account(id: UUID(), jid: testJID, isEnabled: true, connectOnLaunch: true, createdAt: Date())
            await store.addAccount(account)
            credentials.savePassword("secret", for: account.jid.description)

            let transport = MockTransport()
            let factory = MockXMPPClientFactory(transport: transport)
            let service = makeAccountService(store: store, credentials: credentials, clientFactory: factory)
            try await service.loadAccounts()

            let (client, connectTask) = try await driveMockConnect(service, accountID: account.id, transport: transport)

            // Re-running launch connect must skip the already-connected account: the same client instance
            // stays in place (a re-dial would build a new client and fail on the already-connected transport).
            await service.connectEnabledAccounts()
            #expect(service.connectedClient(for: account.id) === client)

            connectTask.cancel()
            await service.disconnect(accountID: account.id)
        }

        @Test
        @MainActor
        func `connectEnabledAccountsOnLaunch connects only on its first call`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let account = Account(id: UUID(), jid: testJID, isEnabled: true, connectOnLaunch: true, createdAt: Date())
            await store.addAccount(account)
            credentials.savePassword("secret", for: account.jid.description)

            // A permanent connect error lands an attempted account in `.error` without a handshake.
            let transport = MockTransport(connectError: TestError())
            let factory = MockXMPPClientFactory(transport: transport)
            let service = makeAccountService(store: store, credentials: credentials, clientFactory: factory)
            try await service.loadAccounts()

            await service.connectEnabledAccountsOnLaunch()
            guard case .error = service.connectionStates[account.id] else {
                Issue.record("Expected the first call to attempt a connect, got \(String(describing: service.connectionStates[account.id]))")
                return
            }

            await service.disconnect(accountID: account.id)
            await service.connectEnabledAccountsOnLaunch()

            guard case .disconnected = service.connectionStates[account.id] else {
                Issue.record("Expected the second call not to reconnect, got \(String(describing: service.connectionStates[account.id]))")
                return
            }
        }

        @Test
        @MainActor
        func `connectEnabledAccountsOnLaunch still connects when its caller is cancelled`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let account = Account(id: UUID(), jid: testJID, isEnabled: true, connectOnLaunch: true, createdAt: Date())
            await store.addAccount(account)
            credentials.savePassword("secret", for: account.jid.description)

            // A cancelled connect bails before `.connecting`, so only a real attempt reaches the connect error's `.error`.
            let transport = MockTransport(connectError: TestError())
            let factory = MockXMPPClientFactory(transport: transport)
            let service = makeAccountService(store: store, credentials: credentials, clientFactory: factory)
            try await service.loadAccounts()

            // Closing the Contacts window cancels the view task that makes the launch call.
            let caller = Task { await service.connectEnabledAccountsOnLaunch() }
            caller.cancel()
            await caller.value

            guard case .error = service.connectionStates[account.id] else {
                Issue.record("Expected the launch attempt to survive cancellation, got \(String(describing: service.connectionStates[account.id]))")
                return
            }
        }
    }

    struct DeleteAccount {
        @Test
        @MainActor
        func `deleteAccount removes from store and deletes password`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let account = makeAccount()
            await store.addAccount(account)
            credentials.savePassword("secret", for: account.jid.description)

            let service = makeAccountService(store: store, credentials: credentials)
            try await service.loadAccounts()
            #expect(service.accounts.count == 1)

            try await service.deleteAccount(account.id)

            #expect(service.accounts.isEmpty)
            let storedAccounts = try await store.fetchAccounts()
            #expect(storedAccounts.isEmpty)
            #expect(credentials.loadPassword(for: account.jid.description) == nil)
        }
    }

    struct CredentialManagement {
        @Test
        @MainActor
        func `connect without stored password throws noStoredPassword`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let account = makeAccount()
            await store.addAccount(account)

            let service = makeAccountService(store: store, credentials: credentials)
            try await service.loadAccounts()

            await #expect(throws: AccountService.AccountServiceError.self) {
                try await service.connect(accountID: account.id)
            }
        }
    }

    struct CreateAndConnect {
        @Test
        @MainActor
        func `rollback on connection failure deletes account and unlinks conversations`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let contactJID = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
            let conv = makeConversation(jid: contactJID, importSourceJID: testJIDString)
            await store.addConversation(conv)

            let transport = MockTransport(connectError: TestError())
            let factory = MockXMPPClientFactory(transport: transport)
            let service = makeAccountService(store: store, credentials: credentials, clientFactory: factory)

            await #expect(throws: TestError.self) {
                _ = try await service.createAndConnect(
                    jidString: testJIDString, password: "secret",
                    host: "example.com", port: 5222
                )
            }

            let accounts = try await store.fetchAccounts()
            #expect(accounts.isEmpty)

            let all = try await store.fetchAllConversations()
            #expect(all.count == 1)
            #expect(all[0].accountID == nil)
            #expect(all[0].importSourceJID == testJIDString)

            #expect(credentials.loadPassword(for: testJIDString) == nil)
        }

        @Test
        @MainActor
        func `success saves password and reloads accounts`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let transport = MockTransport()
            let factory = MockXMPPClientFactory(transport: transport)
            let service = makeAccountService(store: store, credentials: credentials, clientFactory: factory)

            let connectTask = Task { @MainActor in
                try await service.createAndConnect(
                    jidString: testJIDString, password: "secret",
                    host: "example.com", port: 5222
                )
            }
            await simulateNoTLSConnect(transport)
            let accountID = try await connectTask.value

            #expect(credentials.loadPassword(for: testJIDString) == "secret")

            let accounts = try await store.fetchAccounts()
            #expect(accounts.count == 1)
            #expect(accounts[0].id == accountID)
            #expect(accounts[0].connectOnLaunch == true)
        }

        @Test
        @MainActor
        func `afterConnect failure triggers rollback with contact deletion`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let contactJID = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
            let conv = makeConversation(jid: contactJID, importSourceJID: testJIDString)
            await store.addConversation(conv)

            let transport = MockTransport()
            let factory = MockXMPPClientFactory(transport: transport)
            let service = makeAccountService(store: store, credentials: credentials, clientFactory: factory)

            let connectTask = Task { @MainActor in
                try await service.createAndConnect(
                    jidString: testJIDString, password: "secret",
                    host: "example.com", port: 5222,
                    afterConnect: { accountID in
                        let contact = Contact(
                            id: UUID(), accountID: accountID, jid: contactJID,
                            subscription: .both, groups: [], isBlocked: false, createdAt: Date()
                        )
                        try await store.upsertContact(contact)
                        throw TestError()
                    }
                )
            }
            await simulateNoTLSConnect(transport)

            await #expect(throws: TestError.self) {
                _ = try await connectTask.value
            }

            let accounts = try await store.fetchAccounts()
            #expect(accounts.isEmpty)

            let contacts = await store.contacts
            #expect(contacts.isEmpty)

            let all = try await store.fetchAllConversations()
            #expect(all.count == 1)
            #expect(all[0].accountID == nil)
            #expect(all[0].importSourceJID == testJIDString)

            #expect(credentials.loadPassword(for: testJIDString) == nil)
        }
    }

    struct IsAuthenticationError {
        @Test
        func `returns true for authenticationFailed`() {
            let error: any Error = XMPPClientError.authenticationFailed("not-authorized")
            #expect(AccountService.isAuthenticationError(error))
        }

        @Test
        func `returns false for other XMPPClientError cases`() {
            #expect(!AccountService.isAuthenticationError(XMPPClientError.notConnected))
            #expect(!AccountService.isAuthenticationError(XMPPClientError.timeout))
            #expect(!AccountService.isAuthenticationError(XMPPClientError.tlsRequired))
        }

        @Test
        func `returns false for unrelated errors`() {
            #expect(!AccountService.isAuthenticationError(TestError()))
        }
    }

    struct DisconnectMessages {
        @Test(arguments: [
            (XMPPStreamError?.some(.systemShutdown), String?.some("Maintenance window"), "Maintenance window"),
            (XMPPStreamError?.some(.systemShutdown), String?.some(" \n "), "The server is shutting down"),
            (XMPPStreamError?.some(.policyViolation), String?.none, "The connection violates a server policy"),
            (XMPPStreamError?.none, String?.some("Idle timeout"), "Idle timeout"),
            (XMPPStreamError?.none, String?.none, "The server closed the connection")
        ])
        func `streamErrorMessage prefers non-blank text, then the condition phrase`(
            condition: XMPPStreamError?, text: String?, expected: String
        ) {
            #expect(AccountService.streamErrorMessage(condition: condition, text: text) == expected)
        }

        @Test
        func `connectionLostMessage labels the detail`() {
            #expect(AccountService.connectionLostMessage("Stream ended") == "Connection lost: Stream ended")
        }

        enum Trigger: Sendable {
            case systemShutdownStreamError
            case streamEnd
        }

        @Test(arguments: [
            (Trigger.systemShutdownStreamError, "The server is shutting down"),
            (Trigger.streamEnd, "Connection lost: Stream ended")
        ])
        @MainActor
        func `a dropped stream stores the composed message`(trigger: Trigger, expected: String) async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let account = makeAccount()
            await store.addAccount(account)
            let transport = MockTransport()
            let factory = MockXMPPClientFactory(transport: transport)
            let service = makeAccountService(store: store, credentials: credentials, clientFactory: factory)
            try await service.loadAccounts()
            let (_, connectTask) = try await driveMockConnect(service, accountID: account.id, transport: transport)

            var stateAtDisconnect: AccountService.ConnectionState?
            service.onEvent = { [weak service] event, accountID in
                if case .disconnected = event { stateAtDisconnect = service?.connectionStates[accountID] }
            }
            switch trigger {
            case .systemShutdownStreamError:
                await transport.simulateReceive("<error><system-shutdown xmlns='urn:ietf:params:xml:ns:xmpp-streams'/></error>")
            case .streamEnd:
                await transport.simulateDisconnect()
            }
            for _ in 0 ..< 100 {
                if stateAtDisconnect != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }

            connectTask.cancel()
            await service.disconnectAll()

            guard case let .error(message) = stateAtDisconnect else {
                Issue.record("Expected .error at disconnect, got \(String(describing: stateAtDisconnect))")
                return
            }
            #expect(message == expected)
        }
    }

    struct SavePassword {
        @Test
        @MainActor
        func `savePassword persists to credential store`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let transport = MockTransport(connectError: TestError())
            let factory = MockXMPPClientFactory(transport: transport)
            let service = makeAccountService(store: store, credentials: credentials, clientFactory: factory)

            let accountID = try await service.createAccount(jidString: testJIDString)
            try await service.loadAccounts()

            // connect sets passwords[accountID] before performConnect throws
            do {
                try await service.connect(accountID: accountID, password: "secret")
            } catch is TestError {}

            await service.savePassword(accountID: accountID)

            #expect(credentials.loadPassword(for: testJIDString) == "secret")
        }

        @Test
        @MainActor
        func `savePassword overload persists a directly supplied password`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let service = makeAccountService(store: store, credentials: credentials)

            let accountID = try await service.createAccount(jidString: testJIDString)
            try await service.loadAccounts()

            // No connect populates passwords[accountID]; the overload seeds it directly.
            await service.savePassword(accountID: accountID, password: "secret")

            #expect(credentials.loadPassword(for: testJIDString) == "secret")
        }
    }

    struct DisconnectAll {
        @Test
        @MainActor
        func `disconnectAll tears down a connected client`() async throws {
            let store = makeStore()
            let credentials = makeCredentials()
            let transport = MockTransport()
            let factory = MockXMPPClientFactory(transport: transport)
            let service = makeAccountService(store: store, credentials: credentials, clientFactory: factory)

            let connectTask = Task { @MainActor in
                try await service.createAndConnect(
                    jidString: testJIDString, password: "secret",
                    host: "example.com", port: 5222
                )
            }
            await simulateNoTLSConnect(transport)
            let accountID = try await connectTask.value

            await service.disconnectAll()

            if case .disconnected = service.connectionStates[accountID] {
                // Expected
            } else {
                Issue.record("Expected .disconnected after disconnectAll, got \(String(describing: service.connectionStates[accountID]))")
            }
            #expect(service.client(for: accountID) == nil)
        }

        @Test
        @MainActor
        func `disconnectAll within deadline returns even when no clients are connected`() async {
            // Fast smoke-test: zero-client case must complete promptly so the
            // deadline path doesn't dominate the latency budget at app exit.
            let store = makeStore()
            let service = makeAccountService(store: store)

            let clock = ContinuousClock()
            let elapsed = await clock.measure {
                await service.disconnectAll(within: .seconds(1))
            }
            #expect(elapsed < .milliseconds(500))
        }
    }
}
