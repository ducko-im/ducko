import Foundation

/// Polls `condition` at `interval` until true or `timeout` elapses. Cooperatively cancellable — returns `false` on
/// cancellation including during the `Task.sleep` gap. `sending` closure lets `@MainActor` callers hand off without
/// requiring `@Sendable`.
func pollUntil(
    _ condition: sending () async -> Bool,
    timeout: Duration,
    interval: Duration = .milliseconds(50)
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if Task.isCancelled { return false }
        if await condition() { return true }
        do {
            try await Task.sleep(for: interval)
        } catch {
            return false
        }
    }
    if Task.isCancelled { return false }
    return await condition()
}
