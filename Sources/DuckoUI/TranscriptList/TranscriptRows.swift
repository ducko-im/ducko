import DuckoCore
import Foundation

/// Builds a transcript's rows from what its owner holds. Pure, so equal inputs give equal rows.
enum TranscriptRows {
    /// What the rows say about the conversation as a whole.
    struct Details {
        var isGroupchat = false
        /// The chat's name, which a note and a file waiting to be accepted name the contact by.
        var displayName = ""
        /// The contact's name in the contact list, for a chat with someone who is in it.
        var contactName: String?
        var searchResults: Set<UUID> = []
        /// Whether there is history left to load, once the first load has finished.
        var showsTopSlot = false
        var isLoadingOlder = false
    }

    /// The top slot, one row per timeline item, then the files being received.
    static func chat(
        items: [TimelineItem],
        details chat: Details,
        transfers: [FileTransferService.ActiveTransfer],
        receivingTransfers: [FileTransferService.ActiveTransfer],
        linkPreview: (ChatMessage) -> LinkPreview?
    ) -> [TranscriptRow] {
        let positions = computeMessagePositions(items)
        var messagesByStanzaID: [String: ChatMessage] = [:]
        for case let .message(message) in items {
            if let stanzaID = message.stanzaID {
                messagesByStanzaID[stanzaID] = message
            }
        }
        let transfersByID = Dictionary(transfers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // In a one-to-one chat with someone in your contact list, their photos load on sight. Anyone else's wait for a
        // click, so a stranger's image is not fetched merely by being shown.
        let loadsIncomingImagesOnSight = !chat.isGroupchat && chat.contactName != nil

        var rows: [TranscriptRow] = []
        if chat.showsTopSlot {
            rows.append(TranscriptRow(id: TranscriptRow.topSlotID, kind: .topSlot(isLoading: chat.isLoadingOlder)))
        }
        for (index, item) in items.enumerated() {
            let isFirstOfDay = startsDay(at: index, in: items)
            switch item {
            case let .message(message):
                let replied = message.replyToID.flatMap { messagesByStanzaID[$0] }
                rows.append(TranscriptRow(id: message.id, kind: .message(TranscriptRow.Message(
                    message: message,
                    position: positions[message.id] ?? MessagePosition(isFirstInGroup: true, isLastInGroup: true),
                    isGroupchat: chat.isGroupchat,
                    startsDay: isFirstOfDay,
                    replyQuote: replied.map {
                        TranscriptRow.ReplyQuote(senderName: $0.isOutgoing ? "You" : $0.fromJID, previewText: $0.previewText)
                    },
                    linkPreview: linkPreview(message),
                    transferStatus: .resolve(for: message, transfer: transfersByID[message.id], recipientName: chat.displayName),
                    actionSenderName: actionSenderName(of: message, chat: chat),
                    loadsIncomingImagesOnSight: loadsIncomingImagesOnSight,
                    isSearchResult: chat.searchResults.contains(message.id)
                ))))
            case let .note(note):
                rows.append(TranscriptRow(id: note.id, kind: .note(note, contactName: chat.displayName, startsDay: isFirstOfDay)))
            }
        }
        for transfer in receivingTransfers {
            rows.append(TranscriptRow(id: transfer.id, kind: .receivingFile(TranscriptRow.ReceivingFile(
                fileName: transfer.fileName,
                fileSize: transfer.fileSize,
                status: .receiving(transfer)
            ))))
        }
        return rows
    }

    /// One row per timeline item of a day in the History window, which shows no reply quotes and no link previews.
    static func history(
        items: [TimelineItem],
        positions: [UUID: MessagePosition],
        details: Details,
        transfers: [FileTransferService.ActiveTransfer]
    ) -> [TranscriptRow] {
        let transfersByID = Dictionary(transfers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return items.map { item in
            switch item {
            case let .message(message):
                TranscriptRow(id: message.id, kind: .message(TranscriptRow.Message(
                    message: message,
                    position: positions[message.id] ?? MessagePosition(isFirstInGroup: true, isLastInGroup: true),
                    isGroupchat: details.isGroupchat,
                    startsDay: false,
                    replyQuote: nil,
                    linkPreview: nil,
                    transferStatus: .resolve(for: message, transfer: transfersByID[message.id], recipientName: details.displayName),
                    actionSenderName: message.fromJID,
                    loadsIncomingImagesOnSight: false,
                    isSearchResult: details.searchResults.contains(message.id)
                )))
            case let .note(note):
                TranscriptRow(id: note.id, kind: .note(note, contactName: details.displayName, startsDay: false))
            }
        }
    }

    private static func startsDay(at index: Int, in items: [TimelineItem]) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(items[index].timestamp, inSameDayAs: items[index - 1].timestamp)
    }

    private static func actionSenderName(of message: ChatMessage, chat: Details) -> String {
        if message.isOutgoing {
            return "You"
        }
        if message.type == "groupchat" {
            return message.fromJID
        }
        return chat.contactName ?? message.fromJID
    }
}
