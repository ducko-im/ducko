import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.serviceoutage")

/// Implements XEP-0455 Service Outage Status — parses outage information
/// from stream features and emits an event for service-layer consumption.
public final class ServiceOutageModule: XMPPModule, Sendable {
    private struct State {
        var context: ModuleContext?
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
        checkForOutage()
    }

    public func handleResume() async throws {
        checkForOutage()
    }

    private func checkForOutage() {
        guard let context = state.withLock({ $0.context }), let features = context.serverStreamFeatures(),
              let outage = features.child(named: "outage", namespace: XMPPNamespaces.serviceOutage) else {
            return
        }

        let description = outage.child(named: "description")?.textContent
        let expectedEnd = outage.child(named: "expected-end")?.textContent
        let alternativeDomain = outage.child(named: "alternative-domain")?.textContent

        let info = ServiceOutageInfo(
            description: description,
            expectedEnd: expectedEnd,
            alternativeDomain: alternativeDomain
        )

        log.info("Service outage detected: \(description ?? "no description")")
        context.emitEvent(.serviceOutageReceived(info))
    }
}
