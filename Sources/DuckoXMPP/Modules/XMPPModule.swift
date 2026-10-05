/// Feature module for stanza handling. `final class` (not actor) so handler calls stay synchronous from the dispatch loop.
/// `ModuleContext` is stored behind an `OSAllocatedUnfairLock` for `Sendable` compliance.
public protocol XMPPModule: AnyObject, Sendable {
    /// XMPP feature namespaces this module supports (for XEP-0030 Service Discovery).
    var features: [String] { get }
    /// Called once when the module is registered with a client.
    func setUp(_ context: ModuleContext)
    /// Called once the handshake has bound or resumed a session, before any incoming stanza of that session is
    /// dispatched and before the session is announced with `.connected` or `.streamResumed`.
    func handleSessionEstablished(resumed: Bool)
    /// Called after the XMPP session is fully established.
    func handleConnect() async throws
    /// Called after a successful Stream Management session resume.
    func handleResume() async throws
    /// Called when the XMPP session is torn down (before state is cleared).
    func handleDisconnect() async
    /// Called for each incoming `<message>` stanza.
    func handleMessage(_ message: XMPPMessage) throws
    /// Called for each incoming `<presence>` stanza.
    func handlePresence(_ presence: XMPPPresence) throws
    /// Called for each incoming `<iq>` stanza (after IQ tracking).
    /// Returns `true` if the module handled the IQ (preventing a `service-unavailable` fallback reply).
    func handleIQ(_ iq: XMPPIQ) throws -> Bool
}

public extension XMPPModule {
    var features: [String] {
        []
    }

    func handleSessionEstablished(resumed: Bool) {}
    func handleConnect() async throws {}
    func handleResume() async throws {}
    func handleDisconnect() async {}
    func handleMessage(_ message: XMPPMessage) throws {}
    func handlePresence(_ presence: XMPPPresence) throws {}
    func handleIQ(_ iq: XMPPIQ) throws -> Bool {
        false
    }
}
