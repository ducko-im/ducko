import AppKit
import DuckoCore
import SwiftUI

/// Where a transcript's rows are shown, which decides what a message row looks like and can do.
enum TranscriptRowContext {
    case chat(ChatWindowState)
    case history
}

/// The inputs `TranscriptListView` pushes into its coordinator on each `updateNSView`, bundled into one value so the
/// push is a single assignment.
@MainActor
struct TranscriptListInputs {
    var rows: [TranscriptRow]
    var scroller: TranscriptScroller
    var context: TranscriptRowContext
    var remoteImageConsent: RemoteImageConsent
    var environment: AppEnvironment
    var themeEngine: ThemeEngine
    /// The theme the rows are drawn in. Read here so a theme change reaches the list, which measures its rows again.
    var theme: DuckoTheme
    var accessibilityIdentifier: String?
    var restsShortContentAtEnd: Bool
    /// Space kept between the newest row and the bottom edge, so the row does not sit flush against what is below.
    var bottomPadding: CGFloat
    /// Whether a button to go back to the newest message shows while the view is away from it.
    var showsJumpToNewest: Bool
    var onNearOldest: () -> Void
}

/// AppKit transcript list: a view-based `NSTableView` whose cells host the SwiftUI rows. Only the rows near the screen
/// are laid out, and the list keeps its scroller's position through every change to its rows and its size.
struct TranscriptListView: NSViewRepresentable {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeEngine.self) private var theme

    let rows: [TranscriptRow]
    let scroller: TranscriptScroller
    let context: TranscriptRowContext
    let remoteImageConsent: RemoteImageConsent
    var accessibilityIdentifier: String?
    var restsShortContentAtEnd = false
    var bottomPadding: CGFloat = 0
    var showsJumpToNewest = false
    var onNearOldest: () -> Void = {}

    func makeCoordinator() -> TranscriptListCoordinator {
        TranscriptListCoordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(TranscriptListInputs(
            rows: rows,
            scroller: scroller,
            context: self.context,
            remoteImageConsent: remoteImageConsent,
            environment: environment,
            themeEngine: theme,
            theme: theme.current,
            accessibilityIdentifier: accessibilityIdentifier,
            restsShortContentAtEnd: restsShortContentAtEnd,
            bottomPadding: bottomPadding,
            showsJumpToNewest: showsJumpToNewest,
            onNearOldest: onNearOldest
        ))
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: TranscriptListCoordinator) {
        coordinator.detach()
    }
}
