import DuckoCore
import SwiftUI

public struct TranscriptViewerWindow: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(TranscriptScope.self) private var transcriptScope
    @State private var state: TranscriptViewerState?

    public init() {}

    public var body: some View {
        Group {
            if let state {
                TranscriptViewerContent(state: state)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let viewerState = TranscriptViewerState(environment: environment)
            state = viewerState
            // Cold open: a request that fired before the scene appeared, and thus before any `onChange`, is taken up here
            // rather than missed. It is cleared so that a later open from the File menu does not find it again.
            let request = transcriptScope.requested
            await viewerState.start(with: request)
            if let request {
                transcriptScope.clearHandled(request.generation)
            }
        }
        .onChange(of: transcriptScope.requested) {
            guard let state, let request = transcriptScope.requested else { return }
            Task {
                await state.applyScope(request)
                transcriptScope.clearHandled(request.generation)
            }
        }
    }
}

private struct TranscriptViewerContent: View {
    let state: TranscriptViewerState
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        NavigationSplitView {
            TranscriptSidebarView(state: state)
                // Wide enough for a row's avatar, name and address.
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            TranscriptDetailView(state: state)
        }
        .searchable(text: Binding(
            get: { state.searchFieldText },
            set: { state.setSearchText($0) }
        ), placement: .toolbar, prompt: "Search all conversations")
        .searchFocused($isSearchFieldFocused)
        .onChange(of: state.searchFieldFocusRequests) {
            isSearchFieldFocused = true
        }
        .focusedSceneValue(\.transcriptViewerState, state)
    }
}
