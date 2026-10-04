import AppKit
import DuckoCore
import QuartzCore
import SwiftUI

/// The inputs the SwiftUI `ContactListTableView` pushes into its coordinator on
/// each `updateNSView`, bundled into one value so the push is a single
/// assignment rather than a property-by-property triple-touch (declare, assign,
/// read). `@MainActor` because the ref/closure inputs never leave the main
/// actor.
@MainActor
struct ContactListTableInputs {
    var environment: AppEnvironment?
    var theme: ThemeEngine?
    var openChat = OpenChatAction { _, _ in }
    var openWindow: OpenWindowAction?
    var transcriptScope: TranscriptScope?
    var presentSheet: (ContactListRowSheet) -> Void = { _ in }
    var requestRemoval: (Contact) -> Void = { _ in }
    var onSelectionChange: (ContactListRow?) -> Void = { _ in }
    var preferences: ContactListPreferences?
    var incomingRows: [ContactListRow] = []
    var chromeHeight: CGFloat = 0
    var autoSizeVertical = true
    var autoSizeHorizontal = true
    var maxWidthPreference = ContactListSizingDefaults.defaultMaxWidth
    var hasConnectedAccount = false
}

/// AppKit contact list: a view-based `NSTableView` whose cells host the
/// SwiftUI rows, owning both the animated row diff and a top-left-anchored
/// `NSWindow` frame resize so the two co-animate in one transaction.
@MainActor
struct ContactListTableView: NSViewRepresentable {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.openChat) private var openChat
    @Environment(\.openWindow) private var openWindow
    @Environment(TranscriptScope.self) private var transcriptScope

    let rows: [ContactListRow]
    let preferences: ContactListPreferences
    let chromeHeight: CGFloat
    let autoSizeVertical: Bool
    let autoSizeHorizontal: Bool
    let maxWidthPreference: Double
    let hasConnectedAccount: Bool
    let presentSheet: (ContactListRowSheet) -> Void
    let requestRemoval: (Contact) -> Void
    let onSelectionChange: (ContactListRow?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.makeContainer()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.inputs = ContactListTableInputs(
            environment: environment,
            theme: theme,
            openChat: openChat,
            openWindow: openWindow,
            transcriptScope: transcriptScope,
            presentSheet: presentSheet,
            requestRemoval: requestRemoval,
            onSelectionChange: onSelectionChange,
            preferences: preferences,
            incomingRows: rows,
            chromeHeight: chromeHeight,
            autoSizeVertical: autoSizeVertical,
            autoSizeHorizontal: autoSizeHorizontal,
            maxWidthPreference: maxWidthPreference,
            hasConnectedAccount: hasConnectedAccount
        )
        coordinator.reconcile()
    }

    /// Owns the table, the row diff, selection-to-open routing, name/height
    /// measurement, and the co-animated window-frame resize. Subclasses
    /// `NSObject` solely to adopt the AppKit table/menu delegate protocols.
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        fileprivate var inputs = ContactListTableInputs()

        private var rows: [ContactListRow] = []
        private var rowHeights: [CGFloat] = []
        private var lastReportedRowID: String?
        private var lastAppliedKey: ContactListResize.LayoutKey?
        private var pendingInitialApply = true
        private let measurement = ContactListMeasurement()
        private let resizeGate = ContactListResizeGate()
        private var didInstallGate = false

        isolated deinit {
            // Restore SwiftUI's original window delegate if we proxied it.
            if didInstallGate, let window = tableView?.window, window.delegate === resizeGate {
                window.delegate = resizeGate.downstream
            }
        }

        private weak var container: NSView?
        private weak var scrollView: NSScrollView?
        private weak var tableView: ContactListTableControl?

        private static let cellIdentifier = NSUserInterfaceItemIdentifier("contact-cell")

        // MARK: - View construction

        func makeContainer() -> NSView {
            let table = ContactListTableControl()
            table.headerView = nil
            table.style = .plain
            table.backgroundColor = .clear
            table.selectionHighlightStyle = .regular
            table.allowsEmptySelection = true
            table.allowsMultipleSelection = false
            table.intercellSpacing = NSSize(width: 0, height: 0)
            table.usesAutomaticRowHeights = false
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("contact"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.dataSource = self
            table.delegate = self
            table.onOpenRow = { [weak self] in self?.openRow($0) }
            table.onReturn = { [weak self] in self?.openSelectedRow() }
            // Setting the table's own menu (populated per-row by the delegate)
            // lets NSTableView's default contextual-menu path draw the native
            // rounded emphasis on the clicked row.
            let contextMenu = NSMenu()
            contextMenu.delegate = self
            table.menu = contextMenu

            let scrollView = NSScrollView()
            scrollView.documentView = table
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.automaticallyAdjustsContentInsets = false

            let container = NSView()
            container.addSubview(scrollView)
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: container.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            // Re-expose the connectivity gate the integration harness polls:
            // `contact-list` identifier + `connected`/`connecting` value on a
            // container element whose descendants are the table's rows.
            container.setAccessibilityElement(true)
            container.setAccessibilityRole(.group)
            container.setAccessibilityIdentifier("contact-list")
            container.setAccessibilityValue(inputs.hasConnectedAccount ? "connected" : "connecting")

            self.container = container
            self.scrollView = scrollView
            tableView = table
            return container
        }

        // MARK: - Reconciliation

        func reconcile() {
            guard inputs.theme != nil, inputs.environment != nil, inputs.preferences != nil,
                  let tableView, let scrollView else { return }
            defer { reportSelection() }

            container?.setAccessibilityValue(inputs.hasConnectedAccount ? "connected" : "connecting")

            // Window policy (the resize-gate axis locks) must track the auto-size
            // prefs on every pass, before the layout-key bail below: a pure
            // preference toggle doesn't change the key, so applying it only in
            // `applyLayout` would leave the gate stale until an unrelated reconcile.
            updateResizeGateLocks()

            let contentWidth = measurement.contentWidth(inputs: inputs, manualWidth: manualContentWidth())
            let geometry = measurement.heights(
                inputs: inputs, contentWidth: contentWidth, maxListHeight: maxListHeight, cellContent: cellContent
            )
            let newHeights = geometry.newHeights
            let listHeight = geometry.listHeight

            // Auto-size mode fits the window to the roster, so a scroller is only
            // needed when the roster exceeds the screen cap; keeping it off
            // otherwise avoids the overlay scroller flashing over the trailing
            // avatars while rows insert/remove during a resize. Manual mode lets
            // the user shrink the window below the roster, so the scroller must
            // stay available there.
            scrollView.hasVerticalScroller = !inputs.autoSizeVertical || listHeight >= maxListHeight

            let window = tableView.window
            let targetContentSize = targetContentSize(window: window, contentWidth: contentWidth, listHeight: listHeight)
            let scale = window?.backingScaleFactor ?? scrollView.window?.backingScaleFactor ?? 2
            let key = ContactListResize.LayoutKey(
                rowIDs: inputs.incomingRows.map(\.id),
                contentSize: targetContentSize,
                scale: scale
            )
            // A matching key means geometry is unchanged, but a value-passed
            // field (not read reactively) like a group header's online count can
            // still differ, so re-host the visible cells. `rowIDs` are part of the
            // key, so they're identical on a bail and swapping rows is safe.
            guard key != lastAppliedKey else {
                refreshPersistingCells(newRows: inputs.incomingRows)
                rows = inputs.incomingRows
                return
            }

            applyLayout(newHeights: newHeights, targetContentSize: targetContentSize, key: key, window: window, tableView: tableView)
        }

        /// Measures the AppKit terms — the title-bar inset and the window's
        /// current content size — and delegates the per-axis composition to
        /// `ContactListSizing.targetContentSize`, which owns that contract.
        private func targetContentSize(window: NSWindow?, contentWidth: CGFloat, listHeight: CGFloat) -> CGSize {
            ContactListSizing.targetContentSize(
                autoSizeHorizontal: inputs.autoSizeHorizontal,
                autoSizeVertical: inputs.autoSizeVertical,
                contentWidth: contentWidth,
                listHeight: listHeight,
                chromeHeight: inputs.chromeHeight,
                titlebarInset: titlebarInset(window),
                floorWidth: ContactListWidthMetrics.floor,
                maxWidth: clampedMaxWidth,
                currentContentSize: window.map { $0.contentRect(forFrameRect: $0.frame).size }
            )
        }

        /// Strip the full-size-content title bar reserves above SwiftUI's safe
        /// area. Constant for a given window regardless of its size.
        private func titlebarInset(_ window: NSWindow?) -> CGFloat {
            guard let window, let contentView = window.contentView else { return 0 }
            return max(0, contentView.frame.height - window.contentLayoutRect.height)
        }

        /// Applies the new rows and target frame. The first pass (and Reduce
        /// Motion) applies non-animated; every later pass co-animates the row
        /// diff and the top-left-anchored frame in one `NSAnimationContext`.
        private func applyLayout(
            newHeights: [CGFloat],
            targetContentSize: CGSize,
            key: ContactListResize.LayoutKey,
            window: NSWindow?,
            tableView: ContactListTableControl
        ) {
            let oldIDs = rows.map(\.id)
            let newIDs = inputs.incomingRows.map(\.id)
            let heightsChanged = newHeights != rowHeights

            guard let window else {
                rows = inputs.incomingRows
                rowHeights = newHeights
                tableView.reloadData()
                return
            }
            lastAppliedKey = key
            installResizeGate(on: window)

            let drivesFrame = inputs.autoSizeVertical || inputs.autoSizeHorizontal
            let targetFrame: CGRect? = drivesFrame ? frame(for: targetContentSize, window: window) : nil
            let animate = !pendingInitialApply && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            pendingInitialApply = false

            guard animate else {
                rows = inputs.incomingRows
                rowHeights = newHeights
                tableView.reloadData()
                if let targetFrame { setFrameAllowingResize(window, targetFrame) }
                return
            }

            // Co-animate the row insert/remove and the window frame in one
            // transaction (same duration), so the child rows slide up into the
            // group header on collapse and down out of it on expand, in lockstep
            // with the window edge. `allowProgrammaticResize` lets the gate's
            // `windowWillResize` pass this through while still vetoing user drags.
            refreshPersistingCells(newRows: inputs.incomingRows)
            rows = inputs.incomingRows
            rowHeights = newHeights
            resizeGate.allowProgrammaticResize = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = targetFrame.map { window.animationResizeTime($0) } ?? 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                if oldIDs != newIDs {
                    applyRowDiff(old: oldIDs, new: newIDs)
                } else if heightsChanged {
                    tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< rows.count))
                }
                if let targetFrame {
                    window.animator().setFrame(targetFrame, display: true)
                }
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.resizeGate.allowProgrammaticResize = false }
            }
        }

        /// `setFrame` with the resize gate temporarily allowing it (the gate
        /// otherwise pins a locked axis, so a programmatic set would be vetoed).
        private func setFrameAllowingResize(_ window: NSWindow, _ frame: CGRect) {
            resizeGate.allowProgrammaticResize = true
            window.setFrame(frame, display: true)
            resizeGate.allowProgrammaticResize = false
        }

        /// Syncs the resize gate's per-axis veto with the current auto-size prefs.
        private func updateResizeGateLocks() {
            resizeGate.lockWidth = inputs.autoSizeHorizontal
            resizeGate.lockHeight = inputs.autoSizeVertical
        }

        /// Installs the window-delegate proxy that vetoes user resize on the
        /// auto-size axes. SwiftUI re-asserts `.resizable` / `contentMaxSize` /
        /// `styleMask`, so `windowWillResize` is the only hook that holds; the
        /// proxy forwards every other delegate message to SwiftUI's delegate. The
        /// axis locks themselves are kept current by `updateResizeGateLocks`.
        private func installResizeGate(on window: NSWindow) {
            guard !didInstallGate else { return }
            if window.delegate !== resizeGate {
                resizeGate.downstream = window.delegate
                window.delegate = resizeGate
            }
            didInstallGate = true
        }

        private func applyRowDiff(old: [String], new: [String]) {
            guard let tableView else { return }
            let (removals, insertions) = new.difference(from: old).rowChanges
            // Slide vertically so children move into/out of the group header
            // (collapse slides up, expand slides down), the standard disclosure
            // motion — in lockstep with the window edge via the shared context.
            tableView.beginUpdates()
            if !removals.isEmpty { tableView.removeRows(at: removals, withAnimation: .slideUp) }
            if !insertions.isEmpty { tableView.insertRows(at: insertions, withAnimation: .slideDown) }
            tableView.endUpdates()
        }

        /// Re-host cells whose backing row kept its identity but changed content
        /// — a group header's chevron and count on collapse/expand. The row diff
        /// only (re)builds inserted rows, so a header that stays put would keep
        /// its stale `isExpanded`. Matches each realized view by its current
        /// (pre-swap) index to the new row of the same id, so it must run before
        /// `rows` is replaced.
        private func refreshPersistingCells(newRows: [ContactListRow]) {
            guard let tableView else { return }
            let newByID = Dictionary(newRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            tableView.enumerateAvailableRowViews { _, index in
                guard rows.indices.contains(index),
                      let newRow = newByID[rows[index].id],
                      let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ContactListCellView,
                      let content = cellContent(for: newRow) else { return }
                cell.update(content: content)
            }
        }

        private func frame(for contentSize: CGSize, window: NSWindow) -> CGRect {
            let frameSize = window.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize)).size
            return ContactListResize.topLeftAnchoredFrame(current: window.frame, targetSize: frameSize)
        }

        // MARK: - Measurement

        private var clampedMaxWidth: CGFloat {
            CGFloat(ContactListSizing.clampMaxWidth(inputs.maxWidthPreference))
        }

        private var maxListHeight: CGFloat {
            (NSScreen.main?.visibleFrame.height ?? 800) - 160
        }

        private func manualContentWidth() -> CGFloat {
            if let window = tableView?.window {
                return window.contentRect(forFrameRect: window.frame).width
            }
            return scrollView?.bounds.width ?? ContactListWidthMetrics.floor
        }

        // MARK: - Cell content

        private func cellContent(for row: ContactListRow) -> ContactListCellContent? {
            guard let environment = inputs.environment, let theme = inputs.theme else { return nil }
            return ContactListCellContent(
                row: row,
                environment: environment,
                theme: theme,
                openChat: inputs.openChat,
                toggle: { [weak self] sectionKey in self?.inputs.preferences?.toggleGroupExpanded(sectionKey) },
                showMenu: { [weak self] in self?.showAccessibilityMenu(forRowID: row.id) }
            )
        }

        /// Opens the row's context menu in response to an AX/VoiceOver show-menu
        /// action (the mouse path is the table-owned `NSMenu`, which draws the
        /// native emphasis; the SwiftUI element carrying `contact-row-*` can't
        /// reach that menu, so this bridges it). Deferred to the next runloop
        /// tick: `NSMenu.popUp` runs a modal tracking loop, so opening it inline
        /// would block the out-of-process AX action call until dismissal and the
        /// menu would never be observed.
        private func showAccessibilityMenu(forRowID id: String) {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.presentRowMenu(forRowID: id) }
            }
        }

        private func presentRowMenu(forRowID id: String) {
            guard let tableView, let index = rows.firstIndex(where: { $0.id == id }),
                  let menu = contextMenu(forRow: index) else { return }
            let rowRect = tableView.rect(ofRow: index)
            menu.popUp(positioning: nil, at: NSPoint(x: rowRect.midX, y: rowRect.midY), in: tableView)
        }

        // MARK: - Selection / open

        private func openRow(_ index: Int) {
            guard rows.indices.contains(index), let key = rows[index].selectionKey else { return }
            inputs.openChat(key.jid, accountID: key.accountID)
        }

        private func openSelectedRow() {
            guard let tableView, tableView.selectedRow >= 0 else { return }
            openRow(tableView.selectedRow)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            reportSelection()
        }

        /// Publishes the selected row for the menu-bar commands. `reconcile()` reports too, because `reloadData()` and
        /// the row diff move the selection without posting a selection change. It reports only when the row identity
        /// changes. `reconcile()` runs on every `updateNSView`, and the App body reads the published row, so an
        /// unconditional write would loop into another `updateNSView`.
        private func reportSelection() {
            guard let tableView else { return }
            let index = tableView.selectedRow
            let row = rows.indices.contains(index) ? rows[index] : nil
            guard row?.id != lastReportedRowID else { return }
            lastReportedRowID = row?.id
            inputs.onSelectionChange(row)
        }

        // MARK: - Context menu (NSMenuDelegate)

        /// Populates the table-owned menu for the right-clicked row just before
        /// it opens. Because the menu is table-owned, `NSTableView`'s default
        /// contextual path draws the native rounded emphasis on `clickedRow`.
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView else { return }
            let clickedRow = tableView.clickedRow
            guard let built = contextMenu(forRow: clickedRow) else { return }
            let items = built.items
            built.removeAllItems()
            for item in items {
                menu.addItem(item)
            }
        }

        /// Builds the row's right-click menu as an AppKit `NSMenu`. Item titles
        /// and AX identifiers must stay in sync with the integration suite that
        /// polls them; the sheets are SwiftUI, presented via `presentSheet`.
        private func contextMenu(forRow index: Int) -> NSMenu? {
            guard rows.indices.contains(index), let environment = inputs.environment else { return nil }
            return ContactListMenuBuilder(
                openChat: inputs.openChat, openWindow: inputs.openWindow, transcriptScope: inputs.transcriptScope,
                presentSheet: inputs.presentSheet, requestRemoval: inputs.requestRemoval, target: self, action: #selector(performMenuItem(_:))
            )
            .menu(for: rows[index], environment: environment)
        }

        @objc private func performMenuItem(_ sender: NSMenuItem) {
            (sender.representedObject as? MenuCommand)?.run()
        }

        // MARK: - NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        // MARK: - NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let content = cellContent(for: rows[row]) else { return nil }
            if let reused = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? ContactListCellView {
                reused.update(content: content)
                return reused
            }
            let cell = ContactListCellView(content: content)
            cell.identifier = Self.cellIdentifier
            return cell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            rowHeights.indices.contains(row) ? rowHeights[row] : (inputs.theme?.current.avatarSize ?? 40) + ContactListMeasurement.estimatedRowChrome
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            rows.indices.contains(row) ? rows[row].isSelectable : false
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            rows.indices.contains(row) ? rows[row].typeSelectString : nil
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            false
        }
    }
}

/// View-based `NSTableView` that owns keyboard (Return-to-open),
/// double-click-to-open, and the per-row right-click menu. Keyboard and
/// double-click stay selector-free closures; the menu is a table-owned
/// `NSMenu` so `NSTableView` draws its native rounded context emphasis.
final class ContactListTableControl: NSTableView {
    var onOpenRow: ((Int) -> Void)?
    var onReturn: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        // Return / keypad Enter opens the selected row's chat; arrows and
        // type-select stay the table's own.
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        if clickedRow >= 0 { onOpenRow?(clickedRow) }
    }
}

/// Boxes a `@MainActor` closure so it can ride an `NSMenuItem.representedObject`
/// and be invoked by the coordinator's single `@objc` action trampoline.
@MainActor
final class MenuCommand {
    let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        self.run = run
    }
}

/// Window-delegate proxy that vetoes a USER resize on each locked (auto-size)
/// axis via `windowWillResize`, while letting the coordinator's own animated
/// `setFrame` through (`allowProgrammaticResize`). This is the only hook that
/// actually holds — SwiftUI re-asserts `.windowResizability` / `styleMask` /
/// `contentMaxSize`. Every other delegate message is forwarded to SwiftUI's
/// original delegate so scene behavior (close, restoration, etc.) is preserved.
@MainActor
final class ContactListResizeGate: NSObject, NSWindowDelegate {
    weak var downstream: NSWindowDelegate?
    var lockWidth = false
    var lockHeight = false
    var allowProgrammaticResize = false

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !allowProgrammaticResize else { return frameSize }
        var size = frameSize
        if lockWidth { size.width = sender.frame.width }
        if lockHeight { size.height = sender.frame.height }
        return size
    }

    /// Keep the edge resize affordance in sync with the axis locks. When both
    /// axes are locked, suppress the misleading resize cursor: SwiftUI keeps
    /// re-adding `.resizable` (a one-time removal doesn't hold), so re-remove it
    /// whenever it reappears (`windowWillResize` already vetoes the drag, and
    /// programmatic `setFrame` works without `.resizable`). Otherwise restore
    /// `.resizable` if it's missing, so unlocking an axis at runtime brings the
    /// handle back immediately rather than waiting for SwiftUI's next re-assert.
    /// Mixed auto/manual modes keep `.resizable` and rely on the per-axis veto.
    func windowDidUpdate(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if lockWidth, lockHeight {
            if window.styleMask.contains(.resizable) { window.styleMask.remove(.resizable) }
        } else if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (downstream?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        super.responds(to: aSelector) ? self : downstream
    }
}

/// The cell hosting one contact-list row. The hosting view keeps its own sizing, so the table's measured row height
/// and the SwiftUI fitting size agree.
typealias ContactListCellView = HostingTableCellView<ContactListCellContent>

/// The single concrete SwiftUI view a hosted cell renders, switching on the row
/// kind and re-injecting the environments the hosted wrappers depend on. One
/// type keeps `NSHostingView<ContactListCellContent>` concrete (no `AnyView`).
struct ContactListCellContent: View {
    let row: ContactListRow
    let environment: AppEnvironment
    let theme: ThemeEngine
    let openChat: OpenChatAction
    let toggle: (String) -> Void
    let showMenu: () -> Void

    var body: some View {
        rowView
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .environment(environment)
            .environment(theme)
            .environment(\.openChat, openChat)
    }

    @ViewBuilder
    private var rowView: some View {
        switch row {
        case let .header(header):
            GroupHeaderRow(
                name: header.title,
                online: header.online,
                total: header.total,
                showCount: header.showCount,
                isExpanded: header.isExpanded
            ) {
                toggle(header.sectionKey)
            }
            .padding(.vertical, 4)
        case let .contact(_, contact):
            ContactRow(contact: contact)
                // AX-only show-menu (not `.contextMenu`, which would claim the
                // mouse path and suppress the table's native emphasis). Bridges
                // VoiceOver's show-menu on the row to the table-owned menu.
                .accessibilityAction(.showMenu, showMenu)
                .padding(.vertical, 2)
        case let .room(room):
            RoomRow(conversation: room)
                .accessibilityAction(.showMenu, showMenu)
                .padding(.vertical, 2)
        }
    }
}
