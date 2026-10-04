import DuckoCore
import SwiftUI

struct TranscriptDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    let state: TranscriptViewerState

    private var isGroupchat: Bool {
        state.selectedConversation?.type == .groupchat
    }

    var body: some View {
        if let conversation = state.selectedConversation {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(conversation.displayTitle)
                            .font(.headline)
                        Text(conversation.jid.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                HSplitView {
                    dateListView
                    messageListView
                }
            }
            .searchable(text: Binding(
                get: { state.transcriptSearchText },
                set: { newValue in
                    state.transcriptSearchText = newValue
                    Task { await state.performTranscriptSearch() }
                }
            ), placement: .toolbar, prompt: "Search in conversation")
            .navigationTitle(conversation.displayTitle)
        } else {
            ContentUnavailableView(
                "Select a Conversation",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Choose a conversation from the sidebar to view its transcript.")
            )
        }
    }

    // MARK: - Date List

    private var dateListView: some View {
        List(state.messageDates, id: \.self, selection: Binding(
            get: { state.selectedDate },
            set: { newDate in
                Task { await state.selectDate(newDate) }
            }
        )) { date in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt)))
                    Spacer()
                    if state.searchMatchDates.contains(date) {
                        Image(systemName: "text.magnifyingglass")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                if let count = state.messageDateCounts[date] {
                    Text("\(count) \(count == 1 ? "message" : "messages")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
    }

    // MARK: - Message List

    private var rows: [TranscriptRow] {
        TranscriptRows.history(
            items: state.timelineItems,
            positions: state.positions,
            details: TranscriptRows.Details(
                isGroupchat: isGroupchat,
                displayName: state.selectedConversation?.displayTitle ?? "",
                searchResults: state.searchResults
            ),
            transfers: environment.fileTransferService.activeTransfers
        )
    }

    private var messageListView: some View {
        TranscriptListView(
            rows: rows,
            scroller: state.scroller,
            context: .history,
            remoteImageConsent: state.remoteImageConsent
        )
        .frame(minWidth: 300)
    }
}
