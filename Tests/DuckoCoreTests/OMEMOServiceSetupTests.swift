import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let peer = BareJID(localPart: "bob", domainPart: "example.com")!

/// How far each account's encryption setup got, as encrypted chats and the CLI see it, and asking for it again.
enum OMEMOServiceSetupTests {
    @MainActor
    struct State {
        private let service = OMEMOService(omemoStore: MockOMEMOStore())
        private let accountID = UUID()

        @Test func `A connect makes the setup pending, and each outcome replaces it`() throws {
            try service.receiveSetupEvent(.connected(#require(FullJID.parse("alice@example.com/res"))), accountID: accountID)
            #expect(service.setupStates[accountID] == .pending)
            service.receiveSetupEvent(.omemoSetupChanged(.refused(.forbidden)), accountID: accountID)
            #expect(service.setupStates[accountID] == .refused)
            service.receiveSetupEvent(.omemoSetupChanged(.complete), accountID: accountID)
            #expect(service.setupStates[accountID] == .complete)
            service.receiveSetupEvent(.disconnected(.connectionLost("gone")), accountID: accountID)
            #expect(service.setupStates[accountID] == .complete)
        }

        @Test func `An outcome or a disconnect ends a retry`() {
            for event in [XMPPEvent.omemoSetupChanged(.incomplete), .disconnected(.connectionLost("gone"))] {
                service.retryingSetupAccounts.insert(accountID)
                service.receiveSetupEvent(event, accountID: accountID)
                #expect(service.retryingSetupAccounts.isEmpty)
            }
        }

        @Test func `A dismissed notice stays hidden in its chat only, until the next failed attempt`() {
            service.receiveSetupEvent(.omemoSetupChanged(.incomplete), accountID: accountID)
            service.dismissSetupProblem(accountID: accountID, conversationJID: peer.description)
            #expect(service.setupProblem(accountID: accountID, conversationJID: peer.description) == nil)
            #expect(service.setupProblem(accountID: accountID, conversationJID: "carol@example.com") == .incomplete)

            service.clearSetupState(accountID: accountID)
            service.receiveSetupEvent(.omemoSetupChanged(.complete), accountID: accountID)
            #expect(service.setupProblem(accountID: accountID, conversationJID: "carol@example.com") == nil)
            service.receiveSetupEvent(.omemoSetupChanged(.refused(.forbidden)), accountID: accountID)
            #expect(service.setupProblem(accountID: accountID, conversationJID: peer.description) == .refused)
        }

        @Test func `Clearing the state keeps what the user dismissed`() {
            service.receiveSetupEvent(.omemoSetupChanged(.incomplete), accountID: accountID)
            service.dismissSetupProblem(accountID: accountID, conversationJID: peer.description)
            service.retryingSetupAccounts.insert(accountID)

            service.clearSetupState(accountID: accountID)

            #expect(service.setupStates[accountID] == nil)
            #expect(service.retryingSetupAccounts.isEmpty)
            #expect(service.dismissedSetupProblems[accountID] == [peer.description])
        }

        @Test func `Without a connection there is nothing to retry`() async {
            service.receiveSetupEvent(.omemoSetupChanged(.incomplete), accountID: accountID)
            #expect(await service.retrySetup(accountID: accountID) == .notConnected)
            #expect(service.retryingSetupAccounts.isEmpty)
        }

        /// The account's events reach the setup state in their order, before any of them is handled on its own task, and
        /// handling the connect on its task afterwards leaves the outcome as it is.
        @Test func `A fast outcome is not overwritten by the connect before it`() async throws {
            let env = AppEnvironment(store: MockPersistenceStore(), transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore())
            try env.accountService.onEvent?(.connected(#require(FullJID.parse("alice@example.com/res"))), accountID)
            env.accountService.onEvent?(.omemoSetupChanged(.refused(.forbidden)), accountID)
            #expect(env.omemoService.setupProblem(accountID: accountID, conversationJID: peer.description) == .refused)

            try await Task.sleep(for: .milliseconds(200))
            #expect(env.omemoService.setupProblem(accountID: accountID, conversationJID: peer.description) == .refused)
        }

        @Test func `Each account's module stores its new identity under its own address`() async throws {
            let store = MockOMEMOStore()
            let service = OMEMOService(omemoStore: store)
            let accounts = try [(UUID(), #require(BareJID.parse("alice@example.com"))), (UUID(), #require(BareJID.parse("carol@example.com")))]
            for (index, (accountID, jid)) in accounts.enumerated() {
                let module = await service.buildModule(for: jid, accountID: accountID, pepModule: PEPModule())
                let (persister, key) = module.state.withLock { ($0.identityPersister, $0.identityPersisterAccountID) }
                let data = try EncryptedSendHarness.device(UInt32(300 + index), preKeyID: 1).keys
                #expect(try await #require(persister).persistNewIdentity(data, accountID: #require(key)))
            }

            for (index, (_, jid)) in accounts.enumerated() {
                #expect(try await store.loadIdentity(for: jid.description)?.deviceID == UInt32(300 + index))
            }
        }
    }

    /// A connected account whose setup's read of the account's list the test releases or fails, on a new device unless
    /// the test gives it device 100.
    @MainActor
    struct Connected {
        @Test func `Try Again runs only for an incomplete or refused setup`() async throws {
            let harness = try await EncryptedSendHarness.connect(newDevice: true)
            await harness.transport.waitForBlockedSend()
            #expect(await harness.omemoService.retrySetup(accountID: harness.accountID) == .notNeeded)

            await harness.transport.failBlockedSends(with: XMPPClientError.sendFailed("The connection was closed"))
            try await eventually { harness.omemoService.setupStates[harness.accountID] == .incomplete }
            #expect(await harness.omemoService.retrySetup(accountID: harness.accountID) == .started)
            #expect(harness.omemoService.retryingSetupAccounts == [harness.accountID])

            try await eventually { harness.omemoService.setupStates[harness.accountID] == .complete }
            #expect(harness.omemoService.retryingSetupAccounts.isEmpty)
            #expect(await harness.omemoService.retrySetup(accountID: harness.accountID) == .notNeeded)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test func `Try Again after a refusal runs an attempt at once`() async throws {
            let harness = try await EncryptedSendHarness.connect(newDevice: true)
            await harness.transport.waitForBlockedSend()
            await harness.transport.failBlockedSends(with: XMPPClientError.sendFailed("The connection was closed"))
            try await eventually { harness.omemoService.setupStates[harness.accountID] == .incomplete }
            harness.omemoService.receiveSetupEvent(.omemoSetupChanged(.refused(.forbidden)), accountID: harness.accountID)

            #expect(await harness.omemoService.retrySetup(accountID: harness.accountID) == .started)

            try await eventually { harness.omemoService.setupStates[harness.accountID] == .complete }
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        /// A resumed session whose module has no identity runs a setup attempt, whatever the account's setup recorded.
        /// A store that keeps no identity leaves even a completed setup's resumed session without one.
        @Test(arguments: [OMEMOSetupState.pending, .incomplete, .refused, .complete])
        func `A resumed session without an identity runs a setup attempt`(state: OMEMOSetupState) async throws {
            let harness = try await EncryptedSendHarness.connect(newDevice: true)
            await harness.transport.waitForBlockedSend()
            await harness.transport.failBlockedSends(with: XMPPClientError.sendFailed("The connection was closed"))
            try await eventually { harness.omemoService.setupStates[harness.accountID] == .incomplete }
            let reads = await ownListReads(harness)

            harness.omemoService.setupStates[harness.accountID] = state
            try await harness.omemoService.handleEvent(.streamResumed(#require(FullJID.parse("\(testJIDString)/ducko"))), accountID: harness.accountID)

            try await eventually { await ownListReads(harness) > reads }
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        /// A resumed session whose module has its identity carries on with a setup the account had not completed, and
        /// leaves a completed one alone. The module's own setup has not completed, as on a resumed session's new
        /// module, so only the account's recorded setup decides.
        @Test(arguments: [
            (OMEMOSetupState.pending, true), (.incomplete, true), (.refused, true), (.complete, false)
        ] as [(OMEMOSetupState, Bool)])
        func `A resumed session with an identity runs an attempt unless its setup completed`(state: OMEMOSetupState, runsAttempt: Bool) async throws {
            let harness = try await EncryptedSendHarness.connect(holdsSetupRead: true)
            await harness.transport.waitForBlockedSend()
            await harness.transport.failBlockedSends(with: XMPPClientError.sendFailed("The connection was closed"))
            try await eventually { harness.omemoService.setupStates[harness.accountID] == .incomplete }
            let reads = await ownListReads(harness)

            harness.omemoService.setupStates[harness.accountID] = state
            try await harness.omemoService.handleEvent(.streamResumed(#require(FullJID.parse("\(testJIDString)/ducko"))), accountID: harness.accountID)

            if runsAttempt {
                try await eventually { await ownListReads(harness) > reads }
            } else {
                try await Task.sleep(for: .milliseconds(200))
                #expect(await ownListReads(harness) == reads)
            }
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        /// A reset waits for the setup that may create this device, and fails before touching a session without one.
        @Test(arguments: [true, false])
        func `A session reset on a new device waits for its setup`(setupSucceeds: Bool) async throws {
            let harness = try await EncryptedSendHarness.connect(newDevice: true)
            await harness.transport.waitForBlockedSend()
            try await harness.omemoStore.saveSession(OMEMOStoredSession(
                accountJID: testJIDString, peerJID: peer.description, peerDeviceID: 200, version: .omemo2, sessionData: Data([1]), associatedData: Data([2])
            ))

            let reset = Task { try await harness.omemoService.resetSessions(peerJID: peer.description, deviceID: nil, accountID: harness.accountID) }
            try await eventually { await harness.identityWaiters() == 1 }
            if setupSucceeds {
                await harness.transport.releaseBlockedSends()
                let report = try await reset.value
                #expect(report.devices.map(\.deviceID) == [200])
            } else {
                await harness.transport.failBlockedSends(with: XMPPClientError.sendFailed("The connection was closed"))
                await #expect(throws: OMEMOServiceError.self) { try await reset.value }
                #expect(try await harness.omemoStore.loadSessions(for: testJIDString).count == 1)
            }
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        private func ownListReads(_ harness: EncryptedSendHarness) async -> Int {
            await harness.transport.sentBytes.count { EncryptedSendHarness.isOwnListRead(String(decoding: $0, as: UTF8.self)) }
        }
    }
}
