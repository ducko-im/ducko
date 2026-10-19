import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.csi")

/// Implements XEP-0352 Client State Indication — tells the server
/// whether the client is actively being used so it can optimize traffic.
public final class CSIModule: XMPPModule, Sendable {
    private struct State {
        var context: ModuleContext?
        /// `nil` when the state the server holds is unknown, as on a resumed stream, so the next change is always sent.
        var isActive: Bool? = true
        var serverSupported: Bool = false
    }

    private let state: OSAllocatedUnfairLock<State>

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Lifecycle

    public func handleConnect() async throws {
        // XEP-0352: a new session starts out active.
        detectServerSupport(isActive: true)
    }

    public func handleResume() async throws {
        detectServerSupport(isActive: nil)
    }

    public func handleDisconnect() async {
        state.withLock {
            $0.serverSupported = false
            $0.isActive = true
        }
    }

    private func detectServerSupport(isActive: Bool?) {
        guard let context = state.withLock({ $0.context }) else { return }

        guard let features = context.serverStreamFeatures(),
              features.child(named: "csi", namespace: XMPPNamespaces.csi) != nil else {
            log.info("Server does not advertise CSI support")
            state.withLock { $0.serverSupported = false }
            return
        }

        state.withLock {
            $0.serverSupported = true
            $0.isActive = isActive
        }
        log.info("Server supports Client State Indication")
    }

    // MARK: - Public API

    /// Sends `<active/>` to indicate the client is in the foreground.
    public func sendActive() async throws {
        let (context, shouldSend) = state.withLock { s -> (ModuleContext?, Bool) in
            guard s.serverSupported, s.isActive != true else { return (nil, false) }
            s.isActive = true
            return (s.context, true)
        }
        guard shouldSend, let context else { return }

        let element = XMLElement(name: "active", namespace: XMPPNamespaces.csi)
        try await context.sendElement(element)
        log.info("Sent CSI active")
    }

    /// Sends `<inactive/>` to indicate the client is in the background.
    public func sendInactive() async throws {
        let (context, shouldSend) = state.withLock { s -> (ModuleContext?, Bool) in
            guard s.serverSupported, s.isActive != false else { return (nil, false) }
            s.isActive = false
            return (s.context, true)
        }
        guard shouldSend, let context else { return }

        let element = XMLElement(name: "inactive", namespace: XMPPNamespaces.csi)
        try await context.sendElement(element)
        log.info("Sent CSI inactive")
    }
}
