import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
@testable import DuckoXMPP

/// Plays the server for a module driven without a client: answers bundle fetches, and records what the module sends,
/// reports and hands to the modules acting on decrypted messages.
final class OMEMOMessageRecorder: Sendable {
    private struct Recorded {
        var events: [XMPPEvent] = []
        var sent: [XMLElement] = []
        var iqs: [XMLElement] = []
        var dispatched: [XMPPMessage] = []
        var forwardTo: [any XMPPModule] = []
        var bundles: [String: XMLElement] = [:]
    }

    let account: FullJID
    private let recorded = OSAllocatedUnfairLock(initialState: Recorded())
    private let answer: @Sendable (XMLElement) async -> XMLElement?

    init(account: FullJID, answer: @escaping @Sendable (XMLElement) async -> XMLElement? = { _ in nil }) {
        self.account = account
        self.answer = answer
    }

    var context: ModuleContext {
        makeStubModuleContext(
            sendStanza: { [recorded] stanza, onAccepted in
                onAccepted?()
                recorded.withLock { $0.sent.append(stanza.element) }
            },
            sendIQ: { [recorded, answer] iq, _ in
                recorded.withLock { $0.iqs.append(iq.element) }
                let item = iq.element.child(named: "pubsub")?.child(named: "items")?.child(named: "item")?.attribute("id")
                if let bundle = recorded.withLock({ recorded in item.flatMap { recorded.bundles.removeValue(forKey: $0) } }) {
                    return bundle
                }
                return await answer(iq.element)
            },
            emitEvent: { [recorded] event in recorded.withLock { $0.events.append(event) } },
            connectedJID: account,
            dispatchDecryptedMessage: { [recorded] message in
                let modules = recorded.withLock { recorded in
                    recorded.dispatched.append(message)
                    return recorded.forwardTo
                }
                for module in modules {
                    module.handleDecryptedMessage(message)
                }
            }
        )
    }

    /// Answers the next fetch of the bundle `deviceID` with `identity`'s bundle.
    func answerBundle(of identity: TestOMEMOIdentity, for deviceID: UInt32) {
        recorded.withLock { $0.bundles["\(deviceID)"] = bundleItems(for: identity) }
    }

    func forwardDecryptedMessages(to modules: [any XMPPModule]) {
        recorded.withLock { $0.forwardTo = modules }
    }

    var events: [XMPPEvent] {
        recorded.withLock { $0.events }
    }

    var sentMessages: [XMLElement] {
        recorded.withLock { $0.sent.filter { $0.name == "message" } }
    }

    var dispatched: [XMPPMessage] {
        recorded.withLock { $0.dispatched }
    }

    /// Whose device lists the module fetched, in order.
    var deviceListFetches: [String] {
        fetches(of: XMPPNamespaces.omemoDevices)
    }

    /// Whose legacy device lists the module fetched, in order.
    var legacyDeviceListFetches: [String] {
        fetches(of: XMPPNamespaces.omemoLegacyDeviceList)
    }

    private func fetches(of node: String) -> [String] {
        recorded.withLock { recorded in
            recorded.iqs.filter { $0.child(named: "pubsub")?.child(named: "items")?.attribute("node") == node }
                .map { $0.attribute("to") ?? "" }
        }
    }

    /// How often the module reported a session moved on: once for each empty message it sends, as it encrypts it,
    /// and once for each it receives.
    var sessionAdvances: Int {
        events.count { if case .omemoSessionAdvanced = $0 { true } else { false } }
    }

    var outcomes: [OMEMOReceiveOutcome] {
        events.compactMap { if case let .omemoEncryptedMessageReceived(_, outcome, _) = $0 { outcome } else { nil } }
    }

    var decryptedEvents: [OMEMODecryptedMessage] {
        outcomes.compactMap { if case let .decrypted(decrypted) = $0 { decrypted } else { nil } }
    }

    func installedModule(identity: OMEMOModule.OMEMOIdentityData, mucModule: MUCModule? = nil) -> OMEMOModule {
        makeInstalledOMEMOModule(identity: identity, context: context, mucModule: mucModule)
    }
}

extension OMEMOReceiveOutcome {
    var reason: OMEMOUndecryptableReason? {
        if case let .undecryptable(reason) = self { reason } else { nil }
    }
}
