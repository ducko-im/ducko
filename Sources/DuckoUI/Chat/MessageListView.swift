import DuckoCore
import SwiftUI

struct MessageListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeEngine.self) private var theme
    let windowState: ChatWindowState

    var body: some View {
        TranscriptListView(
            rows: rows,
            scroller: windowState.scroller,
            context: .chat(windowState),
            remoteImageConsent: windowState.remoteImageConsent,
            accessibilityIdentifier: "message-list",
            restsShortContentAtEnd: true,
            bottomPadding: 8,
            showsJumpToNewest: true,
            onNearOldest: { Task { await windowState.loadOlderMessages() } }
        )
    }

    /// Built in `body`, so that observation tracks everything a row draws from.
    private var rows: [TranscriptRow] {
        let showsLinkPreviews = theme.current.showLinkPreviews
        return TranscriptRows.chat(
            items: windowState.timelineItems,
            details: TranscriptRows.Details(
                isGroupchat: windowState.isGroupchat,
                displayName: windowState.displayName,
                contactName: windowState.contact?.displayName,
                searchResults: Set(windowState.searchResults),
                showsTopSlot: windowState.conversation != nil && !windowState.isLoading && !windowState.hasReachedEnd,
                isLoadingOlder: windowState.isLoadingOlder,
                timestampStyle: theme.current.timestampStyle
            ),
            transfers: environment.fileTransferService.activeTransfers,
            receivingTransfers: windowState.receivingTransfers,
            linkPreview: { showsLinkPreviews ? windowState.linkPreview(for: $0) : nil }
        )
    }
}
