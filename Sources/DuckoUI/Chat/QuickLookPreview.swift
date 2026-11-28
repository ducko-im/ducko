import AppKit
import QuickLookUI
import SwiftUI

/// Shows `fileURL` in the system Quick Look panel — the same panel Finder opens, with its share and "Open with…"
/// controls — while `isPresented` is true. Held in place before there is a file to show, so the panel finds it in the
/// responder chain the moment one is.
struct QuickLookPreview: NSViewRepresentable {
    let fileURL: URL?
    @Binding var isPresented: Bool

    func makeNSView(context _: Context) -> QuickLookHostView {
        QuickLookHostView()
    }

    func updateNSView(_ view: QuickLookHostView, context _: Context) {
        view.previewItem = fileURL.map { $0 as NSURL }
        view.onPanelClosed = { isPresented = false }
        if isPresented {
            view.showPanel()
        } else {
            view.hidePanel()
        }
    }

    /// The panel holds its data source unowned, so a view SwiftUI takes out of the hierarchy has to hand control back
    /// itself: the panel only re-searches the responder chain when the key or main window changes, which removing a
    /// view does not do.
    static func dismantleNSView(_ view: QuickLookHostView, coordinator _: ()) {
        view.relinquishPanel()
    }
}

// MARK: - QuickLookHostView

/// The responder Quick Look talks to. `QLPreviewPanel` takes its data source from the responder chain, so a view in
/// the chain has to answer for the panel; it also gives the panel the frame to zoom the preview from.
final class QuickLookHostView: NSView, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    var previewItem: NSURL?
    var onPanelClosed: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    func showPanel() {
        guard let panel = QLPreviewPanel.shared() else { return }
        window?.makeFirstResponder(self)
        guard panel.isVisible else {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        if panel.dataSource === self {
            panel.reloadData()
        } else {
            // Taking over an open panel changes the responder chain without changing the key window, which is the one
            // case the panel does not notice by itself.
            panel.updateController()
        }
    }

    // `hidePanel` and `relinquishPanel` check `sharedPreviewPanelExists()` before calling `shared()`, which would create
    // a panel. They run for every attachment in every chat, including ones nobody previews.

    func hidePanel() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(), panel.isVisible, panel.dataSource === self else { return }
        panel.orderOut(nil)
    }

    /// Hands the panel back before this view goes away, so it never reads a data source that no longer exists.
    func relinquishPanel() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(), panel.dataSource === self else { return }
        panel.orderOut(nil)
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: - Panel control

    // Quick Look drives these on the main thread, but the `NSResponder` category declares them outside the main actor.

    override func acceptsPreviewPanelControl(_: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { previewItem != nil }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            if panel.dataSource === self {
                panel.dataSource = nil
                panel.delegate = nil
            }
            onPanelClosed?()
        }
    }

    // MARK: - QLPreviewPanelDataSource

    // Quick Look calls these on the main thread too. `MainActor.assumeIsolated` states that assumption, so a violation
    // traps and names itself rather than racing.

    func numberOfPreviewItems(in _: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewItem == nil ? 0 : 1 }
    }

    func previewPanel(_: QLPreviewPanel!, previewItemAt _: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewItem }
    }

    // MARK: - QLPreviewPanelDelegate

    /// Zooms the preview out of the attachment this view sits behind.
    func previewPanel(_: QLPreviewPanel!, sourceFrameOnScreenFor _: (any QLPreviewItem)!) -> NSRect {
        MainActor.assumeIsolated {
            guard let window else { return .zero }
            return window.convertToScreen(convert(bounds, to: nil))
        }
    }
}
