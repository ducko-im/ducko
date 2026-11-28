import DuckoCore
import DuckoXMPP
import Foundation
import Logging
import Testing

private let log = Logger(label: "im.ducko.integrationtests.reset")

/// One-shot live-server fixture hygiene suite. Skipped by default; runs only
/// when `DUCKO_RESET_FIXTURES=1` and the standard `IntegrationTests/.env.test`
/// credentials are configured.
///
/// Two server-side drift sources motivate this suite:
///
/// 1. PEP `urn:xmpp:omemo:2:devices` accumulates stale device IDs across
///    runs, and each obsolete device leaves its bundle behind as an item of
///    `urn:xmpp:omemo:2:bundles`. The
///    `TestHarness` bootstrap-reset gate now triggers this OMEMO path
///    automatically when any account exceeds
///    `TestHarness.autoResetDevicelistThreshold` (32) — the env-gated
///    suite remains the manual entry point and is the only way to also
///    run the roster reseed below in one shot. Retracting the devicelist
///    and reconnecting causes `OMEMOModule.ensureOwnDeviceInList` to
///    publish a fresh singleton list containing only the live device ID.
///    Then every other bundle item is retracted, leaving one devicelist and
///    one bundle per account. The legacy OMEMO list
///    `eu.siacs.conversations.axolotl.devicelist` gets the same retract and
///    republish, and every other listed device's
///    `eu.siacs.conversations.axolotl.bundles:<id>` node is deleted, since
///    nothing else prunes them.
///
/// 2. Roster baseline subscriptions can be lost (server retention edges,
///    per-test side effects). UI tests that expect Bob's contact row on
///    Alice fail silently. The reset reseeds `subscription=both` for the
///    canonical pairs (alice ↔ bob, alice ↔ carol) and persists the result
///    by NOT registering removal cleanups. Per `TestCredentials.swift`,
///    Dave must have NO baseline subscription with any other account
///    (`SubscriptionDance.assertNoSubscription` enforces this), so the
///    reset actively scrubs every dave-paired subscription (alice ↔ dave,
///    bob ↔ dave, carol ↔ dave) instead of seeding any of them.
///
/// Invoke with:
///
///     DUCKO_RESET_FIXTURES=1 swift test --package-path IntegrationTests \
///         --filter ResetTestServerState
extension DuckoIntegrationTests {
    struct ResetTestServerState {
        @Test(.enabled(
            if: ProcessInfo.processInfo.environment["DUCKO_RESET_FIXTURES"] == "1"
                && TestCredentials.isAvailable
                && TestCredentials.isDaveAvailable,
            "Set DUCKO_RESET_FIXTURES=1 and configure all four DUCKO_TEST_*_{JID,PASSWORD} pairs"
        ))
        @MainActor func `reset OMEMO devicelists and reseed roster baseline`() async throws {
            let accounts: [TestCredentials.Credential] = [
                TestCredentials.alice,
                TestCredentials.bob,
                TestCredentials.carol,
                TestCredentials.dave
            ]

            for credential in accounts {
                try await Self.resetOMEMODeviceList(for: credential)
            }

            try await Self.reseedRosterBaseline(accounts: accounts)
        }

        // MARK: - OMEMO Devicelist Reset

        /// Retracts `urn:xmpp:omemo:2:devices` and the legacy devicelist for
        /// `credential`, then disconnects and reconnects so
        /// `OMEMOModule.ensureOwnDeviceInList` republishes each as a singleton
        /// list containing only the live device ID. Verifies the
        /// post-reconnect lists are singletons, then retracts every
        /// `urn:xmpp:omemo:2:bundles` item whose id, the device ID, is not the
        /// live one, and deletes the legacy bundle node of every other device
        /// either list named before the retract.
        ///
        /// `skipBootstrap` is passed through to the inner `withHarness` so
        /// the bootstrap-reset gate doesn't re-enter when this is called
        /// from inside `runBootstrapResetIfNeeded`. Defaults to `false` for
        /// the existing manual `DUCKO_RESET_FIXTURES=1` callers.
        @MainActor
        static func resetOMEMODeviceList(
            for credential: TestCredentials.Credential, skipBootstrap: Bool = false
        ) async throws {
            try await TestHarness.withHarness(skipBootstrap: skipBootstrap) { harness in
                try await harness.setUp(accounts: [credential.label: credential])
                // A first registration still running could publish the old list again after the retract.
                try await harness.awaitOMEMOSetup(for: credential.label)
                let account = try #require(harness.accounts[credential.label])
                let listedDeviceIDs = try await Self.awaitLegacyPublication(for: credential, on: harness)

                let pep = try await harness.module(PEPModule.self, for: credential.label)
                for node in [XMPPNamespaces.omemoDevices, XMPPNamespaces.omemoLegacyDeviceList] {
                    do {
                        try await pep.retractItem(node: node, itemID: "current")
                        log.info("Retracted \(node) for \(credential.label)")
                    } catch {
                        // First-time accounts have no node yet; treat as success.
                        log.debug("\(node) retract for \(credential.label) returned \(error) — continuing")
                    }
                }

                await harness.environment.accountService.disconnect(accountID: account.accountID)
                try await harness.environment.accountService.connect(
                    accountID: account.accountID,
                    password: credential.password
                )

                _ = try await account.waitForEvent(matching: { event in
                    if case let .rosterUpdated(update) = event, update.isInitialResponse { return true }
                    return false
                }, timeout: TestTimeout.connect)
                try await harness.awaitOMEMOSetup(for: credential.label)

                // Post-condition: the freshly-published devicelist must be a
                // singleton — exactly the live device ID. Catches a regression
                // where retract+republish leaves prior accumulation in place.
                // The OMEMO devicelist payload root is `<devices xmlns="urn:xmpp:omemo:2">`
                // with one `<device id="…"/>` child per device, so count children
                // directly (matches `OMEMOModule.parseDeviceList`'s shape).
                // Use `try #require` rather than `#expect`: a non-singleton or
                // missing-id state would leave `liveDeviceID` nil and cause
                // the bundle sweep below to retract the just-published live
                // bundle along with the stale ones.
                let pepAfter = try await harness.module(PEPModule.self, for: credential.label)
                let items = try await pepAfter.retrieveItems(node: XMPPNamespaces.omemoDevices, from: nil)
                let devices = items.first?.payload.children(named: "device") ?? []
                try #require(devices.count == 1, "Expected singleton devicelist for \(credential.label), got \(devices.count) entries")
                let liveDeviceID = try #require(devices.first?.attribute("id"), "Singleton devicelist for \(credential.label) is missing the `id` attribute")
                let connectedDeviceID = try #require(
                    await harness.module(OMEMOModule.self, for: credential.label).ownIdentityData?.deviceID,
                    "No OMEMO identity for \(credential.label) after reconnecting"
                )
                try #require(liveDeviceID == String(connectedDeviceID), "The singleton devicelist for \(credential.label) is not the connected device")

                try await Self.retractStaleBundles(
                    for: credential,
                    keeping: liveDeviceID,
                    on: harness
                )
                try await Self.deleteStaleLegacyBundles(
                    for: credential,
                    keeping: connectedDeviceID,
                    listed: listedDeviceIDs,
                    on: harness
                )
            }
        }

        /// Waits until the legacy device list of `credential` names its connected device, then returns the devices on
        /// either of its lists. The legacy publication follows the setup attempt, so until the list names the device
        /// it could still publish the list it read before a retract. Each listed device can own a legacy bundle node,
        /// since a device publishes under its OMEMO 2 id there.
        @MainActor
        private static func awaitLegacyPublication(
            for credential: TestCredentials.Credential,
            on harness: TestHarness
        ) async throws -> Set<UInt32> {
            let omemo = try await harness.module(OMEMOModule.self, for: credential.label)
            let deviceID = try #require(omemo.ownIdentityData?.deviceID, "No OMEMO identity for \(credential.label)")
            _ = try await Self.awaitLegacyListing(of: deviceID, for: credential, on: harness)
            return try await Set(omemo.fetchListedDevices(of: harness.jid(for: credential)))
        }

        /// Polls the legacy device list of `credential` until it names `deviceID`, and returns it.
        @MainActor
        private static func awaitLegacyListing(
            of deviceID: UInt32,
            for credential: TestCredentials.Credential,
            on harness: TestHarness
        ) async throws -> [UInt32] {
            let account = try #require(harness.accounts[credential.label])
            let ownJID = try harness.jid(for: credential)
            let omemo = try await harness.module(OMEMOModule.self, for: credential.label)
            var devices: [UInt32] = []
            try await account.waitForCondition({
                devices = await (try? omemo.fetchDeviceList(for: ownJID, forceRefresh: true, version: .legacy)) ?? []
                return devices.contains(deviceID)
            }, timeout: TestTimeout.omemoSession)
            return devices
        }

        /// Waits for the reconnected device's legacy publication, which follows its setup attempt, and verifies the
        /// republished legacy list is the singleton `liveDeviceID`. Then deletes the
        /// `eu.siacs.conversations.axolotl.bundles:<id>` node of every other device in `listedDeviceIDs`, and asserts
        /// none remains.
        @MainActor
        private static func deleteStaleLegacyBundles(
            for credential: TestCredentials.Credential,
            keeping liveDeviceID: UInt32,
            listed listedDeviceIDs: Set<UInt32>,
            on harness: TestHarness
        ) async throws {
            let legacyDevices = try await Self.awaitLegacyListing(of: liveDeviceID, for: credential, on: harness)
            try #require(legacyDevices == [liveDeviceID], "Expected singleton legacy devicelist for \(credential.label), got \(legacyDevices)")

            let pep = try await harness.module(PEPModule.self, for: credential.label)
            let stale = listedDeviceIDs.subtracting([liveDeviceID]).sorted()
            var deleted = 0
            for deviceID in stale {
                do {
                    try await pep.deleteNode(node: XMPPNamespaces.omemoLegacyBundles(deviceID: deviceID))
                    deleted += 1
                } catch {
                    // Best-effort per node, as the bundle item sweep is: a device on the OMEMO 2 list alone has no
                    // legacy node. The postcondition re-query below catches a node a real failure left behind.
                    log.debug("Legacy bundle node delete \(deviceID) for \(credential.label) returned \(error) — continuing")
                }
            }
            log.info("Deleted \(deleted) stale legacy OMEMO bundle node(s) for \(credential.label)")

            var remaining: [UInt32] = []
            for deviceID in stale where try await Self.legacyBundleExists(of: deviceID, on: pep) {
                remaining.append(deviceID)
            }
            #expect(remaining.isEmpty, "Stale legacy OMEMO bundles still present for \(credential.label) after sweep: \(remaining)")
        }

        /// Whether the legacy bundle node of `deviceID` holds an item. A missing node answers `item-not-found`.
        private static func legacyBundleExists(of deviceID: UInt32, on pep: PEPModule) async throws -> Bool {
            do {
                return try await !pep.retrieveItems(node: XMPPNamespaces.omemoLegacyBundles(deviceID: deviceID)).isEmpty
            } catch let error as XMPPStanzaError where error.condition == .itemNotFound {
                return false
            }
        }

        /// Retracts every `urn:xmpp:omemo:2:bundles` item owned by
        /// `credential` whose id is not `liveDeviceID`. The post-reconnect
        /// bundle for the live device is preserved so OMEMO can resume
        /// immediately after the reset. Asserts no stale bundle remains
        /// after the sweep.
        @MainActor
        static func retractStaleBundles(
            for credential: TestCredentials.Credential,
            keeping liveDeviceID: String,
            on harness: TestHarness
        ) async throws {
            let pep = try await harness.module(PEPModule.self, for: credential.label)

            let stale = try await Self.staleBundleItemIDs(
                in: pep.retrieveItems(node: XMPPNamespaces.omemoBundles, from: nil),
                keeping: liveDeviceID
            )

            var retracted = 0
            for itemID in stale {
                do {
                    try await pep.retractItem(node: XMPPNamespaces.omemoBundles, itemID: itemID)
                    retracted += 1
                } catch {
                    // Best-effort per item: a server-side race or an
                    // already-gone item shouldn't abort the loop. Real
                    // failures (forbidden, feature-not-implemented, repeated
                    // timeouts) are caught by the postcondition re-query
                    // below — they would leave stale items visible.
                    log.debug("Bundle item retract \(itemID) for \(credential.label) returned \(error) — continuing")
                }
            }
            log.info("Retracted \(retracted) stale OMEMO bundle(s) for \(credential.label)")

            let remaining = try await Self.staleBundleItemIDs(
                in: pep.retrieveItems(node: XMPPNamespaces.omemoBundles, from: nil),
                keeping: liveDeviceID
            )
            #expect(remaining.isEmpty, "Stale OMEMO bundles still present for \(credential.label) after sweep: \(remaining)")
        }

        /// The ids of the bundle items that are not the live device's.
        /// Shared by the sweep loop and its postcondition re-query so the
        /// two definitions of "stale" cannot drift.
        static func staleBundleItemIDs(in items: [PEPItem], keeping liveDeviceID: String) -> [String] {
            items.map(\.id).filter { $0 != liveDeviceID }
        }

        // MARK: - Roster Baseline Reseed

        /// Seeds `subscription='both'` for the canonical pairs (alice ↔ bob,
        /// alice ↔ carol) and scrubs every dave-paired subscription so dave
        /// stays empty per `TestCredentials.alice` documentation; both outcomes
        /// persist after teardown because no removal cleanup is registered.
        /// `SubscriptionDance.assertNoSubscription` enforces the dave-empty
        /// invariant at test time; an interrupted prior run can leave a stale
        /// alice/bob/carol entry on dave, so the scrubs run unconditionally
        /// and tolerate "already absent".
        @MainActor
        private static func reseedRosterBaseline(accounts: [TestCredentials.Credential]) async throws {
            try await TestHarness.withHarness { harness in
                let labelled = Dictionary(uniqueKeysWithValues: accounts.map { ($0.label, $0) })
                try await harness.setUp(accounts: labelled)

                for peer in [TestCredentials.bob, TestCredentials.carol] {
                    try await Self.setUpMutualSubscription(
                        first: TestCredentials.alice,
                        second: peer,
                        on: harness
                    )
                }

                for other in [TestCredentials.alice, TestCredentials.bob, TestCredentials.carol] {
                    try await Self.scrubSubscription(
                        first: other,
                        second: TestCredentials.dave,
                        on: harness
                    )
                }
            }
        }

        /// Idempotently removes any roster subscription between `first` and
        /// `second` from both sides, then asserts both rosters are clean via
        /// `SubscriptionDance.assertNoSubscription`. The per-side `try?`
        /// swallows the `item-not-found` IQ the server returns when an entry
        /// is already absent; the post-scrub assertion catches the case where
        /// `removeContact` swallowed a non-`item-not-found` error and left a
        /// stale entry — without it the reset would report success while
        /// leaving the baseline inconsistent.
        @MainActor
        private static func scrubSubscription(
            first: TestCredentials.Credential,
            second: TestCredentials.Credential,
            on harness: TestHarness
        ) async throws {
            let firstEndpoint = try await SubscriptionEndpoint.resolve(credential: first, on: harness)
            let secondEndpoint = try await SubscriptionEndpoint.resolve(credential: second, on: harness)

            try? await firstEndpoint.roster.removeContact(jid: secondEndpoint.jid)
            try? await secondEndpoint.roster.removeContact(jid: firstEndpoint.jid)

            try await SubscriptionDance.assertNoSubscription(harness: harness, first: first, second: second)

            log.info("Scrubbed any subscription between \(first.label) and \(second.label)")
        }

        /// Runs a bidirectional subscription dance so both endpoints end up
        /// with `subscription='both'` for each other. Mirrors
        /// `setUpBobSubscribedToAlice` (PresenceTests.swift) but runs the
        /// dance in both directions and registers no removal cleanup, so the
        /// seeded subscriptions persist on the live server.
        @MainActor
        private static func setUpMutualSubscription(
            first: TestCredentials.Credential,
            second: TestCredentials.Credential,
            on harness: TestHarness
        ) async throws {
            let firstEndpoint = try await SubscriptionEndpoint.resolve(credential: first, on: harness)
            let secondEndpoint = try await SubscriptionEndpoint.resolve(credential: second, on: harness)

            try await SubscriptionDance.subscribeAndApproveInHarness(
                requester: secondEndpoint,
                approver: firstEndpoint
            )
            try await SubscriptionDance.subscribeAndApproveInHarness(
                requester: firstEndpoint,
                approver: secondEndpoint
            )

            log.info("Reseeded subscription=both between \(first.label) and \(second.label)")
        }
    }
}
