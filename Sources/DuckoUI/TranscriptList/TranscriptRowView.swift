import DuckoCore
import SwiftUI

/// The single concrete SwiftUI view a hosted transcript cell renders, switching on the row's kind and on where the
/// transcript is shown, and re-injecting the environments the rows depend on.
struct TranscriptRowView: View {
    let row: TranscriptRow
    let context: TranscriptRowContext
    let environment: AppEnvironment
    let remoteImageConsent: RemoteImageConsent

    var body: some View {
        content
            // A row takes the height its content asks for, whatever height it is offered: measuring offers one without
            // limit, which content that fills its height would take.
            .fixedSize(horizontal: false, vertical: true)
            // A reused cell must not hand one row's view state, such as an open sheet, to the next row.
            .id(row.id)
            .environment(environment)
            .environment(remoteImageConsent)
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case let .message(message):
            switch context {
            case let .chat(windowState):
                ChatMessageRow(row: message, windowState: windowState)
            case .history:
                TranscriptBubbleView(row: message)
            }
        case let .note(note, contactName, startsDay):
            VStack(spacing: 0) {
                if startsDay {
                    DaySeparator(date: note.timestamp)
                }
                TimelineNoteView(note: note, contactName: contactName)
            }
        case let .receivingFile(file):
            switch context {
            case let .chat(windowState):
                ReceivingFileRow(id: row.id, file: file, windowState: windowState)
                    .padding(.top, 8)
                    .padding(.horizontal)
            case .history:
                EmptyView()
            }
        case let .topSlot(isLoading):
            TranscriptTopSlot(isLoading: isLoading)
        }
    }
}

/// A chat's message row: the day's date when the row starts one, then the bubble.
private struct ChatMessageRow: View {
    let row: TranscriptRow.Message
    let windowState: ChatWindowState
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            if row.startsDay {
                DaySeparator(date: row.message.timestamp)
            }

            MessageBubbleView(row: row, isHovered: isHovered, windowState: windowState)
                .messageRowFrame(row)
                .onHover { isHovered = $0 }
        }
    }
}

/// The date drawn above the first row of a day.
private struct DaySeparator: View {
    let date: Date

    var body: some View {
        Text(date.formatted(date: .abbreviated, time: .omitted))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }
}

extension View {
    /// The space above and beside a message row, closer to the row before it within a group, and the highlight of a
    /// search result.
    func messageRowFrame(_ row: TranscriptRow.Message) -> some View {
        padding(.top, row.position.isFirstInGroup ? 8 : 2)
            .padding(.horizontal)
            .background(
                row.isSearchResult ? Color.yellow.opacity(0.15) : Color.clear,
                in: .rect(cornerRadius: 8)
            )
    }
}
