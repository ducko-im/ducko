import Foundation
import Testing
@testable import DuckoCore

struct TranscriptLayoutTests {
    private let ids = (0 ..< 10).map { _ in UUID() }

    /// Ten rows of 100 pt, so the document is 1000 pt tall.
    private func rows(measured: Set<Int> = Set(0 ..< 10)) -> [TranscriptLayout.Row] {
        ids.enumerated().map { index, id in
            TranscriptLayout.Row(id: id, frame: CGRect(x: 0, y: CGFloat(index) * 100, width: 300, height: 100), isMeasured: measured.contains(index))
        }
    }

    private func viewport(y: CGFloat, height: CGFloat = 300) -> CGRect {
        CGRect(x: 0, y: y, width: 300, height: height)
    }

    @Test(arguments: [700, 699.5, 699])
    func `a viewport ending within a point of the document's end is at the newest message`(y: CGFloat) {
        #expect(TranscriptLayout.position(visible: viewport(y: y), documentHeight: 1000, rows: rows()) == .newest)
    }

    @Test func `a viewport away from the end is at the measured row nearest its middle`() {
        // The viewport shows 250...550, with its middle at 400, which is where rows 3 and 4 meet. Row 3 is unmeasured.
        let position = TranscriptLayout.position(visible: viewport(y: 250), documentHeight: 1000, rows: rows(measured: [2, 4, 5]))

        #expect(position == .reading(id: ids[4], offset: 150))
    }

    @Test func `a viewport over rows that only have estimates is at the nearest of those`() {
        let position = TranscriptLayout.position(visible: viewport(y: 220), documentHeight: 1000, rows: rows(measured: []))

        #expect(position == .reading(id: ids[3], offset: 80))
    }

    @Test func `a document shorter than the viewport is at the newest message`() {
        let short = Array(rows().prefix(2))

        #expect(TranscriptLayout.position(visible: viewport(y: 0), documentHeight: 200, rows: short) == .newest)
    }

    @Test func `a reading position puts its row at its offset`() {
        let frame = CGRect(x: 0, y: 400, width: 300, height: 100)

        let origin = TranscriptLayout.origin(for: .reading(id: ids[4], offset: 150), rowFrame: frame, documentHeight: 1000, viewportHeight: 300)

        #expect(origin == 250)
    }

    struct ClampedCase {
        let rowTop: CGFloat
        let offset: CGFloat
        let expected: CGFloat
    }

    @Test(arguments: [ClampedCase(rowTop: 50, offset: 200, expected: 0), ClampedCase(rowTop: 950, offset: 10, expected: 700)])
    func `a reading position is clamped to the document`(example: ClampedCase) {
        let frame = CGRect(x: 0, y: example.rowTop, width: 300, height: 50)

        let origin = TranscriptLayout.origin(
            for: .reading(id: ids[0], offset: example.offset), rowFrame: frame, documentHeight: 1000, viewportHeight: 300
        )

        #expect(origin == example.expected)
    }

    @Test func `a reading position whose row is gone has no origin`() {
        #expect(TranscriptLayout.origin(for: .reading(id: UUID(), offset: 0), rowFrame: nil, documentHeight: 1000, viewportHeight: 300) == nil)
    }

    @Test(arguments: [(documentHeight: CGFloat(1000), end: CGFloat(700)), (documentHeight: 200, end: 0)])
    func `newest and oldest map to the document's ends`(example: (documentHeight: CGFloat, end: CGFloat)) {
        #expect(TranscriptLayout.origin(for: .newest, rowFrame: nil, documentHeight: example.documentHeight, viewportHeight: 300) == example.end)
        #expect(TranscriptLayout.origin(for: .oldest, rowFrame: nil, documentHeight: example.documentHeight, viewportHeight: 300) == 0)
    }
}
