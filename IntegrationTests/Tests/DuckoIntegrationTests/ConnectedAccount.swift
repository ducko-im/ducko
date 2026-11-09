import DuckoXMPP
import Foundation

/// A connected XMPP account scoped to a `TestHarness`.
///
/// Thin facade over `EventRouter`: each `waitForEvent` / `collectEvents` call
/// allocates a fresh `UUID` and installs a one-shot waiter on the router via
/// `register`, with `withTaskCancellationHandler` propagating caller
/// `Task.cancel()` through `cancelWaiter`. The public API matches the prior
/// stream-based implementation so integration tests do not change.
@MainActor
final class ConnectedAccount {
    let accountID: UUID

    private unowned let router: EventRouter

    init(accountID: UUID, router: EventRouter) {
        self.accountID = accountID
        self.router = router
    }

    // MARK: - Event Waiting

    /// Waits for the first event matching `predicate`, or throws on timeout.
    func waitForEvent(
        matching predicate: @Sendable @escaping (XMPPEvent) -> Bool,
        timeout: Duration = TestTimeout.event
    ) async throws -> XMPPEvent {
        try await waitForRouter(timeout: timeout) { event in
            predicate(event) ? event : nil
        }
    }

    /// Waits for the first event for which `extract` returns non-nil, returning
    /// the extracted payload. Lets tests destructure event payloads in one step
    /// instead of matching then re-`guard case let`-ing outside the closure.
    ///
    /// The explicit `extracting:` label disambiguates this overload from
    /// `waitForEvent(matching:)` at trailing-closure call sites where closure
    /// return type alone would leave the resolution fragile.
    func waitForEvent<T: Sendable>(
        extracting extract: @Sendable @escaping (XMPPEvent) -> T?,
        timeout: Duration = TestTimeout.event
    ) async throws -> T {
        try await waitForRouter(timeout: timeout, deliver: extract)
    }

    /// Collects every event up to and including the one that satisfies `predicate`.
    func collectEvents(
        until predicate: @Sendable @escaping (XMPPEvent) -> Bool,
        timeout: Duration = TestTimeout.event
    ) async throws -> [XMPPEvent] {
        var collected: [XMPPEvent] = []
        return try await waitForRouter(timeout: timeout) { event in
            collected.append(event)
            return predicate(event) ? collected : nil
        }
    }

    /// Polls `condition` on the MainActor until it returns true, or throws on timeout.
    ///
    /// Use this for service-state assertions: `onExternalEvent` fires before the
    /// internal service handlers (which run in their own `Task { @MainActor in ... }`),
    /// so a raw event wait does not guarantee the service has processed the event.
    func waitForCondition(
        _ condition: @MainActor @escaping () async -> Bool,
        timeout: Duration = TestTimeout.event,
        pollInterval: Duration = .milliseconds(100)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: pollInterval)
        }
        if await condition() { return }
        throw TestHarnessError.timeout
    }

    // MARK: - Internal helpers

    /// Owns the install/cancel scaffold shared by the three `waitForEvent` /
    /// `collectEvents` shapes. `deliver` returns non-nil to hand off the
    /// value and drop the waiter (single signal — the helper resumes the
    /// continuation, callers can't accidentally leak it or trigger a
    /// double-resume).
    private func waitForRouter<T: Sendable>(
        timeout: Duration,
        deliver: @MainActor @escaping (XMPPEvent) -> T?
    ) async throws -> T {
        let waiterID = UUID()
        let accountID = accountID
        let router = router
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                let routerDeliver: @MainActor (XMPPEvent) -> Bool = { event in
                    guard let value = deliver(event) else { return false }
                    continuation.resume(returning: value)
                    return true
                }
                let cancel: @MainActor (TestHarnessError) -> Void = { error in
                    continuation.resume(throwing: error)
                }
                router.register(
                    accountID: accountID,
                    id: waiterID,
                    deliver: routerDeliver,
                    cancel: cancel,
                    timeout: timeout
                )
            }
        } onCancel: {
            Task { @MainActor [router] in
                router.cancelWaiter(accountID: accountID, id: waiterID, error: .streamClosed)
            }
        }
    }
}

/// Predicates on the events that more than one suite waits for.
extension XMPPEvent {
    /// Whether this is a room message with `body`.
    func isRoomMessage(body: String) -> Bool {
        if case let .roomMessageReceived(message, _) = self { return message.body == body }
        return false
    }

    /// Whether this is another occupant's departure under `nickname` from `room`.
    func isDeparture(of nickname: String, from room: BareJID) -> Bool {
        if case let .roomOccupantLeft(left, occupant, _, isSelf) = self {
            return left == room && occupant.nickname == nickname && !isSelf
        }
        return false
    }
}
