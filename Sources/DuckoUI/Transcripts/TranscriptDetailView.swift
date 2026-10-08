import DuckoCore
import SwiftUI

struct TranscriptDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    let state: TranscriptViewerState

    /// Whether the listed days can belong to more than one conversation, so that each entry names its own.
    private var listsSeveralConversations: Bool {
        if state.searchesAllConversations { return true }
        switch state.selection {
        case .account, .importSource: return true
        case .conversation, nil: return false
        }
    }

    var body: some View {
        HSplitView {
            dayList
            messagePane
        }
        .navigationTitle(state.shownConversation?.displayTitle ?? "Chat History")
        .navigationSubtitle(state.shownConversation?.jid.description ?? "")
    }

    // MARK: - Day List

    private var dayList: some View {
        let matchCounts = state.matchCounts
        let namesConversation = listsSeveralConversations
        return List(state.listedDays, id: \.self, selection: Binding(
            get: { state.selectedDay },
            set: { state.selectDay($0) }
        )) { day in
            let conversation = namesConversation ? state.conversation(withID: day.conversationID) : nil
            TranscriptDayRow(
                date: day.date,
                conversation: conversation,
                avatarData: conversation.flatMap { state.avatarData(for: $0) },
                matchCount: matchCounts[day]
            )
        }
        .takesKeyboardOnClick()
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
    }

    // MARK: - Message Pane

    private var rows: [TranscriptRow] {
        TranscriptRows.history(
            items: state.timelineItems,
            positions: state.positions,
            details: TranscriptRows.Details(
                isGroupchat: state.shownConversation?.type == .groupchat,
                displayName: state.shownConversation?.displayTitle ?? "",
                searchResults: state.shownMatchIDs,
                searchQuery: state.trimmedKeyword,
                currentSearchResult: state.currentMatchID
            ),
            transfers: environment.fileTransferService.activeTransfers
        )
    }

    private var messagePane: some View {
        VStack(spacing: 0) {
            if state.isFindBarVisible {
                MessageSearchBar(
                    text: Binding(
                        get: { state.keyword },
                        set: { state.setFindText($0) }
                    ),
                    matchTotal: state.matchTotal,
                    currentMatchNumber: state.currentMatchNumber,
                    // A search typed into the toolbar field keeps the cursor there.
                    focusesOnAppear: !state.searchesAllConversations,
                    showsProgress: state.isScanning,
                    onSubmit: { state.findNext() },
                    onPrevious: { state.findPrevious() },
                    onNext: { state.findNext() },
                    onDone: state.endFind
                )

                Divider()
            }

            TranscriptListView(
                rows: rows,
                scroller: state.scroller,
                context: .history,
                remoteImageConsent: state.remoteImageConsent
            )
            .overlay {
                if state.selectedDay == nil {
                    placeholder
                }
            }
        }
        .frame(minWidth: 300)
    }

    /// What the message pane says while no day is open.
    @ViewBuilder
    private var placeholder: some View {
        if state.searchesAllConversations {
            if state.hasNoResults {
                ContentUnavailableView.search(text: state.trimmedKeyword)
            } else if state.isScanning {
                ProgressView("Searching…")
            }
        } else if state.isLoading {
            EmptyView()
        } else if state.allConversations.isEmpty {
            ContentUnavailableView(
                "No Chat History",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Conversations are kept here once you have exchanged messages.")
            )
        } else if state.selection == nil {
            ContentUnavailableView(
                "Select a Conversation",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Choose an account or a conversation from the sidebar to view its history.")
            )
        } else if state.days.isEmpty {
            ContentUnavailableView(
                "No Messages",
                systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Nothing is stored for this conversation yet.")
            )
        }
    }
}

// MARK: - Day Row

private struct TranscriptDayRow: View {
    let date: Date
    /// Set where the listed days belong to several conversations.
    let conversation: Conversation?
    let avatarData: Data?
    let matchCount: Int?

    private var dateText: String {
        date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt))
    }

    private var matchText: String? {
        matchCount.map { $0 == 1 ? "1 match" : "\($0) matches" }
    }

    var body: some View {
        HStack {
            if let conversation {
                ConversationAvatarView(conversation: conversation, avatarData: avatarData)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation?.displayTitle ?? dateText)
                    .singleLine()

                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .singleLine()
                }
            }
        }
    }

    /// Below a conversation's name, the date and the matches. Below a date, the matches.
    private var caption: String? {
        guard conversation != nil else { return matchText }
        return [dateText, matchText].compactMap(\.self).joined(separator: " · ")
    }
}
