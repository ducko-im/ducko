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
                NavigationSplitView {
                    TranscriptSidebarView(state: state)
                } detail: {
                    TranscriptDetailView(state: state)
                }
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            let viewerState = TranscriptViewerState(environment: environment)
            state = viewerState
            await viewerState.load()
            // Cold open: `load()` populates `allConversations` only after the scene
            // appears, so a request that fired before this finished (and thus before any
            // `onChange`) is resolved here rather than missed.
            if let request = transcriptScope.requested {
                await viewerState.applyScope(request)
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
