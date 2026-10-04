import AppKit
import SwiftUI

/// The row heights a transcript list has measured. A height counts as measured only for the row value, the width, and
/// the theme it was measured under. Otherwise it is the row's last known height, which serves as its estimate.
struct TranscriptHeights {
    /// What a row that was never measured is taken to be.
    static let estimate: CGFloat = 44

    private struct Entry {
        /// The value the height was measured for, or nil once the width or the theme changed.
        var row: TranscriptRow?
        var height: CGFloat
    }

    private var entries: [UUID: Entry] = [:]
    /// The width the measured heights are for.
    private(set) var width: CGFloat = 0
    private var theme: DuckoTheme?

    /// Called before measuring. Heights measured at another width or under another theme stay on as estimates.
    mutating func prepare(width: CGFloat, theme: DuckoTheme) {
        guard width != self.width || theme != self.theme else { return }
        self.width = width
        self.theme = theme
        for id in entries.keys {
            entries[id]?.row = nil
        }
    }

    func height(of id: UUID) -> CGFloat {
        entries[id]?.height ?? Self.estimate
    }

    func isMeasured(_ row: TranscriptRow) -> Bool {
        entries[row.id]?.row == row
    }

    /// Returns whether the row's height changed.
    mutating func record(_ height: CGFloat, for row: TranscriptRow) -> Bool {
        let isChanged = height != self.height(of: row.id)
        entries[row.id] = Entry(row: row, height: height)
        return isChanged
    }

    /// Drops the rows the list no longer has, so paging far back or going through many days does not grow the cache.
    mutating func keep(_ ids: Set<UUID>) {
        entries = entries.filter { ids.contains($0.key) }
    }
}

/// Measures a row's height at a width with one reused hosting controller, without putting the row on screen.
@MainActor
final class TranscriptRowMeasurer {
    private var controller: NSHostingController<TranscriptRowView>?

    func height(of content: TranscriptRowView, width: CGFloat) -> CGFloat {
        let controller = controller ?? NSHostingController(rootView: content)
        self.controller = controller
        controller.rootView = content
        return controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height.rounded(.up)
    }
}
