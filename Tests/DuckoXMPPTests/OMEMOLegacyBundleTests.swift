import DuckoTestSupport
import Testing
@testable import DuckoXMPP

/// Building a session from a contact device's legacy bundle, for a device only its owner's legacy list holds: the
/// bundle's signature, and its key against the device's session in the other version.
struct OMEMOLegacyBundleTests {
    private let aliceJID = BareJID(localPart: "alice", domainPart: "example.com")!
    private let alice: TestOMEMOIdentity
    private let bob: TestOMEMOIdentity

    init() throws {
        self.alice = try makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1])
        self.bob = try makeTestOMEMOIdentity(deviceID: 200, preKeyIDs: [7])
    }

    @Test func `a legacy bundle whose signed pre-key signature is invalid fails encrypt with a cryptographic failure`() async throws {
        let valid = try legacyBundle(of: alice)
        var signature = valid.signedPreKeySignature
        signature[0] ^= 0xFF
        let corrupted = OMEMOBundle(
            deviceID: valid.deviceID, identityKey: valid.identityKey, signedPreKeyID: valid.signedPreKeyID,
            signedPreKey: valid.signedPreKey, signedPreKeySignature: signature, preKeys: valid.preKeys
        )
        let module = try bobsModule(answeringLegacyBundle: corrupted)

        await #expect(throws: OMEMOModuleError.cryptographicFailure("The signed pre-key signature is invalid")) {
            _ = try await module.encryptMessage(plaintext: "hello", to: aliceJID, recipientDeviceIDs: [100], ownDeviceIDs: [])
        }
        #expect(module.allSessionEntries().isEmpty)
    }

    /// As after a restart whose trust row for the device holds no key. The device has one key in both versions, so the
    /// restored OMEMO 2 session's key stands in for a held one.
    @Test(arguments: [false, true])
    func `with no key held, a legacy bundle is taken up only when it carries the key of the device's restored OMEMO 2 session`(
        isImpostor: Bool
    ) async throws {
        let alice = alice
        let earlier = try OMEMOMessageRecorder(account: #require(FullJID.parse("bob@example.com/laptop"))) { _ in bundleItems(for: alice) }
            .installedModule(identity: bob.data)
        _ = try await earlier.encryptMessage(plaintext: "one", to: aliceJID, recipientDeviceIDs: [100], ownDeviceIDs: [])
        let owner = try isImpostor ? makeTestOMEMOIdentity(deviceID: 100, preKeyIDs: [1]) : alice
        let module = try bobsModule(answeringLegacyBundle: legacyBundle(of: owner))
        let trustGuard = OMEMOTrustGuard()
        module.configureTrustGuard(trustGuard)
        module.restoreSessions(earlier.allSessionEntries())
        try #require(module.allSessionEntries().map(\.version) == [.omemo2])

        let encrypt = { try await module.encryptMessage(plaintext: "two", to: aliceJID, recipientDeviceIDs: [100], ownDeviceIDs: []) }

        if isImpostor {
            await #expect(throws: OMEMOModuleError.changedIdentityKey) { _ = try await encrypt() }
            #expect(module.allSessionEntries().map(\.version) == [.omemo2])
            #expect(trustGuard.heldFingerprint(peer: aliceJID, deviceID: 100).isEmpty)
        } else {
            #expect(try await encrypt().legacyEncrypted != nil)
            #expect(Set(module.allSessionEntries().map(\.version)) == [.omemo2, .legacy])
            #expect(OMEMOFingerprint.matches(
                trustGuard.heldFingerprint(peer: aliceJID, deviceID: 100), omemoFingerprint(of: alice.identityKeyPair.publicKeyBytes, format: .omemo2)
            ))
        }
    }

    // MARK: - Helpers

    private func legacyBundle(of identity: TestOMEMOIdentity) throws -> OMEMOBundle {
        try OMEMOPreKeyManager.buildLegacyBundle(
            deviceID: OMEMODeviceID(value: identity.data.deviceID), identityKeyPair: identity.identityKeyPair,
            signedPreKey: identity.signedPreKey, preKeys: identity.preKeys
        )
    }

    /// bob's device 200, which lists alice's device 100 on her legacy list alone and fetches `bundle` as its legacy
    /// bundle. Any other fetch finds nothing.
    private func bobsModule(answeringLegacyBundle bundle: OMEMOBundle) throws -> OMEMOModule {
        let node = XMPPNamespaces.omemoLegacyBundles(deviceID: bundle.deviceID.value)
        var item = XMLElement(name: "item", attributes: ["id": "current"])
        item.addChild(OMEMOModule(pepModule: PEPModule()).buildLegacyBundleElement(bundle))
        var items = XMLElement(name: "items", attributes: ["node": node])
        items.addChild(item)
        var pubsub = XMLElement(name: "pubsub", namespace: XMPPNamespaces.pubsub)
        pubsub.addChild(items)
        let answer = pubsub
        let recorder = try OMEMOMessageRecorder(account: #require(FullJID.parse("bob@example.com/laptop"))) { iq in
            iq.child(named: "pubsub")?.child(named: "items")?.attribute("node") == node ? answer : nil
        }
        let module = recorder.installedModule(identity: bob.data)
        let aliceJID = aliceJID
        module.state.withLock { $0.deviceLists[.legacy, default: [:]][aliceJID] = [100] }
        return module
    }
}
