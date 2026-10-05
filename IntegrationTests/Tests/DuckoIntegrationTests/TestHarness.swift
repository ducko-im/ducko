import DuckoCore
import DuckoXMPP
import Foundation
import Logging
import Testing

private let log = Logger(label: "im.ducko.integrationtests.harness")

/// Lifecycle owner for an integration test: a single shared `AppEnvironment`,
/// per-account event streams, and LIFO cleanup actions.
///
/// Use `TestHarness.withHarness { harness in ... }` to guarantee teardown runs
/// in both success and failure paths (Swift `defer` cannot await).
@MainActor
final class TestHarness {
    let environment: AppEnvironment
    private(set) var accounts: [String: ConnectedAccount] = [:]

    private let router: EventRouter
    private let tempDir: URL
    private let omemoStore: any OMEMOStore
    private var cleanupActions: [@Sendable () async -> Void] = []

    private init(environment: AppEnvironment, router: EventRouter, tempDir: URL, omemoStore: any OMEMOStore) {
        self.environment = environment
        self.router = router
        self.tempDir = tempDir
        self.omemoStore = omemoStore
    }

    // MARK: - Bootstrap-Reset Gate

    /// Process-wide once-gate that runs `runBootstrapResetIfNeeded` before
    /// the first `withHarness` invocation. An async actor (not a `static
    /// let`-style once trick) so the body can await network I/O without
    /// blocking the MainActor.
    actor BootstrapResetGate {
        private enum State {
            case idle
            case running(Task<Void, Error>)
            case done
            case failed(any Error)
        }

        private var state: State = .idle

        func ensure(_ body: @Sendable @escaping () async throws -> Void) async throws {
            switch state {
            case .done:
                return
            case let .failed(error):
                // Bootstrap is infra-fatal — a failed bootstrap means
                // tests would run against undefined server state. Rethrow
                // on every subsequent call rather than silently retrying.
                throw error
            case let .running(task):
                try await task.value
            case .idle:
                let task = Task<Void, Error> { try await body() }
                state = .running(task)
                do {
                    try await task.value
                    state = .done
                } catch {
                    state = .failed(error)
                    throw error
                }
            }
        }
    }

    static let bootstrapResetGate = BootstrapResetGate()

    /// Threshold (per account) of PEP devicelist entries beyond which the
    /// bootstrap reset fires. Historical accumulation went to 400+ before
    /// the captured-identity fixture path landed; expected steady-state
    /// growth with fixtures is ≤ 1 device per process per account, so at
    /// 32 the auto-reset fires at most once every ~128 process runs
    /// across four accounts. Cost when it fires: ~102 s once.
    static let autoResetDevicelistThreshold = 32

    /// Per-probe timeout used by the bootstrap to detect a hung server
    /// without blocking test startup. A timeout logs a warning and the
    /// gate bails without firing the reset path.
    static let bootstrapProbeTimeout: Duration = .seconds(10)

    /// Builds a raw `XMPPClient` for `credential`, connects with TLS, fetches
    /// the OMEMO devicelist via PEP, parses the `<device id="…"/>` children,
    /// and returns the count. Used by the bootstrap-reset gate to measure
    /// accumulation per account without standing up a full `AppEnvironment`.
    /// Returns `nil` on probe failure so the caller can bail without
    /// blocking test startup.
    @MainActor
    static func probeOMEMODevicelistCount(
        for credential: TestCredentials.Credential,
        timeout: Duration = bootstrapProbeTimeout
    ) async -> Int? {
        guard let jid = BareJID.parse(credential.jid),
              let username = jid.localPart else { return nil }
        var builder = XMPPClientBuilder(
            domain: jid.domainPart, username: username, password: credential.password
        )
        builder.withPreferredResource("ducko-bootstrap-probe-\(UUID().uuidString.prefix(8))")
        let pepModule = PEPModule()
        builder.withModule(pepModule)
        let client = await builder.build()
        defer { Task { await client.disconnect() } }
        do {
            try await client.connect()
            try await Self.waitForRawEvent(in: client.events, timeout: timeout) { event in
                if case .connected = event { return true }
                return false
            }
            let items = try await pepModule.retrieveItems(node: XMPPNamespaces.omemoDevices, from: nil)
            let devices = items.first?.payload.children(named: "device") ?? []
            return devices.count
        } catch {
            log.warning("OMEMO bootstrap probe for \(credential.label) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Bootstrap body for the auto-reset gate. Probes each available
    /// credential's PEP devicelist count, and if any account is over
    /// `autoResetDevicelistThreshold` triggers the same reset
    /// `ResetTestServerState` runs manually for OMEMO.
    @MainActor
    static func runBootstrapResetIfNeeded(
        probe: @MainActor @Sendable (TestCredentials.Credential) async -> Int? = { credential in
            await TestHarness.probeOMEMODevicelistCount(for: credential)
        },
        reset: @MainActor @Sendable (TestCredentials.Credential) async throws -> Void = { credential in
            try await DuckoIntegrationTests.ResetTestServerState.resetOMEMODeviceList(
                for: credential, skipBootstrap: true
            )
        }
    ) async throws {
        guard TestCredentials.isAvailable else { return }

        var credentials: [TestCredentials.Credential] = [
            TestCredentials.alice,
            TestCredentials.bob,
            TestCredentials.carol
        ]
        if TestCredentials.isDaveAvailable {
            credentials.append(TestCredentials.dave)
        }

        // Refuse to run reset on misconfigured creds aimed at a wrong server.
        for credential in credentials {
            guard let jid = BareJID.parse(credential.jid) else {
                log.warning("OMEMO bootstrap: malformed credential JID for \(credential.label), skipping reset")
                return
            }
            guard jid.domainPart == TestCredentials.testServerDomain else {
                log.warning("OMEMO bootstrap: credential \(credential.label) domain \(jid.domainPart) does not match expected \(TestCredentials.testServerDomain); skipping reset")
                return
            }
        }

        var overThreshold = false
        for credential in credentials {
            guard let count = await probe(credential) else {
                log.warning("OMEMO bootstrap probe inconclusive for \(credential.label); skipping reset")
                return
            }
            if count > autoResetDevicelistThreshold {
                log.info("OMEMO bootstrap: \(credential.label) devicelist count \(count) exceeds threshold, reset will fire")
                overThreshold = true
            }
        }

        guard overThreshold else { return }
        for credential in credentials {
            try await reset(credential)
        }
    }

    // MARK: - Lifecycle

    /// Runs `body` with a fresh harness, awaiting teardown on both success and failure paths.
    static func withHarness(_ body: (TestHarness) async throws -> Void) async throws {
        try await withHarness(skipBootstrap: false, body)
    }

    /// Private variant that lets the bootstrap path itself call back through
    /// `withHarness` without re-entering the once-gate. Public callers go
    /// through the default-argument form above.
    static func withHarness(
        skipBootstrap: Bool,
        _ body: (TestHarness) async throws -> Void
    ) async throws {
        if !skipBootstrap {
            try await bootstrapResetGate.ensure {
                try await TestHarness.runBootstrapResetIfNeeded()
            }
        }
        let router = EventRouter()
        let bundle = try TestEnvironmentFactory.makeEnvironment { event, accountID in
            MainActor.assumeIsolated {
                router.dispatch(event, accountID: accountID)
            }
        }
        // Bookmarks auto-join would re-enter every test account's stored rooms on
        // connect, polluting the smoke tests' event streams with unrelated joins.
        bundle.environment.bookmarksService.autoJoinEnabled = false

        let harness = TestHarness(
            environment: bundle.environment,
            router: router,
            tempDir: bundle.tempDirectory,
            omemoStore: bundle.omemoStore
        )
        do {
            try await body(harness)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    /// Creates and connects every account in `labels`, waiting for initial roster response
    /// before returning. Cleanup for each successful account is registered immediately.
    ///
    /// `loadOMEMOFixtures` gates the OMEMO identity fixture seed + capture path.
    /// Default `true`: every connect reuses the captured identity so the
    /// account's PEP devicelist stays singleton instead of accumulating one
    /// fresh device per test run. Without this, ~50 protocol-test connects
    /// per suite run push every account past `OMEMOModule.pruneProbeCap = 64`,
    /// which then SIGABRTs the encrypt path on the next suite under bundle
    /// fetch fan-out. The `captureOMEMOFixture` poll is paid only once per
    /// account on a brand-new dev/CI machine; subsequent runs are a 50 KB
    /// file read.
    ///
    /// An account whose label is in `endpoints` connects to that host and port instead of resolving its domain.
    func setUp(
        accounts labels: [String: TestCredentials.Credential],
        endpoints: [String: (host: String, port: Int)] = [:],
        loadOMEMOFixtures: Bool = true
    ) async throws {
        // Sort by label so connect order is deterministic across runs.
        for (label, credential) in labels.sorted(by: { $0.key < $1.key }) {
            let endpoint = endpoints[label]
            let accountID = try await environment.accountService.createAccount(
                jidString: credential.jid, host: endpoint?.host, port: endpoint?.port
            )

            // Populate the account cache before feature services handle connection events.
            try await environment.accountService.loadAccounts()

            // Seed a previously-captured OMEMO identity, if one exists, before
            // the client is built — `OMEMOService.buildModule` only sees identity
            // data that is already present in the store at connect time.
            if loadOMEMOFixtures {
                _ = try? await loadOMEMOFixture(for: credential)
            }

            do {
                try await environment.accountService.connect(accountID: accountID, password: credential.password)
            } catch {
                await environment.accountService.disconnect(accountID: accountID)
                try? await environment.accountService.deleteAccount(accountID)
                throw error
            }
            // Skip savePassword — writing live credentials to the temp
            // FileCredentialStore would leave plaintext secrets on disk.

            let connected = ConnectedAccount(accountID: accountID, router: router)
            accounts[label] = connected

            // Register cleanup before waiting for the roster so a hang here still
            // triggers full teardown via the LIFO chain.
            addCleanup { [environment] in
                await environment.accountService.disconnect(accountID: accountID)
            }

            _ = try await connected.waitForEvent(
                matching: { event in
                    if case let .rosterUpdated(update) = event, update.isInitialResponse { return true }
                    return false
                },
                timeout: TestTimeout.connect
            )

            // Capture the freshly-generated OMEMO identity to disk for reuse by
            // subsequent test runs. No-op when a well-formed fixture is already
            // present; overwrites a malformed one.
            if loadOMEMOFixtures {
                try? await captureOMEMOFixture(for: credential)
            }
        }
    }

    /// Appends a cleanup action; actions run in reverse order during teardown.
    func addCleanup(_ action: @escaping @Sendable () async -> Void) {
        cleanupActions.append(action)
    }

    /// Polls until `accounts[label]`'s connection state becomes `.disconnected`.
    func waitUntilDisconnected(_ label: String, timeout: Duration = TestTimeout.event) async throws {
        let account = try #require(accounts[label])
        try await account.waitForCondition({
            if case .disconnected = self.environment.accountService.connectionStates[account.accountID] {
                return true
            }
            return false
        }, timeout: timeout)
    }

    /// Creates an ephemeral MUC room owned by `label` and registers destroy + leave cleanup.
    /// The room JID is randomized so concurrent test runs do not collide.
    ///
    /// Routes through `ChatService.joinRoom` so the service-level conversation
    /// bookkeeping (group conversation row, participant tracking) happens too.
    /// For protocol-level tests that need direct `MUCModule` access, use
    /// ``joinRoom`` instead.
    func createEphemeralRoom(using label: String = "alice") async throws -> BareJID {
        let randomLocal = "inttest-\(UUID().uuidString.prefix(8))"
        let roomJID = try #require(BareJID.parse("\(randomLocal)@\(TestCredentials.mucService)"))
        let account = try #require(accounts[label])

        // ChatService.joinRoom silently returns if the client is missing, which would
        // make the subsequent waitForEvent hang until timeout instead of failing fast.
        guard case .connected = environment.accountService.connectionStates[account.accountID] else {
            throw TestHarnessError.notConnected(label: label)
        }

        try await environment.chatService.joinRoom(jid: roomJID, nickname: label, accountID: account.accountID)

        // Register cleanup before waiting for `.roomJoined` so a wait timeout or
        // stream error still destroys the server-side room instead of leaking it.
        let accountID = account.accountID
        addCleanup { [environment] in
            do {
                try await environment.chatService.destroyRoom(jidString: roomJID.description, reason: nil, accountID: accountID)
            } catch {
                // Owner-only destroy can fail if the account lost privilege; fall back
                // to leaving the room so the test occupant doesn't linger server-side.
                try? await environment.chatService.leaveRoom(jid: roomJID, accountID: accountID)
            }
        }

        let joinEvent = try await account.waitForEvent(
            matching: { event in
                if case let .roomJoined(joinedRoom, _, _) = event, joinedRoom == roomJID { return true }
                return false
            },
            timeout: TestTimeout.event
        )

        // Accept default config for newly created rooms so they are unlocked for
        // other occupants. Without this, the room stays in a "locked" state (MUC
        // status 201) and rejects join attempts from non-owners.
        if case let .roomJoined(_, _, isNewlyCreated) = joinEvent, isNewlyCreated {
            let mucModule = try await module(MUCModule.self, for: label)
            try await mucModule.acceptDefaultConfig(roomJID)
        }

        return roomJID
    }

    /// Builds and connects a standalone `XMPPClient` (one not managed by
    /// `AccountService`) for raw-module tests, registers a disconnect
    /// cleanup, and waits for `.connected`.
    ///
    /// Use this when a test needs a second resource, custom module stack, or
    /// direct `client.events` access — the harness-managed clients route
    /// events through `AccountService` and aren't available standalone.
    func buildStandaloneClient(
        for credential: TestCredentials.Credential,
        resource: String,
        modules: [any XMPPModule] = [],
        interceptors: [any StanzaInterceptor] = [],
        timeout: Duration = TestTimeout.connect
    ) async throws -> XMPPClient {
        let jid = try #require(BareJID.parse(credential.jid))
        let username = try #require(jid.localPart)

        var builder = XMPPClientBuilder(domain: jid.domainPart, username: username, password: credential.password)
        builder.withPreferredResource(resource)
        for interceptor in interceptors {
            builder.withInterceptor(interceptor)
        }
        for module in modules {
            builder.withModule(module)
        }
        let client = await builder.build()

        addCleanup { await client.disconnect() }
        try await client.connect()

        try await Self.waitForRawEvent(in: client.events, timeout: timeout) { event in
            if case .connected = event { return true }
            return false
        }

        return client
    }

    /// Joins `roomJID` via the MUCModule of the account registered under
    /// `label`, registers leaveRoom cleanup, and awaits `.roomJoined`.
    /// Returns the module so callers can chain further direct-module
    /// operations, and the join event so callers can inspect the join
    /// snapshot (e.g. existing occupants).
    ///
    /// Routes through `MUCModule` directly (no service-level bookkeeping).
    /// For service-layer tests that need a newly-created room, use
    /// ``createEphemeralRoom`` instead.
    @discardableResult
    func joinRoom(
        _ roomJID: BareJID,
        as nickname: String,
        using label: String,
        password: String? = nil,
        timeout: Duration = TestTimeout.event
    ) async throws -> (module: MUCModule, joinEvent: XMPPEvent) {
        let account = try #require(accounts[label])
        guard case .connected = environment.accountService.connectionStates[account.accountID] else {
            throw TestHarnessError.notConnected(label: label)
        }
        let mucModule = try await module(MUCModule.self, for: label)

        try await mucModule.joinRoom(roomJID, nickname: nickname, password: password)

        // Register cleanup before waiting for `.roomJoined` so a wait timeout
        // or stream error still leaves the room instead of leaking the occupant.
        addCleanup { try? await mucModule.leaveRoom(roomJID) }

        let joinEvent = try await account.waitForEvent(
            matching: { event in
                if case let .roomJoined(joinedRoom, _, _) = event, joinedRoom == roomJID { return true }
                return false
            },
            timeout: timeout
        )
        return (mucModule, joinEvent)
    }

    // MARK: - Module/JID Lookup

    /// Returns the registered XMPP module of type `M` on the account registered
    /// under `label`, or throws if the account is not connected or the module
    /// is not installed on its client.
    ///
    /// Mirrors the `guard let account = try #require(accounts[label]); guard ...
    /// else { throw .notConnected }` pattern used by `joinRoom` and
    /// `waitUntilDisconnected` in this file so all three harness lookups fail
    /// through `TestHarnessError` rather than splitting between `#require` and
    /// thrown errors for different misconfiguration modes.
    func module<M: XMPPModule>(_ type: M.Type, for label: String) async throws -> M {
        guard let account = accounts[label] else {
            throw TestHarnessError.notConnected(label: label)
        }
        guard let client = environment.accountService.client(for: account.accountID) else {
            throw TestHarnessError.notConnected(label: label)
        }
        guard let module = await client.module(ofType: type) else {
            throw TestHarnessError.moduleUnavailable(label: label, type: String(describing: type))
        }
        return module
    }

    /// Parses a `TestCredentials.Credential`'s JID string into a `BareJID`,
    /// using `#require` to fail fast on a malformed credential.
    func jid(for credential: TestCredentials.Credential) throws -> BareJID {
        try #require(BareJID.parse(credential.jid))
    }

    // MARK: - OMEMO Fixtures

    /// Seeds the harness's in-memory OMEMO store from a previously-captured
    /// identity fixture resolved via `fixtureURL(for:)`. Returns `true` on a
    /// successful seed, `false` if the fixture is missing, unreadable,
    /// malformed, or fails shape invariants (production code then generates a
    /// fresh identity on connect).
    private func loadOMEMOFixture(for credential: TestCredentials.Credential) async throws -> Bool {
        let fixtureURL = Self.fixtureURL(for: credential.label)
        guard let data = try? Data(contentsOf: fixtureURL) else { return false }
        guard let fixture = try? JSONDecoder().decode(FixtureOMEMOIdentity.self, from: data) else {
            log.warning("OMEMO fixture for \(credential.label) is malformed; ignoring and allowing fresh identity generation")
            return false
        }
        guard fixture.passesShapeInvariants else {
            log.warning("OMEMO fixture for \(credential.label) is malformed; ignoring and allowing fresh identity generation")
            return false
        }
        // Refuse to seed identity material that was captured for a different
        // JID — silent reuse across accounts would mask a renamed/recycled
        // fixture file.
        if !Self.fixtureJIDMatchesCredential(fixture.accountJID, credentialJID: credential.jid) {
            log.warning("OMEMO fixture for \(credential.label) was captured for a different JID; ignoring and allowing fresh identity generation")
            return false
        }

        let identity = OMEMOStoredIdentity(
            accountJID: credential.jid,
            deviceID: fixture.deviceID,
            identityKeyData: Data(fixture.identityKeyRaw),
            registrationID: 0
        )
        try await omemoStore.saveIdentity(identity)

        let preKeys = fixture.preKeys.map {
            OMEMOStoredPreKey(
                accountJID: credential.jid, keyID: $0.keyID,
                keyData: Data($0.keyRaw), isUsed: $0.isUsed
            )
        }
        try await omemoStore.savePreKeys(preKeys)

        let signedPreKey = OMEMOStoredSignedPreKey(
            accountJID: credential.jid,
            keyID: fixture.signedPreKeyID,
            keyData: Data(fixture.signedPreKeyRaw),
            signature: Data(fixture.signedPreKeySignature),
            timestamp: Date()
        )
        try await omemoStore.saveSignedPreKey(signedPreKey)

        return true
    }

    /// Captures the freshly-generated OMEMO identity for `credential` to the
    /// path resolved by `fixtureURL(for:)` so later runs can reuse it via
    /// `loadOMEMOFixture`. Writes only when the encoded bytes differ from
    /// the on-disk file: idempotent runs stay byte-stable (no spurious git
    /// diffs in CI), but a test that consumes prekeys flips an `isUsed`
    /// flag, the encoded bytes diverge from disk, and the fixture is
    /// rewritten. A malformed fixture is also overwritten and logged.
    ///
    /// `OMEMOService.handleConnected` persists identity, prekeys, and signed
    /// prekey via a detached task that outlives initial roster response, so this method
    /// polls `loadSignedPreKey` (the last of the three writes) before reading
    /// the store back. A timeout here logs a warning and returns — the next
    /// run regenerates.
    private func captureOMEMOFixture(for credential: TestCredentials.Credential) async throws {
        let fixtureURL = Self.fixtureURL(for: credential.label)
        // Distinguish "file not present" (continue and write fresh) from
        // "file present but unreadable" (bail rather than clobber). A
        // transient I/O error reading a well-formed fixture must not result
        // in silently overwriting it on disk.
        let fileExists = FileManager.default.fileExists(atPath: fixtureURL.path)
        let existing: Data?
        if fileExists {
            do {
                existing = try Data(contentsOf: fixtureURL)
            } catch {
                log.warning("OMEMO fixture for \(credential.label) at \(fixtureURL.path) is present but unreadable (\(error.localizedDescription)); skipping capture to avoid clobbering it")
                return
            }
        } else {
            existing = nil
        }
        let existingDecoded = existing.flatMap { try? JSONDecoder().decode(FixtureOMEMOIdentity.self, from: $0) }
        let existingIsMalformed = existing != nil && existingDecoded?.passesShapeInvariants != true
        // Refuse to overwrite a well-formed fixture whose accountJID disagrees
        // with the credential — `loadOMEMOFixture` already rejected it as a
        // mismatch and let connect generate fresh material; silently writing
        // the new identity over the existing file would permanently destroy
        // the original-account fixture without warning.
        if let existingDecoded,
           existingDecoded.passesShapeInvariants,
           !Self.fixtureJIDMatchesCredential(existingDecoded.accountJID, credentialJID: credential.jid) {
            log.warning("OMEMO fixture for \(credential.label) at \(fixtureURL.path) was captured for a different JID; preserving existing file. Move or delete it manually if you intend to reuse the path for \(credential.jid).")
            return
        }

        guard let fixture = try await buildFixture(for: credential) else { return }
        let encoded = try Self.encodeFixture(fixture)

        // Idempotency guard: if the on-disk bytes already match the fixture we
        // would write, skip the write. Idempotent test runs stay byte-stable
        // (no spurious git diffs in CI), but a test that consumes prekeys —
        // flipping their `isUsed` flags in memory — will diff against the
        // on-disk copy and trigger a rewrite.
        if existing == encoded {
            log.debug("OMEMO fixture for \(credential.label) unchanged; skipping write at \(fixtureURL.path)")
            return
        }

        try writeFixture(encoded, to: fixtureURL)
        if existingIsMalformed {
            log.info("Overwrote malformed OMEMO fixture for \(credential.label) at \(fixtureURL.path)")
        } else {
            log.debug("OMEMO fixture for \(credential.label) changed; wrote at \(fixtureURL.path)")
        }
    }

    /// Builds a `FixtureOMEMOIdentity` from the OMEMO store after polling the
    /// detached persistence task. Returns `nil` when the store has not
    /// finished writing within 10s — the next run will regenerate.
    private func buildFixture(
        for credential: TestCredentials.Credential
    ) async throws -> FixtureOMEMOIdentity? {
        guard await waitForSignedPreKey(for: credential) else {
            log.warning("OMEMO signed prekey for \(credential.label) did not land in store within 10s; skipping fixture capture")
            return nil
        }
        guard let storedIdentity = try await omemoStore.loadIdentity(for: credential.jid) else {
            log.warning("OMEMO identity for \(credential.label) missing at capture time; skipping fixture capture")
            return nil
        }
        let storedPreKeys = try await omemoStore.loadPreKeys(for: credential.jid)
        guard let storedSignedPreKey = try await omemoStore.loadSignedPreKey(for: credential.jid) else {
            log.warning("OMEMO signed prekey for \(credential.label) missing at capture time; skipping fixture capture")
            return nil
        }
        return FixtureOMEMOIdentity(
            deviceID: storedIdentity.deviceID,
            identityKeyRaw: Array(storedIdentity.identityKeyData),
            signedPreKeyID: storedSignedPreKey.keyID,
            signedPreKeyRaw: Array(storedSignedPreKey.keyData),
            signedPreKeySignature: Array(storedSignedPreKey.signature),
            preKeys: Self.sortedFixturePreKeys(storedPreKeys),
            accountJID: credential.jid
        )
    }

    /// Writes the encoded fixture to disk with owner-only directory and file
    /// permissions so the long-term identity keys don't land at the umask
    /// default (0755/0644) on multi-user hosts.
    private func writeFixture(_ encoded: Data, to fixtureURL: URL) throws {
        let directory = fixtureURL.deletingLastPathComponent()
        try FileManager.default.createOwnerOnlyDirectory(at: directory)
        try encoded.writeOwnerOnly(to: fixtureURL)
    }

    /// Deterministic JSON encoding for `FixtureOMEMOIdentity`. Used both for
    /// writing the fixture and for the on-disk-vs-in-memory diff in
    /// `captureOMEMOFixture` — both sides must agree on key ordering and
    /// formatting, otherwise a byte-stable run would false-positive the diff.
    /// Pretty-printed JSON honors `OMEMOFixtureFormat`'s "visible to the
    /// naked eye when inspecting fixture drift" docstring.
    nonisolated static func encodeFixture(_ fixture: FixtureOMEMOIdentity) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(fixture)
    }

    /// Per-keyID-sorted serialization of stored prekeys, matching
    /// `captureOMEMOFixture`'s in-memory-side serialization. Exposed so unit
    /// tests can assert byte-stability without driving the whole capture flow.
    nonisolated static func sortedFixturePreKeys(
        _ storedPreKeys: [OMEMOStoredPreKey]
    ) -> [FixtureOMEMOIdentity.PreKey] {
        storedPreKeys
            .sorted { $0.keyID < $1.keyID }
            .map { FixtureOMEMOIdentity.PreKey(keyID: $0.keyID, keyRaw: Array($0.keyData), isUsed: $0.isUsed) }
    }

    /// Treats a missing (legacy) `captured` as a match (legacy fixtures
    /// pre-date the field and load until rewritten). When present, compares
    /// as parsed `BareJID` so localpart/domainpart case normalization doesn't
    /// trigger a spurious mismatch.
    nonisolated static func fixtureJIDMatchesCredential(_ captured: String?, credentialJID: String) -> Bool {
        guard let captured else { return true }
        return BareJID.parse(captured) == BareJID.parse(credentialJID)
    }

    /// Polls the OMEMO store for `credential`'s signed-prekey up to 10 s.
    /// Presence of the signed prekey proves the identity + prekeys writes
    /// already landed, since `OMEMOService.handleConnected` persists them in
    /// that order.
    ///
    /// Mirrors `DuckoCore.pollUntil`'s contract — cooperatively cancellable
    /// and does one final probe after the deadline to catch a signed-prekey
    /// write that landed between the last in-loop probe and the deadline.
    private func waitForSignedPreKey(for credential: TestCredentials.Credential) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            if await hasSignedPreKey(for: credential) { return true }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return false
            }
        }
        if Task.isCancelled { return false }
        return await hasSignedPreKey(for: credential)
    }

    private func hasSignedPreKey(for credential: TestCredentials.Credential) async -> Bool {
        do {
            return try await omemoStore.loadSignedPreKey(for: credential.jid) != nil
        } catch {
            // Keep polling on transient errors. A persistent store error would
            // timeout the 10s budget; surfacing it at debug helps diagnose
            // "fixtures never capture" cases without coupling test-harness
            // logs to every transient read.
            log.debug("OMEMO signed-prekey probe for \(credential.label) threw: \(error)")
            return false
        }
    }

    /// Resolves `~/Library/Application Support/Ducko-IntegrationTests/omemo/<label>.json`.
    ///
    /// Long-term OMEMO identity keys live outside the working tree — a
    /// `.gitignore` regression, `git clean`, or accidental `git add -f`
    /// inside the worktree cannot leak fixture contents into the repo.
    /// The path is process-specific but deterministic across runs on the
    /// same machine, so the identity-reuse invariant holds without risk
    /// of checked-in private keys.
    private static func fixtureURL(for label: String) -> URL {
        let root: URL = if let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) {
            support
        } else {
            // Fall back to the temp directory when Application Support is
            // unavailable (e.g. sandboxed CI). The fixture still stays out
            // of the repo.
            FileManager.default.temporaryDirectory
        }
        return root
            .appendingPathComponent("Ducko-IntegrationTests", isDirectory: true)
            .appendingPathComponent("omemo", isDirectory: true)
            .appendingPathComponent("\(label).json")
    }

    // MARK: - Teardown

    private func tearDown() async {
        // Run cleanups first so any action that awaits a server response can still
        // receive its event through the router. Finish continuations only after.
        for action in cleanupActions.reversed() {
            await runIntegrationCleanup(action, timeout: .seconds(5), label: "Harness")
        }
        cleanupActions.removeAll()

        router.cancelAllWaiters()
        accounts.removeAll()

        // Cancel and bounded-await the fire-and-forget service tasks before removing tempDir,
        // so a MAM-sync or Jingle task can't race the directory teardown.
        await environment.shutdown(within: .seconds(5))

        do {
            try FileManager.default.removeItem(at: tempDir)
        } catch {
            log.warning("Failed to remove temp directory \(tempDir.path): \(error.localizedDescription)")
        }
    }

    /// Races an event predicate against a timeout on a raw `AsyncStream<XMPPEvent>`.
    /// Throws `TestHarnessError.timeout` if the event does not arrive in time.
    static func waitForRawEvent(
        in events: AsyncStream<XMPPEvent>,
        timeout: Duration = TestTimeout.event,
        matching predicate: @Sendable @escaping (XMPPEvent) -> Bool
    ) async throws {
        let found = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in events where predicate(event) {
                    return true
                }
                return false
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        if !found {
            throw TestHarnessError.timeout
        }
    }
}
