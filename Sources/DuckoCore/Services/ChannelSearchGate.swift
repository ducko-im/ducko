import Foundation

/// A channel search the server's rate limit holds back. The next one may go out after `retryAfterSeconds`.
public struct ChannelSearchRateLimit: Error, LocalizedError {
    public let retryAfterSeconds: Int

    init(retryAfter wait: Duration) {
        self.retryAfterSeconds = wait.secondsRoundedUp
    }

    /// Tells the user how many seconds are left before channel searches may resume.
    public static func waitMessage(seconds: Int) -> String {
        "The server is limiting channel searches, try again in \(seconds) s"
    }

    public var errorDescription: String? {
        Self.waitMessage(seconds: retryAfterSeconds)
    }
}

/// A channel search service's rate limit on an account: when the account may search it again, and how many rate
/// limits in a row led there.
public struct ChannelSearchLimit: Sendable, Codable, Equatable {
    public let notBefore: Date
    public let consecutiveCount: Int

    public init(notBefore: Date, consecutiveCount: Int) {
        self.notBefore = notBefore
        self.consecutiveCount = consecutiveCount
    }
}

/// When an account may search each channel search service again after the service rate-limited it. The limits are
/// stored with the account, so they hold across reconnects and relaunches, and for the app and the CLI alike.
struct ChannelSearchGate {
    /// The wait after a rate limit that names no `retry-after`. Each further one in a row doubles it, up to six times.
    static let initialBackOff: Duration = .seconds(10)
    private static let maxBackOffDoublings = 6

    private(set) var limits: [String: ChannelSearchLimit]

    /// How long the account must still wait before searching `service`, or nil when it may search now. A wait too long
    /// for a `Duration` saturates, since the service's `retry-after` is kept however large it is.
    func remainingWait(service: String, at now: Date) -> Duration? {
        guard let notBefore = limits[service]?.notBefore, notBefore > now else { return nil }
        return .seconds(min(notBefore.timeIntervalSince(now), TimeInterval(Int.max)))
    }

    /// Records the service's rate limit and returns the wait: `retryAfter` when the service named one, else the
    /// back-off.
    mutating func recordRateLimit(retryAfter: Duration?, service: String, at now: Date) -> Duration {
        let count = (limits[service]?.consecutiveCount ?? 0) + 1
        let wait = retryAfter ?? Self.initialBackOff * (1 << min(count - 1, Self.maxBackOffDoublings))
        limits[service] = ChannelSearchLimit(notBefore: now.addingTimeInterval(TimeInterval(wait.components.seconds)), consecutiveCount: count)
        return wait
    }

    /// Lifts the service's limit after a search it answered. Returns whether there was one.
    mutating func recordSearch(service: String) -> Bool {
        limits.removeValue(forKey: service) != nil
    }
}
