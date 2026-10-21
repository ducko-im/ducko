import DuckoCore

/// The wait a server's rate limit puts on channel searches, counted down in whole seconds.
struct ChannelSearchCooldown: Equatable {
    private let deadline: ContinuousClock.Instant

    init(seconds: Int, from now: ContinuousClock.Instant) {
        self.deadline = now + .seconds(seconds)
    }

    /// The seconds left, counting a started second as a whole one, or nil once searching may resume.
    func remainingSeconds(at now: ContinuousClock.Instant) -> Int? {
        deadline > now ? (deadline - now).secondsRoundedUp : nil
    }

    /// When `remainingSeconds` next changes.
    func nextChange(after now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        guard let remaining = remainingSeconds(at: now) else { return now }
        return deadline - .seconds(remaining - 1)
    }
}
