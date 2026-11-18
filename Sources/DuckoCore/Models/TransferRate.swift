import Foundation

/// How fast a direct transfer is moving and how long the rest of it will take at that pace.
public struct TransferRate: Sendable, Equatable {
    public let bytesPerSecond: Double
    /// The time the bytes still to come take at `bytesPerSecond`, or `nil` when the transfer's size is not known.
    public let secondsRemaining: Double?

    /// Creates the rate of a transfer that has moved `bytesTransferred` of `totalBytes`, or `nil` while no rate is known.
    public init?(bytesPerSecond: Double?, bytesTransferred: Int64, totalBytes: Int64) {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        self.bytesPerSecond = bytesPerSecond
        self.secondsRemaining = totalBytes > 0 ? Double(max(totalBytes - bytesTransferred, 0)) / bytesPerSecond : nil
    }

    /// The rate and the time left, such as "2.1 MB/s · 15 sec left".
    public var displayText: String {
        let rate = Int64(bytesPerSecond.rounded()).formatted(.byteCount(style: .file)) + "/s"
        guard let secondsRemaining else { return rate }
        let timeLeft = Duration.seconds(secondsRemaining.rounded()).formatted(
            Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .condensedAbbreviated, maximumUnitCount: 2)
        )
        return "\(rate) · \(timeLeft) left"
    }
}
