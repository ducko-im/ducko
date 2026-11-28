import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

private let ownDeviceID: UInt32 = 4242
private let legacyBundleNode = XMPPNamespaces.omemoLegacyBundles(deviceID: ownDeviceID)
private let waitError = XMPPStanzaError(errorType: .wait, condition: .internalServerError)

private func isRead(of node: String, _ iq: XMLElement) -> Bool {
    iq.attribute("type") == "get" && iq.child(named: "pubsub")?.child(named: "items")?.attribute("node") == node
}

private func isPublish(to node: String, _ iq: XMLElement) -> Bool {
    iq.child(named: "pubsub")?.child(named: "publish")?.attribute("node") == node
}

/// An identity for this device with pre-keys 1 through `preKeyCount`.
private func ownIdentity(preKeyCount: UInt32) throws -> TestOMEMOIdentity {
    try makeTestOMEMOIdentity(deviceID: ownDeviceID, preKeyIDs: Array(1 ... preKeyCount))
}

/// The ids a legacy device-list publish names.
private func publishedLegacyDeviceIDs(in publish: XMLElement) -> [String] {
    let item = publish.child(named: "pubsub")?.child(named: "publish")?.child(named: "item")
    return item?.child(named: "list", namespace: XMPPNamespaces.omemoLegacy)?.children(named: "device").compactMap { $0.attribute("id") } ?? []
}

extension SetupHarness {
    /// Returns once setup has completed and the own-list slot, where the legacy publication runs after it, is idle.
    func awaitSetupSettled() async throws {
        try await eventually { self.statuses == [.complete] }
        try await eventually { self.module.state.withLock { $0.ownListTask == nil } }
    }

    /// Runs pre-key upkeep's publish step: a republish whenever the bundle lags in either version.
    func runUpkeepPublish() async throws {
        if module.bundleNeedsPublish {
            try await module.republishBundle()
        }
    }
}

extension OMEMOModuleTests {
    /// This device is published for legacy OMEMO (XEP-0384 v0.3) under its OMEMO 2 id and keys, without ever holding up
    /// the OMEMO 2 setup.
    struct LegacyPublicationTests {
        // MARK: - New Identity

        @Test func `A new device draws its id again while the account's legacy list holds the drawn one`() async throws {
            let draws = OSAllocatedUnfairLock(initialState: [UInt32(99), ownDeviceID])
            let harness = SetupHarness(
                answer: { iq in deviceListItems([], answering: iq) ?? deviceListItems([99], answering: iq, in: .legacy) },
                drawDeviceID: { OMEMODeviceID(value: draws.withLock { $0.removeFirst() }) }
            )

            try await harness.connect()

            try await harness.awaitSetupSettled()
            #expect(harness.generatedDevices == 2)
            #expect(harness.module.ownIdentityData?.deviceID == ownDeviceID)
            let listPublish = try #require(harness.publishes(to: XMPPNamespaces.omemoLegacyDeviceList).first)
            #expect(publishedLegacyDeviceIDs(in: listPublish) == ["99", "\(ownDeviceID)"])
        }

        @Test func `A new device is not created until a retry reads the account's legacy list`() async throws {
            let harness = SetupHarness(delays: [.seconds(600)]) { iq in
                if isRead(of: XMPPNamespaces.omemoLegacyDeviceList, iq) { throw waitError }
                return deviceListItems([], answering: iq)
            }
            try await harness.connect()
            try await eventually { harness.statuses == [.incomplete] }
            #expect(harness.generatedDevices == 0)
            #expect(harness.module.ownIdentityData == nil)
            #expect(harness.sent.allSatisfy { $0.child(named: "pubsub")?.child(named: "publish") == nil })

            harness.setAnswer(SetupHarness.emptyServer)
            #expect(harness.module.retrySetup())

            try await eventually { harness.statuses == [.incomplete, .complete] }
            #expect(harness.generatedDevices == 1)
        }

        // MARK: - Existing Identity

        /// The legacy list is read only once the OMEMO 2 bundle is out, and its failure leaves the publication lagging.
        @Test func `A legacy list read error leaves an existing device's setup complete`() async throws {
            let harness = try SetupHarness(identity: ownIdentity(preKeyCount: 20).data) { iq in
                if isRead(of: XMPPNamespaces.omemoLegacyDeviceList, iq) { throw waitError }
                return deviceListItems([], answering: iq)
            }

            try await harness.connect()

            try await harness.awaitSetupSettled()
            let bundlePublish = try #require(harness.sent.firstIndex { isPublish(to: XMPPNamespaces.omemoBundles, $0) })
            let legacyRead = try #require(harness.sent.firstIndex { isRead(of: XMPPNamespaces.omemoLegacyDeviceList, $0) })
            #expect(bundlePublish < legacyRead)
            #expect(harness.publishes(to: XMPPNamespaces.omemoLegacyDeviceList).isEmpty)
            #expect(harness.module.bundleNeedsPublish)
        }

        /// The bundle goes out before the list names the device, so a failed bundle publish adds nothing to the list.
        @Test(arguments: [legacyBundleNode, XMPPNamespaces.omemoLegacyDeviceList])
        func `A failed legacy publish leaves the setup complete, and upkeep with unchanged keys retries it`(failingNode: String) async throws {
            let failing = OSAllocatedUnfairLock(initialState: true)
            let harness = try SetupHarness(identity: ownIdentity(preKeyCount: 20).data) { iq in
                if isPublish(to: failingNode, iq), failing.withLock({ $0 }) { throw waitError }
                return deviceListItems([], answering: iq)
            }
            try await harness.connect()
            try await harness.awaitSetupSettled()
            #expect(harness.publishes(to: legacyBundleNode).count == 1)
            #expect(harness.publishes(to: XMPPNamespaces.omemoLegacyDeviceList).count == (failingNode == legacyBundleNode ? 0 : 1))
            #expect(harness.module.bundleNeedsPublish)

            failing.withLock { $0 = false }
            try await harness.runUpkeepPublish()

            let listPublish = try #require(harness.publishes(to: XMPPNamespaces.omemoLegacyDeviceList).last)
            #expect(publishedLegacyDeviceIDs(in: listPublish) == ["\(ownDeviceID)"])
            #expect(!harness.module.bundleNeedsPublish)
        }

        // MARK: - Waiting for Setup

        /// A one-shot command waits here before it disconnects, so it must not cut the legacy publication short, nor be
        /// held up by one that fails.
        @Test(arguments: [false, true])
        func `Waiting for the first attempt returns only once the legacy publication after it has ended`(fails: Bool) async throws {
            let release = AsyncSemaphore()
            let harness = try SetupHarness(identity: ownIdentity(preKeyCount: 20).data) { iq in
                if isPublish(to: legacyBundleNode, iq) {
                    await release.wait()
                    if fails { throw waitError }
                }
                return deviceListItems([], answering: iq)
            }
            try await harness.connect()
            let waiter = Task { await harness.module.awaitSetupAttempt(); return harness.module.bundleNeedsPublish }
            try await eventually { harness.publishes(to: legacyBundleNode).count == 1 }
            #expect(harness.statuses == [.complete])
            try await eventually { harness.firstAttemptWaiters == 1 }

            await release.signal()

            #expect(await waiter.value == fails)
        }

        // MARK: - Pre-Key Floor

        /// The published bundle is the OMEMO 2 device's: its Curve25519 identity key shows the same fingerprint, and the
        /// signature over the shared signed pre-key verifies.
        @Test func `A legacy bundle is published only once twenty pre-keys can go in it`() async throws {
            let identity = try ownIdentity(preKeyCount: 19)
            let harness = SetupHarness(identity: identity.data)
            try await harness.connect()
            try await harness.awaitSetupSettled()
            #expect(harness.publishes(to: legacyBundleNode).isEmpty)
            #expect(harness.publishes(to: XMPPNamespaces.omemoLegacyDeviceList).isEmpty)
            #expect(!harness.module.bundleNeedsPublish)

            harness.module.addPreKeys([OMEMOPreKey(keyID: 20)])
            try await harness.runUpkeepPublish()

            let publish = try #require(harness.publishes(to: legacyBundleNode).first)
            let item = try #require(publish.child(named: "pubsub")?.child(named: "publish")?.child(named: "item"))
            #expect(item.attribute("id") == "current")
            let payload = try #require(item.child(named: "bundle", namespace: XMPPNamespaces.omemoLegacy))
            let bundle = try #require(harness.module.parseLegacyBundleElement(payload, deviceID: ownDeviceID))
            #expect(bundle.preKeys.count == 20)
            #expect(OMEMOLegacySignature.verify(bundle.signedPreKeySignature, signedPreKey: bundle.signedPreKey, identityCurveKey: bundle.identityKey))
            #expect(
                omemoDisplayFingerprint(ofStoredFingerprint: omemoFingerprint(of: bundle.identityKey, format: .legacy))
                    == omemoDisplayFingerprint(ofStoredFingerprint: omemoFingerprint(of: identity.identityKeyPair.publicKeyBytes, format: .omemo2))
            )
            #expect(harness.publishes(to: XMPPNamespaces.omemoLegacyDeviceList).count == 1)
            #expect(!harness.module.bundleNeedsPublish)
        }

        @Test func `A new signed pre-key republishes the legacy bundle though its pre-keys are unchanged`() async throws {
            let identity = try ownIdentity(preKeyCount: 20)
            let harness = SetupHarness(identity: identity.data)
            try await harness.connect()
            try await harness.awaitSetupSettled()
            #expect(harness.publishes(to: legacyBundleNode).count == 1)
            let rotated = try OMEMOPreKeyManager.generateSignedPreKey(keyID: 4_000_000_000, identityKey: identity.identityKeyPair)

            try harness.module.installSignedPreKeys(current: rotated.identityData, retained: [identity.signedPreKey.identityData])
            try await harness.runUpkeepPublish()

            let publish = try #require(harness.publishes(to: legacyBundleNode).dropFirst().first)
            let item = try #require(publish.child(named: "pubsub")?.child(named: "publish")?.child(named: "item"))
            let payload = try #require(item.child(named: "bundle", namespace: XMPPNamespaces.omemoLegacy))
            let bundle = try #require(harness.module.parseLegacyBundleElement(payload, deviceID: ownDeviceID))
            #expect(bundle.signedPreKeyID == 4_000_000_000)
            #expect(bundle.preKeys.count == 20)
            #expect(!harness.module.bundleNeedsPublish)
        }

        // MARK: - Notifications

        @Test func `A legacy device list from the account without this device puts it back`() async throws {
            let harness = try SetupHarness(identity: ownIdentity(preKeyCount: 20).data) { iq in
                deviceListItems([], answering: iq) ?? deviceListItems([99], answering: iq, in: .legacy)
            }
            try await harness.connect()
            try await harness.awaitSetupSettled()
            #expect(harness.publishes(to: XMPPNamespaces.omemoLegacyDeviceList).count == 1)

            try harness.module.handleMessage(legacyListNotification(naming: [99]))

            try await eventually { harness.publishes(to: XMPPNamespaces.omemoLegacyDeviceList).count == 2 }
            let readd = try #require(harness.publishes(to: XMPPNamespaces.omemoLegacyDeviceList).last)
            #expect(publishedLegacyDeviceIDs(in: readd) == ["99", "\(ownDeviceID)"])
        }

        /// The publication counts as done once its list write returns, so a notification that changed the list while the
        /// write ran must still put the device back after it.
        @Test func `A legacy device list without this device, arriving while the publication writes the list, puts it back`() async throws {
            let release = AsyncSemaphore()
            let heldWrites = OSAllocatedUnfairLock(initialState: 1)
            let harness = try SetupHarness(identity: ownIdentity(preKeyCount: 20).data) { iq in
                if isPublish(to: XMPPNamespaces.omemoLegacyDeviceList, iq), heldWrites.withLock({ held in defer { held -= 1 }; return held > 0 }) {
                    await release.wait()
                }
                return deviceListItems([], answering: iq) ?? deviceListItems([99], answering: iq, in: .legacy)
            }
            try await harness.connect()
            try await eventually { harness.publishes(to: XMPPNamespaces.omemoLegacyDeviceList).count == 1 }

            try harness.module.handleMessage(legacyListNotification(naming: [99]))
            await release.signal()

            try await eventually { harness.publishes(to: XMPPNamespaces.omemoLegacyDeviceList).count == 2 }
            let readd = try #require(harness.publishes(to: XMPPNamespaces.omemoLegacyDeviceList).last)
            #expect(publishedLegacyDeviceIDs(in: readd) == ["99", "\(ownDeviceID)"])
        }

        enum PendingPublication: CaseIterable {
            case tooFewPreKeys, failedBundlePublish
        }

        /// A device on the legacy list without a bundle cannot be encrypted to, so the pending publication adds it once
        /// its bundle is out.
        @Test(arguments: PendingPublication.allCases)
        func `A legacy device list without this device adds nothing back while the legacy publication is pending`(pending: PendingPublication) async throws {
            let harness = try SetupHarness(identity: ownIdentity(preKeyCount: pending == .tooFewPreKeys ? 19 : 20).data) { iq in
                if pending == .failedBundlePublish, isPublish(to: legacyBundleNode, iq) { throw waitError }
                return deviceListItems([], answering: iq) ?? deviceListItems([99], answering: iq, in: .legacy)
            }
            try await harness.connect()
            try await harness.awaitSetupSettled()
            #expect(harness.publishes(to: XMPPNamespaces.omemoLegacyDeviceList).isEmpty)

            try harness.module.handleMessage(legacyListNotification(naming: [99]))

            let ownJID = try #require(BareJID.parse("user@example.com"))
            #expect(harness.module.state.withLock { $0.deviceLists[.legacy]?[ownJID] } == [99])
            #expect(harness.module.state.withLock { $0.ownListTask == nil && $0.pendingReannounces.isEmpty })
            try await Task.sleep(for: .milliseconds(100))
            #expect(harness.publishes(to: XMPPNamespaces.omemoLegacyDeviceList).isEmpty)
        }
    }
}

/// The account's legacy device list naming `devices`, as the server notifies it.
private func legacyListNotification(naming devices: [UInt32]) throws -> XMPPMessage {
    let entries = devices.map { "<device id='\($0)'/>" }.joined()
    return try XMPPMessage(element: stanza("""
    <message from='user@example.com'><event xmlns='http://jabber.org/protocol/pubsub#event'>\
    <items node='\(XMPPNamespaces.omemoLegacyDeviceList)'><item id='current'>\
    <list xmlns='\(XMPPNamespaces.omemoLegacy)'>\(entries)</list></item></items></event></message>
    """))
}
