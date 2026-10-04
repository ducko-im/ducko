import AppKit
import DuckoCore
import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoUI

/// The list in a window that is never shown, which gives the table real geometry.
@MainActor
private final class ListHarness {
    let coordinator = TranscriptListCoordinator()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
        styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: true
    )
    let environment = AppEnvironment(store: MockPersistenceStore(), transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore())
    let preferences = PreferencesFixture()
    let themeEngine: ThemeEngine
    let consent = RemoteImageConsent()
    var restsShortContentAtEnd = true
    var bottomPadding: CGFloat = 0
    var showsJumpToNewest = true
    private(set) var nearOldestCalls = 0

    init() {
        self.themeEngine = preferences.makeThemeEngine()
        window.contentView = coordinator.container
    }

    func show(_ rows: [TranscriptRow], scroller: TranscriptScroller) {
        coordinator.update(TranscriptListInputs(
            rows: rows, scroller: scroller, context: .history, remoteImageConsent: consent,
            environment: environment, themeEngine: themeEngine, theme: themeEngine.current,
            accessibilityIdentifier: "message-list", restsShortContentAtEnd: restsShortContentAtEnd, bottomPadding: bottomPadding, showsJumpToNewest: showsJumpToNewest,
            onNearOldest: { [unowned self] in nearOldestCalls += 1 }
        ))
        window.layoutIfNeeded()
    }

    var scrollView: NSScrollView {
        coordinator.container.subviews.compactMap { $0 as? NSScrollView }[0]
    }

    var table: NSTableView {
        guard let table = scrollView.documentView as? NSTableView else { preconditionFailure("The list's document view is its table") }
        return table
    }

    var showsJumpButton: Bool {
        coordinator.container.subviews.contains { $0 is JumpButtonHost && !$0.isHidden }
    }

    var viewport: CGRect {
        scrollView.contentView.bounds
    }

    var contentHeight: CGFloat {
        table.numberOfRows > 0 ? table.rect(ofRow: table.numberOfRows - 1).maxY : 0
    }

    var distanceFromNewest: CGFloat {
        contentHeight - viewport.maxY
    }

    /// How far the row's top sits below the top of the viewport.
    func offset(ofRow index: Int) -> CGFloat {
        table.rect(ofRow: index).minY - viewport.minY
    }

    /// Stands in for the reader's own scroll.
    func scroll(toY y: CGFloat) {
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func resize(width: CGFloat = 400, height: CGFloat = 500) {
        window.setContentSize(NSSize(width: width, height: height))
        window.layoutIfNeeded()
    }

    /// The realized cell of a row.
    func cell(ofRow index: Int) -> TranscriptListCell? {
        table.view(atColumn: 0, row: index, makeIfNecessary: false) as? TranscriptListCell
    }
}

@MainActor
struct TranscriptListCoordinatorTests {
    private func rows(_ count: Int) -> [TranscriptRow] {
        (0 ..< count).map { makeTranscriptRow(body: "Message \($0) " + String(repeating: "with some more words ", count: $0 % 7)) }
    }

    /// A harness showing `count` rows, scrolled up so that its scroller holds a reading position.
    private func scrolledUp(_ count: Int = 200) throws -> ScrolledUpList {
        let harness = ListHarness()
        let scroller = TranscriptScroller()
        let rows = rows(count)
        harness.show(rows, scroller: scroller)
        harness.scroll(toY: harness.viewport.minY - 2000)
        guard case let .reading(id, _) = scroller.position else {
            throw ListError.notReading
        }
        return try ScrolledUpList(harness: harness, scroller: scroller, rows: rows, held: #require(rows.firstIndex { $0.id == id }))
    }

    private struct ScrolledUpList {
        let harness: ListHarness
        let scroller: TranscriptScroller
        var rows: [TranscriptRow]
        /// The index of the row the scroller's position names.
        var held: Int
    }

    private enum ListError: Error {
        case notReading
    }

    private final class ChangeAtRest {
        var hasRun = false
    }

    @Test func `at the newest message an append and a growing last row keep the end in view`() {
        let harness = ListHarness()
        let scroller = TranscriptScroller()
        var rows = rows(120)
        harness.show(rows, scroller: scroller)
        // Armed: there is more than fits, and the view is at its end.
        #expect(harness.contentHeight > 2 * harness.viewport.height)
        #expect(abs(harness.distanceFromNewest) < 0.5)
        #expect(scroller.isAtNewest)

        rows.append(makeTranscriptRow(body: "One more"))
        harness.show(rows, scroller: scroller)
        #expect(abs(harness.distanceFromNewest) < 0.5)

        let last = rows[rows.count - 1]
        rows[rows.count - 1] = makeTranscriptRow(id: last.id, body: String(repeating: "This one grew a lot. ", count: 30))
        harness.show(rows, scroller: scroller)
        #expect(abs(harness.distanceFromNewest) < 0.5)
        #expect(scroller.isAtNewest)
    }

    @Test func `at the newest message a viewport that changes height keeps the end in view`() {
        let harness = ListHarness()
        let scroller = TranscriptScroller()
        harness.show(rows(120), scroller: scroller)

        for height: CGFloat in [380, 560] {
            harness.resize(height: height)
            #expect(abs(harness.distanceFromNewest) < 0.5)
            #expect(scroller.isAtNewest)
        }
    }

    @Test func `a cell on screen shows its row's new value`() throws {
        let harness = ListHarness()
        let scroller = TranscriptScroller()
        var rows = rows(10)
        harness.show(rows, scroller: scroller)
        let last = rows.count - 1

        rows[last] = makeTranscriptRow(id: rows[last].id, body: "Corrected")
        harness.show(rows, scroller: scroller)

        #expect(try #require(harness.cell(ofRow: last)).content.row == rows[last])
    }

    @Test func `at a reading position a prepend, a change above, and a width change leave the held row where it is`() throws {
        let list = try scrolledUp()
        let (harness, scroller) = (list.harness, list.scroller)
        var (rows, held) = (list.rows, list.held)
        let offset = harness.offset(ofRow: held)
        #expect(!scroller.isAtNewest)

        let older = self.rows(50)
        rows = older + rows
        held += older.count
        harness.show(rows, scroller: scroller)
        #expect(abs(harness.offset(ofRow: held) - offset) < 0.5)

        let above = held - 3
        rows[above] = makeTranscriptRow(id: rows[above].id, body: String(repeating: "Corrected to something longer. ", count: 20))
        harness.show(rows, scroller: scroller)
        #expect(abs(harness.offset(ofRow: held) - offset) < 0.5)

        harness.resize(width: 320)
        #expect(abs(harness.offset(ofRow: held) - offset) < 0.5)
    }

    /// That the view is not put back after such a scroll matters only during elastic overscroll past either end, which
    /// no test can produce: there the clip view clamps a programmatic scroll.
    @Test func `the reader's own scroll becomes the position when nothing was measured`() {
        let harness = ListHarness()
        let scroller = TranscriptScroller()
        harness.show(rows(10), scroller: scroller)
        // The list's first layout measured only what is on screen. A settle measures the whole reach around it, which
        // with this few rows is all of them, so the scroll below brings no unmeasured row into reach.
        scroller.reset(to: .newest)
        let target = harness.viewport.minY - 37

        harness.scroll(toY: target)

        #expect(harness.viewport.minY == target)
        #expect(!scroller.isAtNewest)
    }

    @Test func `a change waiting for rest runs once a scroll without a gesture has been quiet`() async throws {
        let harness = ListHarness()
        let scroller = TranscriptScroller()
        harness.show(rows(120), scroller: scroller)
        // Armed: the change is handed over right after a scroll, while the list is not at rest. On a machine too busy
        // to get there within the quiet interval, the change runs at once, and the scroll is made again.
        var waiting: ChangeAtRest?
        for _ in 0 ..< 10 where waiting == nil {
            harness.scroll(toY: harness.viewport.minY - 30)
            let change = ChangeAtRest()
            scroller.performWhenAtRest { change.hasRun = true }
            if !change.hasRun {
                waiting = change
            }
        }
        let change = try #require(waiting)

        try await waitUntil { change.hasRun }
    }

    @Test func `another tab's rows and back restores the position`() throws {
        let list = try scrolledUp()
        let (harness, scroller, rows, held) = (list.harness, list.scroller, list.rows, list.held)
        let offset = harness.offset(ofRow: held)
        let other = TranscriptScroller()

        harness.show(self.rows(80), scroller: other)
        #expect(abs(harness.distanceFromNewest) < 0.5)
        harness.resize(width: 360)
        harness.show(rows, scroller: scroller)

        #expect(abs(harness.offset(ofRow: held) - offset) < 0.5)
        #expect(other.isAtNewest)
        #expect(!scroller.isAtNewest)
    }

    @Test func `content shorter than the viewport rests at the end in a chat and at the top in History`() {
        let harness = ListHarness()
        let rows = rows(3)
        harness.show(rows, scroller: TranscriptScroller())
        // Armed: the rows are shorter than the viewport.
        #expect(harness.contentHeight < harness.viewport.height)
        #expect(abs(harness.distanceFromNewest) < 0.5)

        let history = ListHarness()
        history.restsShortContentAtEnd = false
        history.show(rows, scroller: TranscriptScroller())
        #expect(abs(history.offset(ofRow: 0)) < 0.5)
    }

    @Test func `the newest row keeps its padding from the bottom edge, with more than fits and with less`() {
        for count in [120, 3] {
            let harness = ListHarness()
            harness.bottomPadding = 8
            let scroller = TranscriptScroller()
            var rows = rows(count)
            harness.show(rows, scroller: scroller)
            #expect(abs(harness.distanceFromNewest + 8) < 0.5)
            #expect(scroller.isAtNewest)

            rows.append(makeTranscriptRow(body: "One more"))
            harness.show(rows, scroller: scroller)
            #expect(abs(harness.distanceFromNewest + 8) < 0.5)
        }
    }

    @Test func `a day that shares no row with the one before shows from its top`() {
        let harness = ListHarness()
        harness.restsShortContentAtEnd = false
        let scroller = TranscriptScroller()
        harness.show(rows(150), scroller: scroller)
        harness.scroll(toY: 900)
        #expect(scroller.position != .oldest)

        scroller.reset(to: .oldest)
        harness.show(rows(150), scroller: scroller)

        #expect(abs(harness.offset(ofRow: 0)) < 0.5)
        #expect(!scroller.isAtNewest)
    }

    @Test func `a page is asked for after a row change that leaves a scrolled-up view near the top`() {
        let harness = ListHarness()
        let scroller = TranscriptScroller()
        var rows = rows(120)
        harness.show(rows, scroller: scroller)
        // At the newest message with more than fits, nothing is near, however little there is above.
        #expect(harness.nearOldestCalls == 0)

        harness.scroll(toY: 40)
        #expect(harness.nearOldestCalls == 1)
        // Further scrolling near the top asks no second time while nothing changed.
        harness.scroll(toY: 20)
        harness.scroll(toY: 60)
        #expect(harness.nearOldestCalls == 1)

        // A page of two rows leaves the view within one viewport of the top.
        rows = self.rows(2) + rows
        harness.show(rows, scroller: scroller)
        #expect(harness.nearOldestCalls == 2)
    }

    @Test func `a page is asked for when the content is shorter than the viewport`() {
        let harness = ListHarness()

        harness.show(rows(3), scroller: TranscriptScroller())

        #expect(harness.nearOldestCalls == 1)
    }

    @Test func `a change to the top slot alone asks for no page`() {
        let harness = ListHarness()
        let scroller = TranscriptScroller()
        let messages = rows(120)
        let topSlot = { TranscriptRow(id: TranscriptRow.topSlotID, kind: .topSlot(isLoading: $0)) }
        harness.show([topSlot(false)] + messages, scroller: scroller)
        harness.scroll(toY: 40)
        #expect(harness.nearOldestCalls == 1)

        // What a load that fails does: the spinner comes and goes, and nothing else changes.
        harness.show([topSlot(true)] + messages, scroller: scroller)
        harness.show([topSlot(false)] + messages, scroller: scroller)

        #expect(harness.nearOldestCalls == 1)
    }

    @Test func `a reset to the newest message moves a scrolled-up list there and reports it`() throws {
        let list = try scrolledUp()
        let (harness, scroller) = (list.harness, list.scroller)

        #expect(harness.showsJumpButton)

        scroller.reset(to: .newest)

        #expect(abs(harness.distanceFromNewest) < 0.5)
        #expect(scroller.isAtNewest)
        #expect(scroller.position == .newest)
        #expect(!harness.showsJumpButton)
    }

    @Test func `a theme change measures the rows again though none of them changed`() throws {
        let harness = ListHarness()
        let scroller = TranscriptScroller()
        let rows = rows(10)
        harness.show(rows, scroller: scroller)
        let height = harness.contentHeight

        let other = try #require(harness.themeEngine.availableThemes.first { $0 != harness.themeEngine.current })
        harness.themeEngine.selectTheme(other)
        harness.show(rows, scroller: scroller)

        #expect(harness.contentHeight != height)
        #expect(abs(harness.distanceFromNewest) < 0.5)
    }

    @Test func `rows that go away leave the others in place, and the row being read going away keeps the view where it is`() throws {
        let list = try scrolledUp()
        let (harness, scroller) = (list.harness, list.scroller)
        var (rows, held) = (list.rows, list.held)
        let topSlot = TranscriptRow(id: TranscriptRow.topSlotID, kind: .topSlot(isLoading: false))
        harness.show([topSlot] + rows, scroller: scroller)
        let offset = harness.offset(ofRow: held + 1)

        // The top slot goes when history has ended.
        harness.show(rows, scroller: scroller)
        #expect(harness.table.numberOfRows == rows.count)
        #expect(abs(harness.offset(ofRow: held) - offset) < 0.5)

        // The row being read goes: what is on screen then is the place to keep, also through what comes in above.
        rows.remove(at: held)
        harness.show(rows, scroller: scroller)
        let kept = harness.offset(ofRow: held)
        #expect(abs(kept - offset) < 0.5)
        #expect(!scroller.isAtNewest)
        let older = self.rows(20)
        harness.show(older + rows, scroller: scroller)
        #expect(abs(harness.offset(ofRow: held + older.count) - kept) < 0.5)
    }

    @Test func `a list that shows no jump button has none when scrolled up`() {
        let harness = ListHarness()
        harness.showsJumpToNewest = false
        let scroller = TranscriptScroller()
        harness.show(rows(120), scroller: scroller)

        harness.scroll(toY: harness.viewport.minY - 300)

        #expect(!scroller.isAtNewest)
        #expect(!harness.showsJumpButton)
    }

    @Test func `a request for the newest message moves a scrolled-up list there`() throws {
        let list = try scrolledUp()

        list.scroller.scrollToNewest()

        #expect(abs(list.harness.distanceFromNewest) < 0.5)
        #expect(list.scroller.isAtNewest)
    }

    @Test func `revealing a row centers it, and a row the list does not have moves nothing`() throws {
        let list = try scrolledUp()
        let (harness, scroller, rows) = (list.harness, list.scroller, list.rows)
        let before = harness.viewport.minY

        scroller.reveal(UUID())
        #expect(harness.viewport.minY == before)

        scroller.reveal(rows[20].id)
        let frame = harness.table.rect(ofRow: 20)
        #expect(abs(frame.midY - harness.viewport.midY) < 1)
    }
}
