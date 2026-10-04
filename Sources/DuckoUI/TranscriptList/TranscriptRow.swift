import DuckoCore
import Foundation

/// One row of a transcript list, as a value. A hosted row takes what decides its height from it and from the theme.
/// Two equal rows are therefore equally tall at one width and under one theme, which is what lets a measured height
/// be kept for as long as the row's value does not change.
struct TranscriptRow: Identifiable, Equatable {
    struct Message: Equatable {
        let message: ChatMessage
        let position: MessagePosition
        let isGroupchat: Bool
        /// Whether the day's date is drawn above the row.
        let startsDay: Bool
        let replyQuote: ReplyQuote?
        let linkPreview: LinkPreview?
        let transferStatus: DirectTransferStatus?
        /// Who a `/me` line names.
        let actionSenderName: String
        let loadsIncomingImagesOnSight: Bool
        let isSearchResult: Bool
    }

    struct ReplyQuote: Equatable {
        let senderName: String
        let previewText: String
    }

    /// A file the contact is sending right now. The row's id is the transfer's.
    struct ReceivingFile: Equatable {
        let fileName: String
        let fileSize: Int64
        let status: DirectTransferStatus
    }

    enum Kind: Equatable {
        case message(Message)
        /// `startsDay` says whether the day's date is drawn above the row.
        case note(TimelineNote, contactName: String, startsDay: Bool)
        case receivingFile(ReceivingFile)
        /// Stands above the oldest loaded message while there is history left to load.
        case topSlot(isLoading: Bool)
    }

    static let topSlotID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    let id: UUID
    let kind: Kind
}
