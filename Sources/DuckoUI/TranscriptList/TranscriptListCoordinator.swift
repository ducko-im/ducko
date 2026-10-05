import AppKit
import DuckoCore
import QuartzCore
import SwiftUI

/// Owns the transcript's table, its row diff, and its scroll position. Rows are measured only within one viewport of
/// what is on screen. The rest keep their last known height or an estimate, and the scroller's position is put back
/// after every change, so what is on screen holds still while heights further away are still guesses. Subclasses
/// `NSObject` solely to adopt the AppKit table protocols.
@MainActor
final class TranscriptListCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, TranscriptScrollerList {
    /// How long nothing must have scrolled for scrolling to count as at rest. A mouse wheel reports no gesture, so
    /// for it this alone decides.
    private static let restInterval = 0.1
    /// Measuring a row can change the heights that decide which rows are within reach, so it repeats. Bounded so a
    /// row that never settles cannot hold the main thread.
    private static let maxMeasurePasses = 12
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("transcript-row")

    let container = NSView()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let measurer = TranscriptRowMeasurer()
    private var jumpButton: JumpButtonHost?
    private var inputs: TranscriptListInputs?
    private var rows: [TranscriptRow] = []
    private var observers: [any NSObjectProtocol] = []
    /// Set while the coordinator itself moves the view or changes the table, so those moves are not taken for the
    /// reader's.
    private var isChanging = false
    private var isLiveScrolling = false
    private var lastScrollTime = 0.0
    private var restCheck: Task<Void, Never>?
    private var widthChangeFollowUp: Task<Void, Never>?
    private var isNearOldest = false
    /// Rows came or went before the list had a size, so whether that left the view near the oldest row is still to
    /// be looked at.
    private var hasUncheckedRowChange = false

    private var clipView: NSClipView {
        scrollView.contentView
    }

    private var isLaidOut: Bool {
        tableView.bounds.width > 1 && clipView.bounds.height > 1
    }

    /// The height of the rows. The table's own frame is no measure of it, since a table fills its scroll view.
    private var contentHeight: CGFloat {
        let count = tableView.numberOfRows
        return count > 0 ? tableView.rect(ofRow: count - 1).maxY : 0
    }

    /// What the view scrolls over: the rows and the padding kept below the newest one.
    private var documentHeight: CGFloat {
        contentHeight + scrollView.contentInsets.bottom
    }

    private var isAtNewest: Bool {
        TranscriptLayout.isAtNewest(visible: clipView.bounds, documentHeight: documentHeight)
    }

    override init() {
        super.init()
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = .zero
        tableView.usesAutomaticRowHeights = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        container.setAccessibilityRole(.group)

        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        observe(NSView.boundsDidChangeNotification, of: clipView) { $0.didScroll() }
        observe(NSView.frameDidChangeNotification, of: clipView) { $0.viewportChanged() }
        observe(NSScrollView.willStartLiveScrollNotification, of: scrollView) { $0.isLiveScrolling = true }
        observe(NSScrollView.didEndLiveScrollNotification, of: scrollView) {
            $0.isLiveScrolling = false
            $0.reportRestIfReached()
        }
    }

    isolated deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func observe(_ name: Notification.Name, of object: NSView, _ handle: @escaping @MainActor (TranscriptListCoordinator) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handle(self)
            }
        })
    }

    // MARK: - Updates

    func update(_ newInputs: TranscriptListInputs) {
        let previous = inputs
        inputs = newInputs
        container.setAccessibilityElement(newInputs.accessibilityIdentifier != nil)
        container.setAccessibilityIdentifier(newInputs.accessibilityIdentifier)

        let scroller = newInputs.scroller
        // A page is asked for once the list has applied a change to which rows there are. A change to a row's value
        // alone never asks: a load that fails only turns the top slot's spinner on and off, and must not be retried
        // by that.
        var changedRows = false
        if previous?.scroller !== scroller {
            previous?.scroller.detach(self)
            scroller.attach(self)
            rows = newInputs.rows
            reload()
            changedRows = true
        } else if rows != newInputs.rows {
            changedRows = apply(newInputs.rows)
        } else {
            return
        }
        if changedRows {
            scroller.heights.keep(Set(rows.map(\.id)))
        }
        bindJumpButton()
        settleOrPerformRequest()
        if changedRows {
            noteNearOldest(afterRowChange: true)
        }
    }

    /// The button lives in the list, above the table, so that scrolling with the pointer over it still scrolls the
    /// transcript. It is centered: at the trailing edge it would sit on the scroll bar. Each settle shows or hides it.
    private func bindJumpButton() {
        guard let inputs, inputs.showsJumpToNewest else { return }
        let content = JumpToNewestButton(scroller: inputs.scroller)
        if let jumpButton {
            jumpButton.rootView = content
            return
        }
        let host = JumpButtonHost(rootView: content)
        host.scrollView = scrollView
        host.isHidden = true
        // The button has one size. Left to size itself, the hosting view would have a say in the container's.
        let size = host.fittingSize
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: size.width),
            host.heightAnchor.constraint(equalToConstant: size.height),
            host.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        jumpButton = host
    }

    /// Called when the list goes away, so its scroller is not left waiting on it.
    func detach() {
        restCheck?.cancel()
        widthChangeFollowUp?.cancel()
        inputs?.scroller.detach(self)
    }

    private func reload() {
        isChanging = true
        defer { isChanging = false }
        tableView.reloadData()
        // The table takes its new size at its next layout, and moves the view while doing so. Done here, that move
        // is not taken for the reader's, and the settle that follows puts the view where it belongs.
        tableView.layoutSubtreeIfNeeded()
    }

    /// Returns whether rows came or went.
    private func apply(_ newRows: [TranscriptRow]) -> Bool {
        let oldIDs = rows.map(\.id)
        let newIDs = newRows.map(\.id)
        rows = newRows
        guard oldIDs != newIDs else {
            refreshRealizedCells()
            return false
        }
        // With no row left of what was shown, there is nothing to keep in place.
        guard !Set(oldIDs).isDisjoint(with: newIDs) else {
            reload()
            return true
        }
        let (removals, insertions) = newIDs.difference(from: oldIDs).rowChanges
        isChanging = true
        tableView.beginUpdates()
        if !removals.isEmpty { tableView.removeRows(at: removals, withAnimation: []) }
        if !insertions.isEmpty { tableView.insertRows(at: insertions, withAnimation: []) }
        tableView.endUpdates()
        tableView.layoutSubtreeIfNeeded()
        isChanging = false
        refreshRealizedCells()
        return true
    }

    /// Re-hosts the cells whose row kept its id but changed value. The row diff only builds inserted rows.
    private func refreshRealizedCells() {
        guard let inputs else { return }
        tableView.enumerateAvailableRowViews { _, index in
            guard rows.indices.contains(index),
                  let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TranscriptListCell,
                  cell.content.row != rows[index] else { return }
            cell.update(content: content(for: rows[index], inputs: inputs))
        }
    }

    private func content(for row: TranscriptRow, inputs: TranscriptListInputs) -> TranscriptRowView {
        TranscriptRowView(row: row, context: inputs.context, environment: inputs.environment, remoteImageConsent: inputs.remoteImageConsent)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row), let inputs else { return TranscriptHeights.estimate }
        return inputs.scroller.heights.height(of: rows[row].id)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let inputs else { return nil }
        let content = content(for: rows[row], inputs: inputs)
        if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? TranscriptListCell {
            reused.update(content: content)
            return reused
        }
        // The table sets each row's height from its measured height, so the hosting view takes no part in sizing.
        let cell = TranscriptListCell(content: content, sizingOptions: [])
        cell.identifier = Self.cellIdentifier
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    // MARK: - Position

    private func index(of id: UUID) -> Int? {
        rows.firstIndex { $0.id == id }
    }

    /// Where the view is now. The top slot is never what is being read: rows are inserted right below it.
    private func currentPosition() -> TranscriptPosition {
        guard let heights = inputs?.scroller.heights else { return .newest }
        let visible = clipView.bounds
        let range = tableView.rows(in: visible)
        let visibleRows = (range.location ..< range.location + range.length).compactMap { index -> TranscriptLayout.Row? in
            guard rows.indices.contains(index), rows[index].id != TranscriptRow.topSlotID else { return nil }
            return TranscriptLayout.Row(id: rows[index].id, frame: tableView.rect(ofRow: index), isMeasured: heights.isMeasured(rows[index]))
        }
        return TranscriptLayout.position(visible: visible, documentHeight: documentHeight, rows: visibleRows)
    }

    private func scroll(to position: TranscriptPosition) {
        var rowFrame: CGRect?
        if case let .reading(id, _) = position {
            rowFrame = index(of: id).map { tableView.rect(ofRow: $0) }
        }
        let viewportHeight = clipView.bounds.height
        guard let origin = TranscriptLayout.origin(
            for: position, rowFrame: rowFrame, documentHeight: documentHeight, viewportHeight: viewportHeight
        ) else { return }
        // Short content resting at the end is held there by a top inset, which the offset runs into.
        let top = -scrollView.contentInsets.top
        let end = max(top, documentHeight - viewportHeight)
        clipView.setBoundsOrigin(NSPoint(x: 0, y: min(max(top, origin), end)))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// Returns whether the insets changed.
    private func updateContentInsets(_ inputs: TranscriptListInputs) -> Bool {
        let top = inputs.restsShortContentAtEnd ? max(0, clipView.bounds.height - contentHeight - inputs.bottomPadding) : 0
        let insets = scrollView.contentInsets
        guard insets.top != top || insets.bottom != inputs.bottomPadding else { return false }
        scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: inputs.bottomPadding, right: 0)
        return true
    }

    /// Measures the unmeasured rows within reach, reporting which changed height.
    private func measureRows(in reach: CGRect, inputs: TranscriptListInputs) -> IndexSet {
        let width = tableView.bounds.width
        let range = tableView.rows(in: reach)
        var changed = IndexSet()
        for index in range.location ..< range.location + range.length
            where rows.indices.contains(index) && !inputs.scroller.heights.isMeasured(rows[index]) {
            let height = measurer.height(of: content(for: rows[index], inputs: inputs), width: width)
            if inputs.scroller.heights.record(height, for: rows[index]) {
                changed.insert(index)
            }
        }
        return changed
    }

    private func noteHeights(ofRows changed: IndexSet) {
        // A view-based table animates a height change unless told not to.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: changed)
        }
    }

    /// Measures the rows within one viewport of what `position` shows and puts the view there, repeating until
    /// nothing in reach is left unmeasured. After the reader's own scroll the view already is where `position` says,
    /// so it is only put back once a measurement has moved it: putting it back unasked would cut off the elastic
    /// overscroll at either end.
    private func settle(at requested: TranscriptPosition, afterUserScroll: Bool = false, measuringOnlyVisible: Bool = false) {
        guard let inputs else { return }
        guard isLaidOut else {
            inputs.scroller.report(requested, isAtNewest: requested == .newest)
            return
        }
        var position = requested
        if case let .reading(id, _) = position, index(of: id) == nil {
            // The row that was being read is gone, so what is on screen now is the place to keep.
            position = currentPosition()
        }
        isChanging = true
        defer { isChanging = false }
        inputs.scroller.heights.prepare(width: tableView.bounds.width)
        var needsScroll = !afterUserScroll
        for _ in 0 ..< Self.maxMeasurePasses {
            if needsScroll { scroll(to: position) }
            let reach = measuringOnlyVisible ? clipView.bounds : clipView.bounds.insetBy(dx: 0, dy: -clipView.bounds.height)
            let changed = measureRows(in: reach, inputs: inputs)
            if changed.isEmpty { break }
            noteHeights(ofRows: changed)
            needsScroll = true
        }
        if updateContentInsets(inputs) { needsScroll = true }
        if needsScroll { scroll(to: position) }
        // A reading position that ended up at the newest message is one: the view follows new messages from there.
        if case .reading = position, isAtNewest { position = .newest }
        inputs.scroller.report(position, isAtNewest: isAtNewest)
        jumpButton?.isHidden = isAtNewest
    }

    private func settleOrPerformRequest() {
        guard let scroller = inputs?.scroller else { return }
        guard isLaidOut, let request = scroller.takeRequest() else {
            settle(at: scroller.position)
            return
        }
        switch request {
        case .newest:
            settle(at: .newest)
        case let .reveal(id):
            reveal(id)
        }
    }

    /// Settles with the row centered. A row the list does not have moves nothing.
    private func reveal(_ id: UUID) {
        guard let inputs, let index = index(of: id) else {
            settle(at: inputs?.scroller.position ?? .newest)
            return
        }
        inputs.scroller.heights.prepare(width: tableView.bounds.width)
        let changed = measureRows(in: tableView.rect(ofRow: index), inputs: inputs)
        if !changed.isEmpty {
            isChanging = true
            noteHeights(ofRows: changed)
            isChanging = false
        }
        let height = inputs.scroller.heights.height(of: id)
        settle(at: .reading(id: id, offset: max(0, (clipView.bounds.height - height) / 2)))
    }

    // MARK: - TranscriptScrollerList

    var isAtRest: Bool {
        !isLiveScrolling && CACurrentMediaTime() - lastScrollTime >= Self.restInterval
    }

    func takePendingRequest() {
        settleOrPerformRequest()
    }

    func settle(at position: TranscriptPosition) {
        settle(at: position, afterUserScroll: false)
    }

    // MARK: - Scrolling

    private func didScroll() {
        guard !isChanging, inputs != nil else { return }
        lastScrollTime = CACurrentMediaTime()
        settle(at: currentPosition(), afterUserScroll: true)
        noteNearOldest(afterRowChange: false)
        restCheck?.cancel()
        restCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.restInterval + 0.02))
            guard !Task.isCancelled else { return }
            self?.reportRestIfReached()
        }
    }

    private func viewportChanged() {
        guard !isChanging, let inputs else { return }
        tableView.sizeLastColumnToFit()
        if isLaidOut, inputs.scroller.heights.width != tableView.bounds.width {
            // At a new width every height is a guess again. While the width keeps changing, as it does on each step
            // of a window resize, only the rows on screen are measured, which is what keeps a step short. The rest of
            // the reach follows once the width has held for a moment.
            settle(at: inputs.scroller.position, measuringOnlyVisible: true)
            widthChangeFollowUp?.cancel()
            widthChangeFollowUp = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.restInterval))
                guard !Task.isCancelled else { return }
                self?.settleOrPerformRequest()
            }
        } else {
            settleOrPerformRequest()
        }
        if hasUncheckedRowChange {
            noteNearOldest(afterRowChange: true)
        }
    }

    private func reportRestIfReached() {
        guard isAtRest else { return }
        inputs?.scroller.listCameToRest()
    }

    /// The view is near the oldest loaded row when its top is within one viewport of it, and the reader is away from
    /// the newest message or the content is shorter than the viewport. At the newest message with more content than
    /// fits, nothing is near: a chat opens on what it loaded and stays there until the reader scrolls up.
    private func noteNearOldest(afterRowChange: Bool) {
        guard let inputs else { return }
        guard isLaidOut else {
            hasUncheckedRowChange = hasUncheckedRowChange || afterRowChange
            return
        }
        hasUncheckedRowChange = false
        let viewportHeight = clipView.bounds.height
        let wasNear = isNearOldest
        isNearOldest = clipView.bounds.minY < viewportHeight && (!inputs.scroller.isAtNewest || documentHeight < viewportHeight)
        if isNearOldest, afterRowChange || !wasNear {
            inputs.onNearOldest()
        }
    }
}

typealias TranscriptListCell = HostingTableCellView<TranscriptRowView>

/// Hosts the jump button above the table. A scroll with the pointer over the button goes to the transcript.
final class JumpButtonHost: NSHostingView<JumpToNewestButton> {
    weak var scrollView: NSScrollView?

    override func scrollWheel(with event: NSEvent) {
        scrollView?.scrollWheel(with: event)
    }
}
