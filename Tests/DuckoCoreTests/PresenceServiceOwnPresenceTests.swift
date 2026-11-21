import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// MARK: - Tests

enum PresenceServiceOwnPresenceTests {
    struct GlobalAndAccountPresence {
        @Test
        @MainActor
        func `applyGlobalPresence broadcasts to every connected account and clears overrides`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService

            // Pin Bob to DND, then clear the wire so the global broadcast is isolated.
            await service.applyAccountPresence(.dnd, message: "busy", accountID: fixture.bobID, connect: { _ in }, disconnect: { _ in })
            #expect(service.effectivePresence(for: fixture.bobID).status == .dnd)
            await fixture.aliceTransport.clearSentBytes()
            await fixture.bobTransport.clearSentBytes()

            await service.applyGlobalPresence(.away, message: nil) { id in
                try await fixture.accountService.connect(accountID: id)
            } disconnect: { id in
                await fixture.accountService.disconnect(accountID: id)
            }

            let alice = await fixture.aliceTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            let bob = await fixture.bobTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(alice.contains { $0.contains("<presence") && $0.contains("away") })
            #expect(bob.contains { $0.contains("<presence") && $0.contains("away") })
            #expect(service.effectivePresence(for: fixture.bobID).status == .away)

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `applyAccountPresence pins one account and a later global resets everyone`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService
            await fixture.aliceTransport.clearSentBytes()
            await fixture.bobTransport.clearSentBytes()

            await service.applyAccountPresence(.dnd, message: "busy", accountID: fixture.bobID) { id in
                try await fixture.accountService.connect(accountID: id)
            } disconnect: { id in
                await fixture.accountService.disconnect(accountID: id)
            }

            let bob = await fixture.bobTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            let alice = await fixture.aliceTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(bob.contains { $0.contains("<presence") && $0.contains("dnd") && $0.contains("busy") })
            #expect(alice.allSatisfy { !$0.contains("<presence") })
            #expect(service.effectivePresence(for: fixture.bobID).status == .dnd)
            #expect(service.effectivePresence(for: fixture.bobID).message == "busy")
            #expect(service.effectivePresence(for: fixture.aliceID).status == .available)

            await service.applyGlobalPresence(.available, message: nil, connect: { _ in }, disconnect: { _ in })
            #expect(service.effectivePresence(for: fixture.bobID).status == .available)

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `applyAccountPresence offline stores no override and disconnects only that account`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService

            // Pre-pin Bob so the assertion proves the override is dropped, not stored as an offline override.
            await service.applyAccountPresence(.dnd, message: nil, accountID: fixture.bobID, connect: { _ in }, disconnect: { _ in })
            #expect(service.effectivePresence(for: fixture.bobID).status == .dnd)

            await service.applyAccountPresence(.offline, message: nil, accountID: fixture.bobID) { id in
                try await fixture.accountService.connect(accountID: id)
            } disconnect: { id in
                await fixture.accountService.disconnect(accountID: id)
            }

            // Effective falls back to the global Available — not Offline — so no override lingers.
            #expect(service.effectivePresence(for: fixture.bobID).status == .available)
            #expect(fixture.accountService.connectedClient(for: fixture.bobID) == nil)
            #expect(fixture.accountService.connectedClient(for: fixture.aliceID) != nil)

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `applyAccountPresence broadcasts the account's status while the global status is offline`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService
            service.myPresence = .offline
            await fixture.aliceTransport.clearSentBytes()
            await fixture.bobTransport.clearSentBytes()

            await service.applyAccountPresence(.away, message: nil, accountID: fixture.bobID, connect: { _ in }, disconnect: { _ in })

            let bob = await fixture.bobTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            let alice = await fixture.aliceTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(bob.contains { $0.contains("<presence") && $0.contains("<show>away</show>") })
            #expect(alice.allSatisfy { !$0.contains("<presence") })

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `displayedPresences reports every enabled account's displayed status and message`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService
            func statuses() -> [PresenceService.PresenceStatus] {
                service.displayedPresences().map(\.status)
            }
            func messages() -> [String?] {
                service.displayedPresences().map(\.message)
            }

            await service.applyGlobalPresence(.away, message: "Lunch", connect: { _ in }, disconnect: { _ in })
            #expect(statuses() == [.away, .away])
            #expect(messages() == ["Lunch", "Lunch"])

            await service.applyAccountPresence(.dnd, message: nil, accountID: fixture.bobID, connect: { _ in }, disconnect: { _ in })
            #expect(statuses() == [.away, .dnd])
            #expect(messages() == ["Lunch", nil])

            await service.applyAccountPresence(.offline, message: nil, accountID: fixture.bobID) { id in
                try await fixture.accountService.connect(accountID: id)
            } disconnect: { id in
                await fixture.accountService.disconnect(accountID: id)
            }
            #expect(statuses() == [.away, .offline])

            // A disconnected enabled account reads Offline, and a disabled one drops out.
            let carolID = try await fixture.accountService.createAccount(jidString: "carol@example.com")
            #expect(statuses() == [.away, .offline, .offline])
            var carol = try #require(fixture.accountService.accounts.first { $0.id == carolID })
            carol.isEnabled = false
            try await fixture.accountService.updateAccount(carol)
            #expect(statuses() == [.away, .offline])

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `applyAccountPresence connects a disconnected account for an online status`() async throws {
            let (accountService, presenceService) = makeUnconnectedService()
            let aliceID = try await accountService.createAccount(jidString: "alice@example.com")

            let recorder = CallRecorder()
            await presenceService.applyAccountPresence(.away, message: nil, accountID: aliceID) { id in
                recorder.append(id)
            } disconnect: { _ in }

            #expect(recorder.ids == [aliceID])
            #expect(presenceService.effectivePresence(for: aliceID).status == .away)
        }

        @Test
        @MainActor
        func `a user-initiated AccountService disconnect clears the account override`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService

            await service.applyAccountPresence(.dnd, message: nil, accountID: fixture.bobID, connect: { _ in }, disconnect: { _ in })
            #expect(service.effectivePresence(for: fixture.bobID).status == .dnd)

            // A deliberate disconnect must drop the pin even though the cancelled event task never delivers
            // `.disconnected(.requested)` to `handleEvent`.
            await fixture.accountService.disconnect(accountID: fixture.bobID)
            #expect(service.effectivePresence(for: fixture.bobID).status == .available)

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `an override survives a connection-lost disconnect and is dropped by a requested one`() async {
            let service = makePresenceService()
            let accountID = UUID()
            await service.applyAccountPresence(.dnd, message: nil, accountID: accountID, connect: { _ in }, disconnect: { _ in })
            #expect(service.effectivePresence(for: accountID).status == .dnd)

            await service.handleEvent(.disconnected(.connectionLost("dropped")), accountID: accountID)
            #expect(service.effectivePresence(for: accountID).status == .dnd)

            await service.handleEvent(.disconnected(.requested), accountID: accountID)
            #expect(service.effectivePresence(for: accountID).status == .available)
        }

        @Test
        @MainActor
        func `effectivePresence returns global without an override and the override when set`() async {
            let service = makePresenceService()
            let accountID = UUID()
            #expect(service.effectivePresence(for: accountID).status == .available)
            #expect(service.effectivePresence(for: accountID).message == nil)

            await service.applyAccountPresence(.dnd, message: "busy", accountID: accountID, connect: { _ in }, disconnect: { _ in })
            #expect(service.effectivePresence(for: accountID).status == .dnd)
            #expect(service.effectivePresence(for: accountID).message == "busy")
        }
    }

    struct OverrideIdleAndReapply {
        @Test
        @MainActor
        func `idle auto-away leaves a per-account override untouched`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService

            await service.applyAccountPresence(.dnd, message: nil, accountID: fixture.bobID, connect: { _ in }, disconnect: { _ in })
            await fixture.aliceTransport.clearSentBytes()
            await fixture.bobTransport.clearSentBytes()

            await service.applyIdleTransition(idleTime: 400, timeout: 300)
            let aliceAway = await fixture.aliceTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            let bobAway = await fixture.bobTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(aliceAway.contains { $0.contains("<presence") && $0.contains("away") })
            #expect(bobAway.allSatisfy { !$0.contains("away") })
            #expect(service.effectivePresence(for: fixture.bobID).status == .dnd)

            await service.applyIdleTransition(idleTime: 0, timeout: 300)
            #expect(service.myPresence == .available)
            #expect(service.effectivePresence(for: fixture.bobID).status == .dnd)

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `reconnect reapplies an account override rather than a blank available`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService

            // Global stays plain Available; only Bob carries a DND override.
            await service.applyAccountPresence(.dnd, message: nil, accountID: fixture.bobID, connect: { _ in }, disconnect: { _ in })
            await fixture.bobTransport.clearSentBytes()

            let bobBare = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
            let bobFullJID = try #require(FullJID(bareJID: bobBare, resourcePart: "ducko"))
            await service.handleEvent(.connected(bobFullJID), accountID: fixture.bobID)

            let bob = await fixture.bobTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(bob.contains { $0.contains("<presence") && $0.contains("dnd") })

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `resendEffectivePresence re-broadcasts an account override, not the global status`() async throws {
            // The path AvatarService uses for avatar/vCard/MUC re-broadcasts: it must carry the override.
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService

            await service.applyAccountPresence(.dnd, message: nil, accountID: fixture.bobID, connect: { _ in }, disconnect: { _ in })
            await fixture.bobTransport.clearSentBytes()

            await service.resendEffectivePresence(accountID: fixture.bobID)

            let bob = await fixture.bobTransport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(bob.contains { $0.contains("<presence") && $0.contains("dnd") })

            await fixture.teardown()
        }
    }

    struct GlobalPresenceLifecycle {
        @Test
        @MainActor
        func `going online skips an account that is still connecting`() async throws {
            let fixture = try await makeAliceConnectedBobConnecting()
            let carolID = try await fixture.accountService.createAccount(jidString: "carol@example.com", host: "example.com", port: 5222)

            let recorder = CallRecorder()
            await fixture.presenceService.applyGlobalPresence(.available, message: nil) { id in
                recorder.append(id)
            } disconnect: { _ in }

            // Carol, disconnected, proves the connect loop ran; Bob's in-flight connect is left alone.
            #expect(recorder.ids == [carolID])

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `going online starts every pending connect without waiting on a stalled one`() async throws {
            let (accountService, presenceService) = makeUnconnectedService()
            let aliceID = try await accountService.createAccount(jidString: "alice@example.com")
            let bobID = try await accountService.createAccount(jidString: "bob@example.com")

            // Alice's connect stalls until released, standing in for an unreachable server.
            let (release, releaser) = AsyncStream<Void>.makeStream()
            let recorder = CallRecorder()
            let apply = Task { @MainActor in
                await presenceService.applyGlobalPresence(.available, message: nil) { id in
                    recorder.append(id)
                    guard id == aliceID else { return }
                    for await _ in release {
                        break
                    }
                } disconnect: { _ in }
            }

            // Both connects start while Alice's is still stalled; the children start in no guaranteed order.
            try await eventually { Set(recorder.ids) == [aliceID, bobID] }

            releaser.finish()
            await apply.value
        }

        @Test
        @MainActor
        func `an offline pick during the online broadcast is not undone by the online pick`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService
            await service.applyAccountPresence(.offline, message: nil, accountID: fixture.bobID) { id in
                try await fixture.accountService.connect(accountID: id)
            } disconnect: { id in
                await fixture.accountService.disconnect(accountID: id)
            }

            // Hold Alice's Away broadcast on the wire so the Offline pick lands while the Away pick is mid-broadcast.
            await fixture.aliceTransport.blockSends { $0.contains("<presence") && $0.contains("away") }
            let recorder = CallRecorder()
            let online = Task { @MainActor in
                await service.applyGlobalPresence(.away, message: nil) { id in
                    recorder.append(id)
                } disconnect: { _ in }
            }
            let aliceTransport = fixture.aliceTransport
            let blocked = try await boundedOutcome {
                await aliceTransport.waitForBlockedSend()
            }
            #expect(blocked != nil)
            // Bob's connect is already under way while the broadcast is held, before the Offline pick.
            let bobID = fixture.bobID
            try await eventually { recorder.ids.contains(bobID) }

            await service.applyGlobalPresence(.offline, message: nil) { _ in
            } disconnect: { id in
                await fixture.accountService.disconnect(accountID: id)
            }
            await fixture.aliceTransport.releaseBlockedSends()
            await online.value

            // Alice, torn down by Offline, is never reconnected by the older Away pick.
            #expect(recorder.ids == [fixture.bobID])

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `global offline tears down a connect still waiting on the store`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService
            let accountService = fixture.accountService
            let bobID = fixture.bobID
            await service.applyAccountPresence(.offline, message: nil, accountID: bobID) { id in
                try await accountService.connect(accountID: id)
            } disconnect: { id in
                await accountService.disconnect(accountID: id)
            }

            // Hold Bob's reconnect in its store fetch, before any client exists.
            let entered = AsyncSemaphore()
            let release = AsyncSemaphore()
            await fixture.store.installFetchAccountsGate(entered: entered, release: release)
            let online = Task { @MainActor in
                await service.applyGlobalPresence(.available, message: nil) { id in
                    try await accountService.connect(accountID: id, password: "secret")
                } disconnect: { _ in }
            }
            let held = try await boundedOutcome { await entered.wait() }
            #expect(held != nil)
            #expect(isConnecting(accountService.connectionStates[bobID]))

            await service.applyGlobalPresence(.offline, message: nil) { _ in
            } disconnect: { id in
                await accountService.disconnect(accountID: id)
            }
            await release.signal()
            let finished = try await boundedOutcome { await online.value }
            #expect(finished != nil)

            #expect(isDisconnected(accountService.connectionStates[bobID]))
            #expect(accountService.connectedClient(for: bobID) == nil)

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `going online during a stalled offline reconnects the accounts it already tore down`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService
            let accountService = fixture.accountService

            // Alice's teardown stalls on its unavailable presence, standing in for an unresponsive server.
            await fixture.aliceTransport.blockSends { $0.contains("unavailable") }
            let offline = Task { @MainActor in
                await service.applyGlobalPresence(.offline, message: nil) { _ in
                } disconnect: { id in
                    await accountService.disconnect(accountID: id)
                }
            }
            let aliceTransport = fixture.aliceTransport
            let stalled = try await boundedOutcome { await aliceTransport.waitForBlockedSend() }
            #expect(stalled != nil)
            // Bob's teardown child may start after Alice's stalls; a newer pick would rightly skip it.
            let aliceID = fixture.aliceID
            let bobID = fixture.bobID
            try await eventually {
                isDisconnected(accountService.connectionStates[aliceID]) && isDisconnected(accountService.connectionStates[bobID])
            }

            let recorder = CallRecorder()
            await service.applyGlobalPresence(.available, message: nil) { id in
                recorder.append(id)
            } disconnect: { _ in }

            #expect(Set(recorder.ids) == [fixture.aliceID, fixture.bobID])
            #expect(service.myPresence == .available)

            await fixture.aliceTransport.releaseBlockedSends()
            await offline.value
            await fixture.teardown()
        }

        @Test
        @MainActor
        func `going online broadcasts to connected accounts before a pending connect finishes`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService
            await service.applyAccountPresence(.offline, message: nil, accountID: fixture.bobID) { id in
                try await fixture.accountService.connect(accountID: id)
            } disconnect: { id in
                await fixture.accountService.disconnect(accountID: id)
            }
            await fixture.aliceTransport.clearSentBytes()

            // Bob's connect stalls until released, standing in for an unreachable server.
            let (release, releaser) = AsyncStream<Void>.makeStream()
            let apply = Task { @MainActor in
                await service.applyGlobalPresence(.away, message: nil) { _ in
                    for await _ in release {
                        break
                    }
                } disconnect: { _ in }
            }

            let outcome = try? await awaitSent(on: fixture.aliceTransport) { $0.contains("<presence") && $0.contains("away") }
            #expect(outcome != nil)

            releaser.finish()
            await apply.value
            await fixture.teardown()
        }

        @Test
        @MainActor
        func `global offline tears down a connecting account too`() async throws {
            let fixture = try await makeAliceConnectedBobConnecting()

            let recorder = CallRecorder()
            await fixture.presenceService.applyGlobalPresence(.offline, message: nil) { _ in
            } disconnect: { id in
                recorder.append(id)
                await fixture.accountService.disconnect(accountID: id)
            }

            #expect(Set(recorder.ids) == Set([fixture.aliceID, fixture.bobID]))
            #expect(fixture.presenceService.myPresence == .offline)

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `global offline tears down an account waiting to reconnect`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let accountService = fixture.accountService
            let aliceID = fixture.aliceID
            // A lost stream leaves Alice in `.error` with a reconnect scheduled.
            await fixture.aliceTransport.simulateDisconnect()
            try await eventually {
                if case .error = accountService.connectionStates[aliceID] { return true }
                return false
            }

            let recorder = CallRecorder()
            await fixture.presenceService.applyGlobalPresence(.offline, message: nil) { _ in
            } disconnect: { id in
                recorder.append(id)
                await accountService.disconnect(accountID: id)
            }

            #expect(Set(recorder.ids) == [aliceID, fixture.bobID])
            #expect(isDisconnected(accountService.connectionStates[aliceID]))

            await fixture.teardown()
        }

        @Test
        @MainActor
        func `going online connects every enabled account whatever connect-on-launch says`() async throws {
            let (accountService, presenceService) = makeUnconnectedService()
            let aliceID = try await accountService.createAccount(jidString: "alice@example.com", connectOnLaunch: true)
            let carolID = try await accountService.createAccount(jidString: "carol@example.com", connectOnLaunch: false)
            let eveID = try await accountService.createAccount(jidString: "eve@example.com")
            var eve = try #require(accountService.accounts.first { $0.id == eveID })
            eve.isEnabled = false
            try await accountService.updateAccount(eve)

            let recorder = CallRecorder()
            await presenceService.applyGlobalPresence(.available, message: nil) { id in
                recorder.append(id)
            } disconnect: { _ in }

            #expect(Set(recorder.ids) == [aliceID, carolID])
        }

        @Test
        @MainActor
        func `going online while another account is connected reconnects an account taken offline`() async throws {
            let fixture = try await makeTwoConnectedAccounts()
            let service = fixture.presenceService
            await service.applyAccountPresence(.offline, message: nil, accountID: fixture.bobID) { id in
                try await fixture.accountService.connect(accountID: id)
            } disconnect: { id in
                await fixture.accountService.disconnect(accountID: id)
            }
            #expect(fixture.accountService.connectedClient(for: fixture.bobID) == nil)

            let recorder = CallRecorder()
            await service.applyGlobalPresence(.available, message: nil) { id in
                recorder.append(id)
            } disconnect: { _ in }

            #expect(recorder.ids == [fixture.bobID])

            await fixture.teardown()
        }
    }
}

// MARK: - Helpers

/// Records the account IDs a `connect`/`disconnect` closure was invoked for. A `@MainActor` class so the
/// `@escaping` apply closures can append without tripping mutable-capture diagnostics.
@MainActor
private final class CallRecorder {
    private(set) var ids: [UUID] = []
    func append(_ id: UUID) {
        ids.append(id)
    }
}

private func isConnecting(_ state: AccountService.ConnectionState?) -> Bool {
    if case .connecting = state { return true }
    return false
}

private func isDisconnected(_ state: AccountService.ConnectionState?) -> Bool {
    if case .disconnected = state { return true }
    return false
}

/// Alice connected and Bob mid-handshake: his connect never finishes, so he stays `.connecting`.
@MainActor
private func makeAliceConnectedBobConnecting() async throws -> TwoConnectedAccountsFixture {
    let services = try await makeTwoAccountServices()
    let (_, aliceTask) = try await driveMockConnect(
        services.accountService, accountID: services.aliceID, transport: services.aliceTransport, awaitInitialPresence: true
    )
    let accountService = services.accountService
    let bobID = services.bobID
    let bobTask = Task { @MainActor in try await accountService.connect(accountID: bobID, password: "secret") }
    try await eventually { isConnecting(accountService.connectionStates[bobID]) }
    return TwoConnectedAccountsFixture(services, aliceTask: aliceTask, bobTask: bobTask)
}

/// An `AccountService`/`PresenceService` pair with no connected accounts, for asserting the connect closures
/// the global apply path invokes without driving real handshakes.
@MainActor
private func makeUnconnectedService() -> (AccountService, PresenceService) {
    let store = MockPersistenceStore()
    let credentials = MockCredentialStore()
    let factory = MockXMPPClientFactory(transportForAccount: { _ in MockTransport() })
    let accountService = AccountService(store: store, credentialStore: credentials, clientFactory: factory)
    let presenceService = PresenceService()
    presenceService.setAccountService(accountService)
    return (accountService, presenceService)
}
