import Testing
@testable import DuckoXMPP

enum JingleProgressMeterTests {
    private static let start = ContinuousClock.now

    /// Feeds the meter `bytesPerStep` every `step` from the start until `duration` has passed, and returns every emission.
    private static func run(
        _ meter: inout JingleProgressMeter, from offset: Duration = .zero, for duration: Duration,
        step: Duration, bytesPerStep: Int64, startingAt bytes: Int64 = 0, totalBytes: Int64 = .max
    ) -> (emissions: [JingleProgressMeter.Emission], bytes: Int64) {
        var emissions: [JingleProgressMeter.Emission] = []
        var transferred = bytes
        var elapsed = offset + step
        while elapsed <= offset + duration {
            transferred += bytesPerStep
            if let emission = meter.record(bytesTransferred: transferred, totalBytes: totalBytes, at: start + elapsed) {
                emissions.append(emission)
            }
            elapsed += step
        }
        return (emissions, transferred)
    }

    struct Throttle {
        @Test
        func `The first update is reported and later ones at most every 250 ms`() {
            var meter = JingleProgressMeter(startedAt: start)
            let (emissions, _) = run(&meter, for: .seconds(2), step: .milliseconds(10), bytesPerStep: 4096)

            #expect(emissions.first?.bytesTransferred == 4096)
            #expect(emissions.count == 8)
        }

        @Test
        func `The update that completes the transfer is always reported`() {
            var meter = JingleProgressMeter(startedAt: start)
            #expect(meter.record(bytesTransferred: 10, totalBytes: 20, at: start + .milliseconds(10)) != nil)
            #expect(meter.record(bytesTransferred: 15, totalBytes: 20, at: start + .milliseconds(20)) == nil)

            let last = meter.record(bytesTransferred: 20, totalBytes: 20, at: start + .milliseconds(30))
            #expect(last?.bytesTransferred == 20)
        }
    }

    struct Rate {
        @Test
        func `No rate is reported during the first second`() {
            var meter = JingleProgressMeter(startedAt: start)
            let (emissions, _) = run(&meter, for: .milliseconds(990), step: .milliseconds(10), bytesPerStep: 4096)

            #expect(!emissions.isEmpty)
            #expect(emissions.allSatisfy { $0.bytesPerSecond == nil })
        }

        @Test
        func `A constant rate is reported as that rate`() throws {
            var meter = JingleProgressMeter(startedAt: start)
            let (emissions, _) = run(&meter, for: .seconds(5), step: .milliseconds(10), bytesPerStep: 1000)

            let rate = try #require(emissions.last?.bytesPerSecond)
            #expect(abs(rate - 100_000) < 1000)
        }

        @Test
        func `The rate follows a step change within three smoothing times`() throws {
            var meter = JingleProgressMeter(startedAt: start)
            let (_, bytes) = run(&meter, for: .seconds(10), step: .milliseconds(10), bytesPerStep: 1000)
            let (emissions, _) = run(
                &meter, from: .seconds(10), for: .seconds(9), step: .milliseconds(10), bytesPerStep: 4000, startingAt: bytes
            )

            let rate = try #require(emissions.last?.bytesPerSecond)
            // Three smoothing times close all but e^-3 (about 5%) of the gap from 100 kB/s to 400 kB/s.
            #expect(rate > 380_000)
            #expect(rate <= 400_000)
        }
    }
}
