import Foundation

/// Where a transcript is scrolled to, in terms that hold while its rows change height and rows come and go above.
public enum TranscriptPosition: Equatable, Sendable {
    /// The end of the transcript, where the newest message is.
    case newest
    /// The top edge.
    case oldest
    /// A row, and how far its top sits below the top of the viewport.
    case reading(id: UUID, offset: CGFloat)
}

/// Pure geometry for a transcript that keeps its place, so reading a position off a viewport and turning one back into
/// a scroll offset are unit-testable. All dimensions are in points, with y growing downwards from the document's top.
public enum TranscriptLayout {
    public struct Row: Equatable, Sendable {
        public let id: UUID
        public let frame: CGRect
        /// Whether the frame's height was measured, as opposed to estimated.
        public let isMeasured: Bool

        public init(id: UUID, frame: CGRect, isMeasured: Bool) {
            self.id = id
            self.frame = frame
            self.isMeasured = isMeasured
        }
    }

    /// Whether a viewport showing `visible` is at the newest message: it ends within a point of the document's end.
    public static func isAtNewest(visible: CGRect, documentHeight: CGFloat) -> Bool {
        documentHeight - visible.maxY <= 1
    }

    /// The position of a viewport showing `visible`, given the `rows` in view. It is the newest message when the
    /// viewport is there, or when no row is in view. Otherwise it is the measured row nearest the viewport's middle,
    /// since such a row stays in view through whatever is measured above or below it next. When none is measured, it
    /// is the nearest row of any kind.
    public static func position(visible: CGRect, documentHeight: CGFloat, rows: [Row]) -> TranscriptPosition {
        guard !isAtNewest(visible: visible, documentHeight: documentHeight) else { return .newest }
        let measured = rows.filter(\.isMeasured)
        let nearest = (measured.isEmpty ? rows : measured).min {
            abs($0.frame.midY - visible.midY) < abs($1.frame.midY - visible.midY)
        }
        guard let nearest else { return .newest }
        return .reading(id: nearest.id, offset: nearest.frame.minY - visible.minY)
    }

    /// The scroll offset that shows `position`, clamped to the document. `rowFrame` is the frame of the row a reading
    /// position names. Returns nil for a reading position whose row is gone.
    public static func origin(
        for position: TranscriptPosition,
        rowFrame: CGRect?,
        documentHeight: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat? {
        let end = max(0, documentHeight - viewportHeight)
        switch position {
        case .newest:
            return end
        case .oldest:
            return 0
        case let .reading(_, offset):
            guard let rowFrame else { return nil }
            return min(max(0, rowFrame.minY - offset), end)
        }
    }
}
