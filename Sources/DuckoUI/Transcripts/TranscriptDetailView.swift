import DuckoCore
import SwiftUI

struct TranscriptDetailView: View {
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

    private var messageListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(state.timelineItems) { item in
                    switch item {
                    case let .message(message):
                        let pos = state.positions[message.id] ?? MessagePosition(isFirstInGroup: true, isLastInGroup: true)

                        TranscriptBubbleView(
                            message: message,
                            position: pos,
                            isGroupchat: isGroupchat,
                            isSearchResult: state.searchResults.contains(message.id)
                        )
                    case let .note(note):
                        TimelineNoteView(note: note, contactName: state.selectedConversation?.displayTitle ?? "")
                    }
                }
            }
        }
        .frame(minWidth: 300)
    }
}
