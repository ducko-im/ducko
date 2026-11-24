import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

/// Records each setup status `client` reports, including those before it started, since the client's event stream
/// buffers them. Use it only where nothing else reads the client's events.
final class SetupStatusRecorder: Sendable {
    private let statuses = OSAllocatedUnfairLock<[OMEMOSetupStatus]>(initialState: [])
    private let task: Task<Void, Never>

    init(client: XMPPClient) {
        let statuses = statuses
        self.task = Task {
            for await event in client.events {
                if case let .omemoSetupChanged(status) = event {
                    statuses.withLock { $0.append(status) }
                }
            }
        }
    }

    var recorded: [OMEMOSetupStatus] {
        statuses.withLock { $0 }
    }

    deinit {
        task.cancel()
    }
}

/// An OMEMO module talking through a stub context whose IQs `answer` replies to: by default with an empty device list
/// and an empty result for everything else.
private final class SetupHarness: Sendable {
    typealias Answer = @Sendable (XMLElement) async throws -> XMLElement?

    let module: OMEMOModule
    private let sentIQs = OSAllocatedUnfairLock<[XMLElement]>(initialState: [])
    private let events = OSAllocatedUnfairLock<[OMEMOSetupStatus]>(initialState: [])
    private let answer: OSAllocatedUnfairLock<Answer>
    private let draws = OSAllocatedUnfairLock<Int>(initialState: 0)

    init(identity: OMEMOModule.OMEMOIdentityData? = nil, delays: [Duration] = [], answer: @escaping Answer = SetupHarness.emptyServer) {
        let sentIQs = sentIQs
        let events = events
        let answer = OSAllocatedUnfairLock<Answer>(initialState: answer)
        self.answer = answer
        let context = makeStubModuleContext(
            sendIQ: { iq, _ in
                sentIQs.withLock { $0.append(iq.element) }
                return try await answer.withLock { $0 }(iq.element)
            },
            emitEvent: { event in
                if case let .omemoSetupChanged(status) = event {
                    events.withLock { $0.append(status) }
                }
            }
        )
        let pepModule = PEPModule()
        pepModule.setUp(context)
        let draws = draws
        self.module = OMEMOModule(pepModule: pepModule, setupRetryDelays: delays) {
            draws.withLock { $0 += 1 }
            return OMEMODeviceID.random()
        }
        module.setUp(context)
        if let identity {
            module.configureIdentity(identity)
        }
    }

    @Sendable static func emptyServer(_ iq: XMLElement) -> XMLElement? {
        deviceListItems([], answering: iq)
    }

    /// Establishes the session and, for a fresh one, starts setup as the client does.
    func connect(resumed: Bool = false) async throws {
        module.handleSessionEstablished(resumed: resumed)
        if !resumed {
            try await module.handleConnect()
        }
    }

    func setAnswer(_ newAnswer: @escaping Answer) {
        answer.withLock { $0 = newAnswer }
    }

    var statuses: [OMEMOSetupStatus] {
        events.withLock { $0 }
    }

    var generatedDevices: Int {
        draws.withLock { $0 }
    }

    var sent: [XMLElement] {
        sentIQs.withLock { $0 }
    }

    var deviceListReads: Int {
        sent.count(where: isDeviceListRead)
    }

    /// Encryptions and resets parked until the running attempt installs an identity.
    var identityWaiters: Int {
        module.state.withLock { $0.identityWaiters.count }
    }

    /// Callers parked until the connection's first attempt reports.
    var firstAttemptWaiters: Int {
        module.state.withLock { state in
            if case let .pending(waiters) = state.firstAttempt { waiters.count } else { 0 }
        }
    }

    func publishes(to node: String) -> [XMLElement] {
        sent.filter { $0.child(named: "pubsub")?.child(named: "publish")?.attribute("node") == node }
    }
}

private func isDeviceListRead(_ iq: XMLElement) -> Bool {
    iq.attribute("type") == "get" && iq.child(named: "pubsub")?.child(named: "items")?.attribute("node") == XMPPNamespaces.omemoDevices
}

private func publishedDeviceIDs(in publish: XMLElement) -> [String] {
    let item = publish.child(named: "pubsub")?.child(named: "publish")?.child(named: "item")
    return item?.child(named: "devices", namespace: XMPPNamespaces.omemo)?.children(named: "device").compactMap { $0.attribute("id") } ?? []
}

private let waitError = XMPPStanzaError(errorType: .wait, condition: .internalServerError)
private let recipientJID = BareJID(localPart: "peer", domainPart: "example.com")!

/// A persister whose stores are held until `release` is signaled, when one is given, and then report `result`.
private final class StubIdentityPersister: OMEMOIdentityPersisting {
    private let release: AsyncSemaphore?
    private let result: Bool
    private let calls = OSAllocatedUnfairLock<[(deviceID: UInt32, accountID: String)]>(initialState: [])

    init(release: AsyncSemaphore? = nil, result: Bool = true) {
        self.release = release
        self.result = result
    }

    var persisted: [(deviceID: UInt32, accountID: String)] {
        calls.withLock { $0 }
    }

    func persistNewIdentity(_ data: OMEMOModule.OMEMOIdentityData, accountID: String) async -> Bool {
        calls.withLock { $0.append((data.deviceID, accountID)) }
        await release?.wait()
        return result
    }
}

extension OMEMOModuleTests {
    /// Setting up this device's encryption runs beside the session, retries what did not finish, and stops at a refusal
    /// (XEP-0384).
    struct SetupTests {
        // MARK: - Session

        @Test func `A plaintext message goes out while the device-list publish is unanswered`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule)
            let client = XMPPClient(
                domain: "example.com", credentials: .init(username: "user", password: "pass"), transport: mock, requireTLS: false, allowsPLAIN: true
            )
            await client.register(pepModule)
            await client.register(omemoModule)
            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            let read = try await awaitOutgoingIQ(on: mock, type: .get, namespace: XMPPNamespaces.pubsub) { $0.contains(XMPPNamespaces.omemoDevices) }
            await mock.simulateReceive("<iq type=\"result\" id=\"\(read.id)\"/>")
            _ = try await awaitOutgoingIQ(on: mock, type: .set, namespace: XMPPNamespaces.pubsub) { $0.contains(XMPPNamespaces.omemoDevices) }
            try await connectTask.value

            var message = XMPPMessage(type: .chat, to: .bare(recipientJID))
            message.body = "hello"
            try await client.send(message)

            #expect(await mock.sentBytes.contains { String(decoding: $0, as: UTF8.self).contains("<body>hello</body>") })
            await disconnectFast(client)
        }

        // MARK: - Outcomes

        /// A known condition of type cancel, auth or modify refuses the setup and ends the attempts. A wait, an unknown
        /// condition, or an error without one leaves it incomplete for the next attempt.
        @Test(arguments: [
            ("<error type='cancel'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>", OMEMOSetupStatus.refused(.itemNotFound)),
            ("<error type='wait'><internal-server-error xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>", .incomplete),
            ("<error type='cancel'><made-up xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>", .incomplete),
            ("", .incomplete)
        ])
        func `A device-list publish error refuses or leaves the setup incomplete`(error: String, expected: OMEMOSetupStatus) async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            let omemoModule = OMEMOModule(pepModule: pepModule, setupRetryDelays: [.zero])
            try omemoModule.configureIdentity(OMEMO2Fixtures.device("bob").identityData)
            let client = XMPPClient(
                domain: "example.com", credentials: .init(username: "user", password: "pass"), transport: mock, requireTLS: false, allowsPLAIN: true
            )
            await client.register(pepModule)
            await client.register(omemoModule)
            let statuses = SetupStatusRecorder(client: client)
            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            let read = try await awaitOutgoingIQ(on: mock, type: .get, namespace: XMPPNamespaces.pubsub) { $0.contains(XMPPNamespaces.omemoDevices) }
            await mock.simulateReceive("<iq type=\"result\" id=\"\(read.id)\"/>")
            let publish = try await awaitOutgoingIQ(on: mock, type: .set, namespace: XMPPNamespaces.pubsub) { $0.contains(XMPPNamespaces.omemoDevices) }
            await mock.simulateReceive("<iq type=\"error\" id=\"\(publish.id)\">\(error)</iq>")
            try await connectTask.value

            try await eventually { statuses.recorded.first == expected }
            let isRetried: @Sendable () async -> Bool = {
                await mock.sentBytes.count { String(decoding: $0, as: UTF8.self).contains(XMPPNamespaces.omemoDevices) && String(decoding: $0, as: UTF8.self).contains("type=\"get\"") } > 1
            }
            if expected == .incomplete {
                try await eventually { await isRetried() }
            } else {
                try await Task.sleep(for: .milliseconds(200))
                #expect(await !isRetried())
            }
            await disconnectFast(client)
        }

        /// The pruning probe comes once, for the other device on the list, after the bundle publish completed setup.
        @Test func `An incomplete setup is retried at the delays until it completes, and prunes once after`() async throws {
            let failures = OSAllocatedUnfairLock(initialState: 1)
            let harness = try SetupHarness(identity: makeTestOMEMOIdentity(deviceID: 4242, preKeyIDs: [1]).data, delays: [.zero, .zero]) { iq in
                if iq.child(named: "pubsub")?.child(named: "publish") != nil, failures.withLock({ count in
                    defer { count -= 1 }
                    return count > 0
                }) {
                    throw waitError
                }
                return deviceListItems([99], answering: iq)
            }
            try await harness.connect()

            try await eventually { harness.statuses == [.incomplete, .complete] }
            try await eventually { harness.module.state.withLock { $0.ownListTask == nil } }
            let probes = harness.sent.indices.filter {
                harness.sent[$0].attribute("type") == "get" && harness.sent[$0].xmlString.contains(XMPPNamespaces.omemoBundles)
            }
            let lastBundlePublish = try #require(harness.sent.lastIndex {
                $0.child(named: "pubsub")?.child(named: "publish")?.attribute("node") == XMPPNamespaces.omemoBundles
            })
            #expect(probes.count == 1)
            #expect(probes.allSatisfy { $0 > lastBundlePublish })
            #expect(harness.deviceListReads == 2)
        }

        // MARK: - Try Again

        @Test func `Try Again during a retry's wait runs an attempt at once`() async throws {
            let harness = try SetupHarness(identity: makeTestOMEMOIdentity(deviceID: 4242, preKeyIDs: [1]).data, delays: [.seconds(600)]) { _ in
                throw waitError
            }
            try await harness.connect()
            try await eventually { harness.statuses == [.incomplete] }

            harness.setAnswer(SetupHarness.emptyServer)
            #expect(harness.module.retrySetup())

            try await eventually { harness.statuses == [.incomplete, .complete] }
        }

        /// The fresh attempt reads the list only once the attempt it replaced has ended. That attempt's new identity
        /// carries over, so one device is generated, and only the fresh attempt reports.
        @Test func `Try Again during an attempt on a new device waits for it and generates no second device`() async throws {
            let release = AsyncSemaphore()
            let held = OSAllocatedUnfairLock(initialState: true)
            let harness = SetupHarness { iq in
                if isDeviceListRead(iq), held.withLock({ isHeld in
                    defer { isHeld = false }
                    return isHeld
                }) {
                    await release.wait()
                }
                return deviceListItems([], answering: iq)
            }
            try await harness.connect()
            try await eventually { harness.deviceListReads == 1 }

            #expect(harness.module.retrySetup())
            try await Task.sleep(for: .milliseconds(200))
            #expect(harness.deviceListReads == 1)
            await release.signal()

            try await eventually { harness.statuses == [.complete] }
            #expect(harness.generatedDevices == 1)
            #expect(harness.deviceListReads == 2)
            try await Task.sleep(for: .milliseconds(100))
            #expect(harness.statuses == [.complete])
        }

        @Test func `Try Again after the setup completed does nothing`() async throws {
            let harness = SetupHarness()
            try await harness.connect()
            try await eventually { harness.statuses == [.complete] }
            let sentCount = harness.sent.count

            #expect(!harness.module.retrySetup())
            try await Task.sleep(for: .milliseconds(100))
            #expect(harness.sent.count == sentCount)
        }

        // MARK: - First Attempt

        @Test func `Waiting for the first attempt returns once it reported`() async throws {
            let release = AsyncSemaphore()
            let harness = SetupHarness { iq in
                if isDeviceListRead(iq) { await release.wait() }
                return deviceListItems([], answering: iq)
            }
            try await harness.connect()
            let waiter = Task { await harness.module.awaitSetupAttempt(); return harness.statuses }
            try await eventually { harness.firstAttemptWaiters == 1 }
            await release.signal()

            #expect(await waiter.value == [.complete])
        }

        @Test func `Waiting for the first attempt after the connection ended returns at once`() async throws {
            let harness = SetupHarness { iq in
                if isDeviceListRead(iq) { try await Task.sleep(for: .seconds(600)) }
                return nil
            }
            try await harness.connect()
            await harness.module.handleDisconnect()

            await harness.module.awaitSetupAttempt()
            #expect(harness.statuses.isEmpty)
        }

        @Test func `A resumed session with an identity has no first attempt to wait for`() async throws {
            let harness = try SetupHarness(identity: makeTestOMEMOIdentity(deviceID: 4242, preKeyIDs: [1]).data)
            try await harness.connect(resumed: true)

            await harness.module.awaitSetupAttempt()
            #expect(harness.sent.isEmpty)
        }

        @Test func `A resumed session without an identity waits for the attempt the resume asks for`() async throws {
            let harness = SetupHarness()
            try await harness.connect(resumed: true)
            let waiter = Task { await harness.module.awaitSetupAttempt(); return harness.statuses }
            try await eventually { harness.firstAttemptWaiters == 1 }
            #expect(harness.sent.isEmpty)

            #expect(harness.module.retrySetup())
            #expect(await waiter.value == [.complete])
        }

        // MARK: - New Identity

        @Test func `A new identity is stored under the account key before the device list names it`() async throws {
            let release = AsyncSemaphore()
            let persister = StubIdentityPersister(release: release)
            let harness = SetupHarness()
            harness.module.configureIdentityPersister(persister, accountID: "acct-1")
            try await harness.connect()

            try await eventually { persister.persisted.count == 1 }
            #expect(persister.persisted.first?.accountID == "acct-1")
            try await Task.sleep(for: .milliseconds(100))
            #expect(harness.publishes(to: XMPPNamespaces.omemoDevices).isEmpty)
            await release.signal()

            try await eventually { harness.statuses == [.complete] }
            let listPublish = try #require(harness.publishes(to: XMPPNamespaces.omemoDevices).first)
            #expect(publishedDeviceIDs(in: listPublish) == [persister.persisted.first.map { String($0.deviceID) }].compactMap(\.self))
        }

        @Test func `An identity that could not be stored is never used`() async throws {
            let release = AsyncSemaphore()
            let persister = StubIdentityPersister(release: release, result: false)
            let harness = SetupHarness()
            harness.module.configureIdentityPersister(persister, accountID: "acct-1")
            try await harness.connect()
            try await eventually { persister.persisted.count == 1 }

            let send = Task {
                try await harness.module.encryptMessage(plaintext: "secret", to: recipientJID, recipientDeviceIDs: [5], ownDeviceIDs: [])
            }
            try await eventually { harness.identityWaiters == 1 }
            #expect(harness.sent.count == 1)
            await release.signal()

            await #expect(throws: OMEMOModuleError.notSetUp) { try await send.value }
            try await eventually { harness.statuses == [.incomplete] }
            #expect(harness.publishes(to: XMPPNamespaces.omemoDevices).isEmpty)
            #expect(harness.module.ownIdentityData == nil)
        }

        /// The replaced attempt leaves its stored identity to the fresh one, which installs it rather than storing a
        /// second device over it.
        @Test func `An identity stored for a replaced attempt is the one the fresh attempt uses`() async throws {
            let release = AsyncSemaphore()
            let persister = StubIdentityPersister(release: release)
            let harness = SetupHarness()
            harness.module.configureIdentityPersister(persister, accountID: "acct-1")
            try await harness.connect()
            try await eventually { persister.persisted.count == 1 }

            #expect(harness.module.retrySetup())
            await release.signal()

            try await eventually { harness.statuses == [.complete] }
            let stored = try #require(persister.persisted.first)
            #expect(persister.persisted.count == 1)
            #expect(harness.generatedDevices == 1)
            #expect(harness.module.ownIdentityData?.deviceID == stored.deviceID)
            let listPublish = try #require(harness.publishes(to: XMPPNamespaces.omemoDevices).first)
            #expect(publishedDeviceIDs(in: listPublish) == [String(stored.deviceID)])
        }

        // MARK: - Encrypt Gate

        /// A send or reset waits for a timed retry that may create this device, then goes on with what it left.
        @Test(arguments: [true, false])
        func `An encryption or reset during a retry on a new device waits for it`(retrySucceeds: Bool) async throws {
            let release = AsyncSemaphore()
            let reads = OSAllocatedUnfairLock(initialState: 0)
            let harness = SetupHarness(delays: [.zero]) { iq in
                guard isDeviceListRead(iq) else { return nil }
                let read = reads.withLock { count in
                    count += 1
                    return count
                }
                if read == 1 { throw waitError }
                if read == 2 {
                    await release.wait()
                    if !retrySucceeds { throw waitError }
                }
                return deviceListItems([], answering: iq)
            }
            try await harness.connect()
            try await eventually { harness.statuses == [.incomplete] && harness.deviceListReads == 2 }

            let send = Task {
                try await harness.module.encryptMessage(plaintext: "secret", to: recipientJID, recipientDeviceIDs: [5], ownDeviceIDs: [])
            }
            let reset = Task { try await harness.module.resetSession(jid: recipientJID, deviceID: 5) }
            try await eventually { harness.identityWaiters == 2 }
            #expect(harness.sent.count == 2)
            await release.signal()

            if retrySucceeds {
                // Past the identity, the recipient's bundle is asked for, and the stub server has none.
                await #expect(throws: OMEMOModuleError.noUsableRecipientDevices) { try await send.value }
                #expect(try await reset.value == .noBundle)
            } else {
                await #expect(throws: OMEMOModuleError.notSetUp) { try await send.value }
                await #expect(throws: OMEMOModuleError.notSetUp) { try await reset.value }
            }
        }

        /// The connect starts the first attempt on a task of its own, so an encryption can start before that task does.
        @Test func `An encryption started before a new device's first attempt runs waits for it`() async throws {
            let harness = SetupHarness()
            harness.module.handleSessionEstablished(resumed: false)
            let send = Task {
                try await harness.module.encryptMessage(plaintext: "secret", to: recipientJID, recipientDeviceIDs: [5], ownDeviceIDs: [])
            }
            try await eventually { harness.identityWaiters == 1 }

            try await harness.module.handleConnect()

            // Past the identity, the recipient's bundle is asked for, and the stub server has none.
            await #expect(throws: OMEMOModuleError.noUsableRecipientDevices) { try await send.value }
        }

        /// A resumed session has no identity until the attempt the resume asks for installs one, so an encryption
        /// started before that attempt waits for it.
        @Test func `An encryption on a resumed session without an identity waits for the attempt the resume asks for`() async throws {
            let harness = SetupHarness()
            try await harness.connect(resumed: true)
            let send = Task {
                try await harness.module.encryptMessage(plaintext: "secret", to: recipientJID, recipientDeviceIDs: [5], ownDeviceIDs: [])
            }
            try await eventually { harness.identityWaiters == 1 }

            #expect(harness.module.retrySetup())

            // Past the identity, the recipient's bundle is asked for, and the stub server has none.
            await #expect(throws: OMEMOModuleError.noUsableRecipientDevices) { try await send.value }
        }

        /// An encryption after Try Again on a new device waits for the attempt it started, which the test holds.
        @Test func `Try Again on a new device makes encryptions wait for its attempt`() async throws {
            let release = AsyncSemaphore()
            let harness = SetupHarness { _ in throw waitError }
            try await harness.connect()
            try await eventually { harness.statuses == [.incomplete] }
            harness.setAnswer { iq in
                if isDeviceListRead(iq) { await release.wait() }
                return deviceListItems([], answering: iq)
            }

            #expect(harness.module.retrySetup())
            let send = Task {
                try await harness.module.encryptMessage(plaintext: "secret", to: recipientJID, recipientDeviceIDs: [5], ownDeviceIDs: [])
            }
            try await eventually { harness.identityWaiters == 1 }
            await release.signal()

            await #expect(throws: OMEMOModuleError.noUsableRecipientDevices) { try await send.value }
        }

        /// Starting the setup loop closes the gate under the caller's lock, before the attempt's task can run, so an
        /// encryption right after Try Again cannot find it open.
        @Test func `Starting the setup loop closes the encryption gate under the caller's lock`() async throws {
            let harness = SetupHarness { _ in throw waitError }
            try await harness.connect()
            try await eventually { harness.statuses == [.incomplete] }
            #expect(!harness.module.state.withLock { $0.attemptInFlight })

            let (isWaiting, replaced) = harness.module.state.withLock { state in
                let replaced = harness.module.startSetupLoop(&state)
                return (state.attemptInFlight, replaced)
            }
            replaced?.cancel()
            #expect(isWaiting)
        }
    }
}
