import AppKit
import DuckoCore
import DuckoTestSupport
import SwiftUI
import Testing
@testable import DuckoUI

@MainActor
struct TranscriptListViewTests {
    private static let headerHeight: CGFloat = 60

    /// The list as a chat shows it, below a view that is there or not.
    private struct Column: View {
        let showsHeader: Bool
        let rows: [TranscriptRow]
        let scroller: TranscriptScroller
        let consent: RemoteImageConsent

        var body: some View {
            VStack(spacing: 0) {
                if showsHeader {
                    Color.clear.frame(height: TranscriptListViewTests.headerHeight)
                }
                TranscriptListView(
                    rows: rows, scroller: scroller, context: .history, remoteImageConsent: consent,
                    restsShortContentAtEnd: true, showsJumpToNewest: true
                )
            }
        }
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    @Test(arguments: [0, 1])
    func `a list with few rows makes room for a view that appears above it`(count: Int) throws {
        let environment = AppEnvironment(store: MockPersistenceStore(), transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore())
        let rows = (0 ..< count).map { _ in makeTranscriptRow() }
        let scroller = TranscriptScroller()
        let consent = RemoteImageConsent()
        func column(showsHeader: Bool) -> some View {
            Column(showsHeader: showsHeader, rows: rows, scroller: scroller, consent: consent).environment(environment)
        }
        let host = NSHostingView(rootView: column(showsHeader: false))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: true
        )
        window.contentView = host
        window.layoutIfNeeded()
        let scrollView = try #require(scrollView(in: host))
        let container = try #require(scrollView.superview)
        // Armed: the list has the whole window.
        #expect(container.frame.height == 500)

        host.rootView = column(showsHeader: true)
        window.layoutIfNeeded()
        #expect(container.frame.height == 500 - Self.headerHeight)
        #expect(scrollView.frame == container.bounds)
    }
}
