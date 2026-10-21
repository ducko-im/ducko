import Testing
@testable import DuckoXMPP

/// Ducko's device list, bundle and `<encrypted>` element against the ones the reference implementation wrote.
extension OMEMO2FixtureTests {
    struct Elements {
        private let module = OMEMOModule(pepModule: PEPModule())

        @Test(arguments: ["alice", "bob"])
        func `a device list has the reference's shape`(device name: String) throws {
            let device = try OMEMO2Fixtures.device(name)

            let built = module.buildDeviceListElement([device.deviceID])

            #expect(try stanza(built.xmlString) == stanza(device.deviceList))
            #expect(try module.parseDeviceList(stanza(device.deviceList)) == [device.deviceID])
        }

        @Test(arguments: ["alice", "bob"])
        func `a bundle has the reference's shape and reads back as its keys`(device name: String) throws {
            let device = try OMEMO2Fixtures.device(name)

            let built = try module.buildBundleElement(OMEMOPreKeyManager.buildBundle(
                deviceID: OMEMODeviceID(value: device.deviceID), identityKeyPair: device.restoredIdentityKey(),
                signedPreKey: device.restoredSignedPreKey(), preKeys: device.restoredPreKeys()
            ))
            let parsed = try #require(try module.parseBundleElement(stanza(device.bundle), deviceID: device.deviceID))

            #expect(try stanza(built.xmlString) == stanza(device.bundle))
            #expect(parsed.identityKey == Array(device.identityKey.publicKey))
            #expect(parsed.signedPreKeyID == device.signedPreKey.id)
            #expect(parsed.signedPreKey == Array(device.signedPreKey.publicKey))
            #expect(parsed.signedPreKeySignature == Array(device.signedPreKey.signature))
            #expect(parsed.preKeys.map(\.id) == device.preKeys.map(\.id))
            #expect(parsed.preKeys.map(\.publicKey) == device.preKeys.map { Array($0.publicKey) })
        }

        @Test func `an encrypted element has the reference's shape`() throws {
            let alice = try OMEMO2Fixtures.device("alice")
            let bob = try OMEMO2Fixtures.device("bob")
            let bobJID = try #require(BareJID.parse(bob.jid))
            let messages = try OMEMO2Fixtures.conversation().messages
            let keyExchange = try #require(messages.first { $0.keyExchange != nil && $0.payload != nil })
            let ratchetMessage = try #require(messages.first { $0.keyExchange == nil && $0.payload != nil && $0.sender == "alice" })

            for (message, data) in try [
                (keyExchange, Array(#require(keyExchange.keyExchange).bytes)),
                (ratchetMessage, Array(ratchetMessage.authenticatedMessage.bytes))
            ] {
                let key = module.buildKeyElement(deviceID: bob.deviceID, data: data, isKex: message.keyExchange != nil)

                let built = try module.buildEncryptedElement(
                    keys: [(bobJID, key)], payload: #require(message.payload), senderDeviceID: alice.deviceID
                )

                #expect(try stanza(built.xmlString) == stanza(message.encrypted))
            }
        }

        @Test func `a message whose keys name another account is not for this device`() throws {
            let bob = try OMEMO2Fixtures.device("bob")
            let message = try #require(try OMEMO2Fixtures.conversation().messages.first { $0.sender == "alice" })
            let module = makeInstalledOMEMOModule(
                identity: bob.identityData, context: makeStubModuleContext(connectedJID: FullJID.parse("carol@example.org/desktop"))
            )
            let sender = try #require(FullJID.parse("alice@example.org/phone"))

            #expect(throws: OMEMOModuleError.notForThisDevice) {
                try module.decryptIncomingMessage(stanza(message.encrypted), from: .full(sender))
            }
        }
    }
}
