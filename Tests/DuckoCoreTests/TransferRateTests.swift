import Foundation
import Testing
@testable import DuckoCore

struct TransferRateTests {
    struct Reading {
        let bytesPerSecond: Double
        let bytesTransferred: Int64
        let totalBytes: Int64
        let expected: String
    }

    @Test(arguments: [nil, 0, -5] as [Double?])
    func `A transfer has no rate until it moves bytes`(bytesPerSecond: Double?) {
        #expect(TransferRate(bytesPerSecond: bytesPerSecond, bytesTransferred: 0, totalBytes: 1000) == nil)
    }

    @Test(arguments: [
        // 30 MB at 2 MB/s, with 15 seconds' worth still to come.
        Reading(bytesPerSecond: 2_000_000, bytesTransferred: 0, totalBytes: 30_000_000, expected: "2 MB/s · 15 sec left"),
        // 2 hours 14 minutes' worth at 38 kB/s.
        Reading(bytesPerSecond: 38000, bytesTransferred: 1_000_000, totalBytes: 1_000_000 + 38000 * 8040, expected: "38 kB/s · 2 hr 14 min left"),
        // A size that is not known leaves only the rate.
        Reading(bytesPerSecond: 38000, bytesTransferred: 1_000_000, totalBytes: 0, expected: "38 kB/s")
    ])
    func `A rate reads as its speed and the time left`(reading: Reading) throws {
        let rate = try #require(TransferRate(
            bytesPerSecond: reading.bytesPerSecond, bytesTransferred: reading.bytesTransferred, totalBytes: reading.totalBytes
        ))
        #expect(rate.displayText == reading.expected)
    }
}
