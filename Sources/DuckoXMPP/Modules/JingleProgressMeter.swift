import Darwin

/// Measures a transfer's throughput and limits how often its progress is reported.
struct JingleProgressMeter {
    struct Emission: Equatable {
        let bytesTransferred: Int64
        /// The smoothed rate, or `nil` while the transfer is too young for one.
        let bytesPerSecond: Double?
    }

    private static let sampleInterval = Duration.milliseconds(100)
    private static let emissionInterval = Duration.milliseconds(250)
    private static let warmUp = Duration.seconds(1)
    private static let smoothingTime = Duration.seconds(3)

    private let startedAt: ContinuousClock.Instant
    private var lastSampleAt: ContinuousClock.Instant
    private var lastSampleBytes: Int64 = 0
    private var lastEmissionAt: ContinuousClock.Instant?
    private var rate: Double?

    init(startedAt: ContinuousClock.Instant) {
        self.startedAt = startedAt
        self.lastSampleAt = startedAt
    }

    /// Takes the byte count reached at `now`, and returns the update to report: the first one, one at most every
    /// 250 ms after it, and always the one that completes the transfer.
    mutating func record(bytesTransferred: Int64, totalBytes: Int64, at now: ContinuousClock.Instant) -> Emission? {
        let sinceSample = now - lastSampleAt
        if sinceSample >= Self.sampleInterval {
            let instantRate = Double(bytesTransferred - lastSampleBytes) / (sinceSample / .seconds(1))
            if let rate {
                self.rate = rate + (1 - exp(-(sinceSample / Self.smoothingTime))) * (instantRate - rate)
            } else {
                rate = instantRate
            }
            lastSampleAt = now
            lastSampleBytes = bytesTransferred
        }

        let isDue = lastEmissionAt.map { now - $0 >= Self.emissionInterval } ?? true
        guard isDue || bytesTransferred == totalBytes else { return nil }
        lastEmissionAt = now
        return Emission(bytesTransferred: bytesTransferred, bytesPerSecond: now - startedAt >= Self.warmUp ? rate : nil)
    }
}

extension JingleModule {
    /// Records the byte count the session of `offerID` reached, and reports it when the session's meter lets the update
    /// through.
    func recordProgress(sid: String, offerID: String, bytesTransferred: Int64, totalBytes: Int64, context: ModuleContext) {
        let now = ContinuousClock.now
        let emission = state.withLock { state -> JingleProgressMeter.Emission? in
            guard Self.session(sid, offerID: offerID, in: state) != nil else { return nil }
            return state.resources[sid]?.progressMeter?.record(bytesTransferred: bytesTransferred, totalBytes: totalBytes, at: now)
        }
        guard let emission else { return }
        context.emitEvent(.jingleFileTransferProgress(
            sid: sid, offerID: offerID, bytesTransferred: emission.bytesTransferred, totalBytes: totalBytes,
            bytesPerSecond: emission.bytesPerSecond
        ))
    }
}
