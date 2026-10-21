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
///    one bundle per account.
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

        /// Retracts `urn:xmpp:omemo:2:devices` for `credential`, then
        /// disconnects and reconnects so `OMEMOModule.ensureOwnDeviceInList`
        /// republishes a singleton list containing only the live device ID.
        /// Verifies the post-reconnect list is a singleton, then retracts
        /// every `urn:xmpp:omemo:2:bundles` item whose id, the device ID, is
        /// not the live one.
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

                let pep = try await harness.module(PEPModule.self, for: credential.label)
                do {
                    try await pep.retractItem(node: XMPPNamespaces.omemoDevices, itemID: "current")
                    log.info("Retracted OMEMO devicelist for \(credential.label)")
                } catch {
                    // First-time accounts have no node yet; treat as success.
                    log.debug("OMEMO devicelist retract for \(credential.label) returned \(error) — continuing")
                }

                let account = try #require(harness.accounts[credential.label])
                await harness.environment.accountService.disconnect(accountID: account.accountID)
                try await harness.environment.accountService.connect(
                    accountID: account.accountID,
                    password: credential.password
                )

                _ = try await account.waitForEvent(matching: { event in
                    if case let .rosterUpdated(update) = event, update.isInitialResponse { return true }
                    return false
                }, timeout: TestTimeout.connect)

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

                try await Self.retractStaleBundles(
                    for: credential,
                    keeping: liveDeviceID,
                    on: harness
                )
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
