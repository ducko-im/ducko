import DuckoTestSupport
import Testing
@testable import DuckoXMPP

enum ConnectOrderingTests {
    // MARK: - Post-Handshake Ordering

    struct PostHandshakeOrdering {
        /// XEP-0163 §3.3.2: the caps-bearing initial presence must reach the server before any PEP publisher.
        @Test func `the one caps-bearing initial presence precedes the first PEP module stanza`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let capsModule = CapsModule()
            await client.register(PresenceModule(capsModule: capsModule))
            await client.register(capsModule)
            await client.register(pepModule)
            await client.register(omemoModule)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)

            // Initial presence (index 4), then OMEMO's connect-time PEP IQs:
            // device-list retrieve (5), device-list publish (6), bundle publish (7).
            await mock.waitForSent(count: 6)
            let retrieveID = try await #require(extractIQID(from: mock.sentBytes[5]))
            await mock.simulateReceive("<iq type=\"result\" id=\"\(retrieveID)\"/>")
            await mock.waitForSent(count: 7)
            let publishID = try await #require(extractIQID(from: mock.sentBytes[6]))
            await mock.simulateReceive("<iq type=\"result\" id=\"\(publishID)\"/>")
            await mock.waitForSent(count: 8)
            let bundleID = try await #require(extractIQID(from: mock.sentBytes[7]))
            await mock.simulateReceive("<iq type=\"result\" id=\"\(bundleID)\"/>")

            try await connectTask.value

            let sent = await mock.sentBytes
            let strings = sent.map { String(decoding: $0, as: UTF8.self) }
            let presences = strings.indices.filter { strings[$0].contains("<presence") }
            let presenceIndex = try #require(presences.first)
            let omemoIndex = try #require(strings.firstIndex { $0.contains(XMPPNamespaces.omemoDevices) })
            #expect(presences.count == 1)
            #expect(strings[presenceIndex].contains(XMPPNamespaces.caps))
            #expect(presenceIndex < omemoIndex)

            await disconnectFast(client)
        }
    }

    // MARK: - Initial Presence Readiness Signal

    struct InitialPresenceReadiness {
        @Test func `resolves after the initial presence on a fresh connect`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let capsModule = CapsModule()
            await client.register(PresenceModule(capsModule: capsModule))
            await client.register(capsModule)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            // Presence is fire-and-forget, so the gate is open once connect completes; reaching the
            // line after the await proves it resolved rather than hung.
            await client.awaitInitialPresenceSent()

            await disconnectFast(client)
        }

        @Test func `resolves immediately on a resumed session`() async throws {
            // Phase 1: connect with SM enabled to obtain a resume state.
            let mock1 = MockTransport()
            let sm1 = StreamManagementModule()
            let client1 = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock1, requireTLS: false
            )
            await client1.register(sm1)
            await client1.addInterceptor(sm1)

            let connect1 = Task { try await client1.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock1, postAuthFeatures: testFeaturesBindWithSM)
            await mock1.waitForSent(count: 5) // SM <enable>
            await mock1.simulateReceive("<enabled xmlns='urn:xmpp:sm:3' id='sm-resume-1' max='300'/>")
            try await connect1.value
            await mock1.simulateDisconnect()
            try? await Task.sleep(for: .milliseconds(100))
            let resumeState = try #require(sm1.resumeState)

            // Phase 2: reconnect, resuming the prior session (no bind, no presence/caps re-sent).
            let mock2 = MockTransport()
            let sm2 = StreamManagementModule(previousState: resumeState)
            let client2 = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock2, requireTLS: false
            )
            await client2.register(sm2)
            await client2.addInterceptor(sm2)

            let connect2 = Task { try await client2.connect(host: "example.com", port: 5222) }
            await mock2.waitForSent(count: 1)
            await mock2.simulateReceive(testServerStreamOpen)
            await mock2.simulateReceive(testFeaturesNoTLS)
            await mock2.waitForSent(count: 2)
            await mock2.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
            await mock2.waitForSent(count: 3)
            await mock2.simulateReceive(testServerStreamOpen)
            await mock2.simulateReceive(testFeaturesBindWithSM)
            await mock2.waitForSent(count: 4) // <resume> sent instead of bind
            await mock2.simulateReceive("<resumed xmlns='urn:xmpp:sm:3' previd='sm-resume-1' h='0'/>")
            try await connect2.value

            await client2.awaitInitialPresenceSent()

            await mock2.simulateDisconnect()
        }

        @Test func `does not hang after a failed connect`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(PresenceModule())

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await mock.waitForSent(count: 1)
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesNoTLS)
            await mock.waitForSent(count: 2) // auth element sent
            await mock.simulateReceive("<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><not-authorized/></failure>")

            await #expect(throws: (any Error).self) {
                try await connectTask.value
            }

            // The handshake-failure path opens the gate, so this resolves instead of hanging on a dead client.
            await client.awaitInitialPresenceSent()
        }

        @Test func `does not hang after the transport connect fails`() async throws {
            // The establish-failure catch is a distinct settle path from the handshake-failure one above: the
            // transport's connect throws before any handshake runs, so the gate must be opened by the
            // `establish()` catch rather than by the handshake catch. Deleting that settle hangs this await.
            let mock = MockTransport(connectError: XMPPClientError.timeout)
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(PresenceModule())

            await #expect(throws: (any Error).self) {
                try await client.connect(host: "example.com", port: 5222)
            }

            await client.awaitInitialPresenceSent()
        }

        @Test func `a waiter parked before the failure is resolved by it`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(PresenceModule())

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await mock.waitForSent(count: 1)
            // Park the waiter only after the first stanza is on the wire. The connect-start re-gate runs
            // before `openStream` sends that stanza, so it has provably already executed — meaning this
            // parked waiter can be resolved only by the handshake-failure settle this test targets, not by
            // the re-gate. Exercises the path where a gated service is suspended when the connection fails.
            let waiter = Task { await client.awaitInitialPresenceSent() }

            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesNoTLS)
            await mock.waitForSent(count: 2) // auth element sent
            await mock.simulateReceive("<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><not-authorized/></failure>")

            await #expect(throws: (any Error).self) {
                try await connectTask.value
            }

            // The parked waiter is resolved by the failure path within a bound rather than hanging forever.
            let resolved = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await waiter.value; return true }
                group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            #expect(resolved)
        }

        @Test func `connection loss while the gate is closed resolves a parked waiter`() async {
            // The cleanUp / connection-lost settle is a distinct path from the connect-time failure catches:
            // here the session reaches `.connected` and a service parks on the gate, but the connection drops
            // before the caps-bearing presence opens it. Hold that presence off the wire so the gate stays closed
            // across the teardown, proving cleanUp's settle (not the presence settle) is what releases the waiter.
            // Deleting that settle hangs this await.
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let capsModule = CapsModule()
            await client.register(PresenceModule(capsModule: capsModule))
            await client.register(capsModule)

            await mock.blockSends { $0.contains(XMPPNamespaces.caps) }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            // The caps-bearing initial presence is blocked, so the gate's presence settle is never reached and
            // the gate stays closed.
            await mock.waitForBlockedSend()

            let waiter = Task { await client.awaitInitialPresenceSent() }
            try? await Task.sleep(for: .milliseconds(50))

            // Connection lost mid-startup → cleanUp settles the still-closed gate.
            await mock.simulateDisconnect()

            let resolved = await withTaskGroup(of: Bool.self) { group in
                group.addTask { await waiter.value; return true }
                group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            #expect(resolved)

            await mock.releaseBlockedSends()
            connectTask.cancel()
        }

        @Test func `the gate stays closed until the caps-bearing presence is sent`() async {
            // Negative assertion guarding the ordering invariant directly: a regression that opened the gate
            // early — at `.connected` or before `PresenceModule.handleConnect()` completes — would still pass
            // the positive resolution tests.
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let capsModule = CapsModule()
            await client.register(PresenceModule(capsModule: capsModule))
            await client.register(capsModule)

            await mock.blockSends { $0.contains(XMPPNamespaces.caps) }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            await mock.waitForBlockedSend()

            // Use an unstructured task that records resolution into an actor flag rather than a task-group
            // race: the gate await is a non-cancellable `CheckedContinuation`, so an abandoned waiter inside a
            // task group would block the group at scope exit while the gate is deliberately held closed.
            let probe = GateProbe()
            let waiter = Task { await client.awaitInitialPresenceSent(); await probe.markOpen() }

            // While the presence is held off the wire the gate must NOT open.
            try? await Task.sleep(for: .milliseconds(300))
            #expect(await probe.isOpen == false)

            // Releasing the presence sends it, reaching the post-presence settle; the gate then opens.
            await mock.releaseBlockedSends()
            var opened = false
            for _ in 0 ..< 100 {
                if await probe.isOpen { opened = true; break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            #expect(opened)

            waiter.cancel()
            await disconnectFast(client)
            connectTask.cancel()
        }

        @Test func `a same-instance reconnect re-closes the gate for a freshly parked waiter`() async {
            // The connect-start re-gate (`settleInitialPresenceReadiness(open: false)`) is only observable on a
            // *same-instance* reconnect, reachable only through a first-attempt establish failure: that catch
            // sets `.disconnected`, opens the gate, and rethrows WITHOUT calling `connection.disconnect()`, so
            // `XMPPConnection.events` and `MockTransport.receivedData` survive and attempt 2 can complete a full
            // handshake on the same instances. Without the re-gate, attempt 1's stale `isOpen = true` would leak
            // into attempt 2 and resolve a waiter that must stay parked until the new caps-bearing presence is sent.
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            let capsModule = CapsModule()
            await client.register(PresenceModule(capsModule: capsModule))
            await client.register(capsModule)

            // Attempt 1: the transport-connect error makes `establish()` throw before the handshake. The catch
            // opens the gate (now stale-open) and rethrows without disconnecting the surviving connection.
            await mock.failNextConnect(XMPPClientError.timeout)
            await #expect(throws: (any Error).self) {
                try await client.connect(host: "example.com", port: 5222)
            }

            // Attempt 2: reconnect on the same instances, holding the caps-bearing presence off the wire so the
            // gate's presence settle is never reached and its state is governed solely by the connect-start re-gate.
            await mock.blockSends { $0.contains(XMPPNamespaces.caps) }
            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            // `simulateNoTLSConnect`'s `waitForSent(count: 1)` is the barrier proving `openStream` ran — i.e. the
            // re-gate's `settle(open: false)` already executed before this stanza went out.
            await simulateNoTLSConnect(mock)
            await mock.waitForBlockedSend()

            // Park a waiter AFTER the re-gate; the "started" signal proves it reached the closed gate before the
            // negative check, so a non-resolution can't be mistaken for a not-yet-started task.
            let probe = GateProbe()
            let waiter = Task {
                await probe.markStarted()
                await client.awaitInitialPresenceSent()
                await probe.markOpen()
            }
            var started = false
            for _ in 0 ..< 100 {
                if await probe.isStarted { started = true; break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            #expect(started)

            // The re-gate re-closed the gate, so the freshly parked waiter must NOT resolve on the stale open.
            try? await Task.sleep(for: .milliseconds(300))
            #expect(await probe.isOpen == false)

            // Releasing the presence reaches the post-presence settle; the same waiter then resolves.
            await mock.releaseBlockedSends()
            var opened = false
            for _ in 0 ..< 100 {
                if await probe.isOpen { opened = true; break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            #expect(opened)

            waiter.cancel()
            await disconnectFast(client)
            connectTask.cancel()
        }
    }
}

/// Records whether the readiness gate opened, for the negative-assertion test above. An actor (rather than a
/// task-group race) is required because the gate await is a non-cancellable `CheckedContinuation`: a waiter
/// abandoned mid-suspension would otherwise block its enclosing task group from ever returning.
private actor GateProbe {
    private(set) var isStarted = false
    private(set) var isOpen = false
    func markStarted() {
        isStarted = true
    }

    func markOpen() {
        isOpen = true
    }
}

extension ConnectOrderingTests {
    @Test
    static func `teardown during SM enable cannot publish a late connected event`() async throws {
        let transport = MockTransport()
        let client = XMPPClient(domain: "example.com", credentials: .init(username: "user", password: "unused"), transport: transport, requireTLS: false)
        let sm = StreamManagementModule()
        await client.register(sm)
        await client.addInterceptor(sm)
        let events = Task { () -> [XMPPEvent] in
            var collected: [XMPPEvent] = []
            for await event in client.events {
                collected.append(event)
            }
            return collected
        }
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        await transport.installDisconnectGate(entered: entered, release: release)
        let connection = Task { try await client.connect(host: "example.com", port: 5222) }
        await simulateNoTLSConnect(transport, postAuthFeatures: testFeaturesBindWithSM)
        await transport.waitForSent(count: 5)
        await transport.simulateReceive("<stream:error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>redirect.example.com</see-other-host></stream:error>")
        let arrival = try await boundedOutcome { await entered.wait() }
        try #require(arrival != nil)
        // Keep teardown parked while the resumed SM-enable caller has an opportunity to continue.
        let prematureCompletion = try await boundedOutcome(timeout: .milliseconds(250)) { try await connection.value }
        await release.signal()
        await #expect(throws: XMPPClientError.self) { try await connection.value }
        if case .success? = prematureCompletion { Issue.record("Connection succeeded during teardown") }
        let collected = await events.value
        #expect(!collected.contains { if case .connected = $0 { return true }; return false })
    }
}
