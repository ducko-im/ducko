import DuckoTestSupport
import Foundation
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let contact = BareJID(localPart: "bob", domainPart: "example.com")!

extension OMEMOServiceTests {
    /// A key first seen through legacy OMEMO is stored in its legacy form, and the next process holds that form.
    @MainActor
    struct LegacyTrustRows {
        @Test func `a row seeded empty and filled by a legacy key exchange holds the legacy form after a restart and admits the next legacy message`() async throws {
            let harness = try await EncryptedSendHarness.connect()
            let events = OSAllocatedUnfairLock<[XMPPEvent]>(initialState: [])
            let forwardSetupEvent = harness.accountService.onEvent
            harness.accountService.onEvent = { event, accountID in
                events.withLock { $0.append(event) }
                forwardSetupEvent?(event, accountID)
            }
            let module = try #require(await harness.accountService.connectedClient(for: harness.accountID)?.module(ofType: OMEMOModule.self))
            let contactIdentity = OMEMOIdentityKeyPair()
            var sender = try LegacyOMEMOSender(identity: contactIdentity, deviceID: 300, to: harness.ownKeys)
            await harness.omemoService.handleEvent(.omemoDeviceListReceived(jid: contact, devices: [300], version: .legacy), accountID: harness.accountID)

            _ = try module.receiveForwardedMessage(legacyMessage(sender.encrypted("hello"), id: "m1"))
            try await eventually { events.withLock { $0.contains(where: Self.isSessionEstablished) } }
            for event in events.withLock({ $0 }) where Self.isSessionEstablished(event) {
                await harness.omemoService.handleEvent(event, accountID: harness.accountID)
            }
            await harness.omemoStore.seedFromIdentityData(harness.ownKeys, accountJID: testJIDString)
            let restarted = OMEMOService(omemoStore: harness.omemoStore)
            let reader = try await installedModule(of: restarted, accountID: harness.accountID)
            let outcome = try reader.receiveForwardedMessage(legacyMessage(sender.encrypted("again"), id: "m2"))

            let curveKey = try Array(contactIdentity.agreementPrivateKey().publicKey.rawRepresentation)
            let row = try #require(try await harness.omemoStore.loadAllDevices(for: contact.description, accountJID: testJIDString).first { $0.deviceID == 300 })
            #expect(row.fingerprint == omemoFingerprint(of: curveKey, format: .legacy))
            #expect(row.fingerprint.count == 66)
            #expect(OMEMODeviceInfo.formatFingerprint(row.fingerprint).filter { $0 != " " } == hexString(curveKey))
            #expect(restarted.trustGuard(forAccountJID: testJIDString).heldFingerprint(peer: contact, deviceID: 300) == row.fingerprint)
            let body: String? = if case let .decrypted(decrypted)? = outcome { decrypted.message.body } else { nil }
            #expect(body == "again")
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        private nonisolated static func isSessionEstablished(_ event: XMPPEvent) -> Bool {
            if case .omemoSessionEstablished(_, _, .legacy, _, _) = event { true } else { false }
        }

        /// A chat message from the contact's desktop to the account carrying `encrypted`.
        private func legacyMessage(_ encrypted: DuckoXMPP.XMLElement, id: String) -> XMPPMessage {
            var message = XMPPMessage(type: .chat, to: JID.parse("\(testJIDString)/ducko"), id: id)
            message.from = JID.parse("\(contact)/desktop")
            message.element.addChild(encrypted)
            return message
        }

        /// The module `service` builds from its store, with its identity installed as an established session installs it.
        private func installedModule(of service: OMEMOService, accountID: UUID) async throws -> OMEMOModule {
            let context = ModuleContext(
                sendStanza: { _, onAccepted in onAccepted?() }, sendIQ: { _, _ in nil }, emitEvent: { _ in }, generateID: { "id" },
                connectedJID: { FullJID.parse("\(testJIDString)/ducko") }, domain: "example.com"
            )
            let pepModule = PEPModule()
            pepModule.setUp(context)
            let module = try await service.buildModule(for: #require(BareJID.parse(testJIDString)), accountID: accountID, pepModule: pepModule)
            module.setUp(context)
            module.handleSessionEstablished(resumed: true)
            return module
        }
    }
}
