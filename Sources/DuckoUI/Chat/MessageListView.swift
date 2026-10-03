import DuckoCore
import SwiftUI

struct MessageListView: View {
    @Environment(ThemeEngine.self) private var theme
    let windowState: ChatWindowState
    @State private var hoveredMessageID: UUID?
    /// Whether the end of the timeline is on screen. Rows that come and go there, like the typing row, are only
    /// scrolled to while it is, so someone reading older messages is left where they are.
    @State private var isAtEnd = true

    private static let endID = "timeline-end"

    private var messages: [ChatMessage] {
        windowState.messages
    }

    private var items: [TimelineItem] {
        windowState.timelineItems
    }

    private var stanzaIDMap: [String: ChatMessage] {
        var map: [String: ChatMessage] = [:]
        for message in messages {
            if let stanzaID = message.stanzaID {
                map[stanzaID] = message
            }
        }
        return map
    }

    var body: some View {
        let items = items
        let positions = computeMessagePositions(items)
        let stanzaIDMap = stanzaIDMap

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !windowState.hasReachedEnd {
                        Color.clear.frame(height: 1)
                            .onAppear {
                                Task { await windowState.loadOlderMessages() }
                            }
                    }

                    if windowState.isLoadingOlder {
                        ProgressView()
                            .padding()
                    }

                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if theme.current.timestampStyle == .grouped, isNewDay(at: index, in: items) {
                            Text(item.timestamp.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }

                        switch item {
                        case let .message(message):
                            let pos = positions[message.id] ?? MessagePosition(isFirstInGroup: true, isLastInGroup: true)
                            let repliedMessage = message.replyToID.flatMap({ stanzaIDMap[$0] })
                            let isSearchResult = windowState.searchResults.contains(message.id)

                            MessageBubbleView(
                                message: message,
                                position: pos,
                                isHovered: hoveredMessageID == message.id,
                                repliedMessage: repliedMessage,
                                windowState: windowState
                            )
                            .id(message.id)
                            .padding(.top, pos.isFirstInGroup ? 8 : 2)
                            .padding(.horizontal)
                            .onHover { hovering in
                                hoveredMessageID = hovering ? message.id : nil
                            }
                            .background(
                                isSearchResult ? Color.yellow.opacity(0.15) : Color.clear,
                                in: .rect(cornerRadius: 8)
                            )
                        case let .note(note):
                            TimelineNoteView(note: note, contactName: windowState.displayName)
                                .id(note.id)
                        }
                    }

                    ForEach(windowState.receivingTransfers) { transfer in
                        ReceivingFileRow(transfer: transfer, windowState: windowState)
                            .id(transfer.id)
                            .padding(.top, 8)
                            .padding(.horizontal)
                    }

                    if windowState.isContactTyping {
                        TypingIndicatorRow(windowState: windowState)
                            .padding(.top, 8)
                            .padding(.horizontal)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.endID)
                        .onAppear { isAtEnd = true }
                        .onDisappear { isAtEnd = false }
                }
            }
            .accessibilityIdentifier("message-list")
            .defaultScrollAnchor(.bottom)
            .onChange(of: items.last?.id) { _, lastID in
                guard let lastID else { return }
                scrollToBottom(proxy, id: lastID)
            }
            // Prepended history (MAM sync, loadOlderMessages) leaves the last
            // row's id unchanged but pushes it offscreen — re-anchor.
            .onChange(of: items.count) {
                guard let lastID = items.last?.id else { return }
                scrollToBottom(proxy, id: lastID)
            }
            // An edit/retract of the last message updates its body without
            // changing identity. Re-anchor so the change is visible.
            .onChange(of: messages.last?.body) {
                guard let lastID = items.last?.id else { return }
                scrollToBottom(proxy, id: lastID)
            }
            .onChange(of: windowState.receivingTransfers.last?.id) { _, transferID in
                guard transferID != nil, isAtEnd else { return }
                scrollToBottom(proxy, id: Self.endID)
            }
            .onChange(of: windowState.isContactTyping) { _, isTyping in
                guard isTyping, isAtEnd else { return }
                scrollToBottom(proxy, id: Self.endID)
            }
            .onChange(of: windowState.currentSearchIndex) {
                guard !windowState.searchResults.isEmpty else { return }
                let targetID = windowState.searchResults[windowState.currentSearchIndex]
                withAnimation {
                    proxy.scrollTo(targetID, anchor: .center)
                }
            }
        }
    }

    private func isNewDay(at index: Int, in items: [TimelineItem]) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(items[index].timestamp, inSameDayAs: items[index - 1].timestamp)
    }

    /// Double-pass scroll: LazyVStack hasn't reified the target before the
    /// in-update `scrollTo` commits, so a 50 ms deferred pass catches the
    /// now-materialized item and exposes its text to the accessibility
    /// bridge.
    private func scrollToBottom(_ proxy: ScrollViewProxy, id: some Hashable) {
        withAnimation {
            proxy.scrollTo(id, anchor: .bottom)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            withAnimation {
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }
}
