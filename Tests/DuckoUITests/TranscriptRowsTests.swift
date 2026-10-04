import DuckoCore
import Foundation
import Testing
@testable import DuckoUI

struct TranscriptRowsTests {
    private let conversationID = UUID()
    private let accountID = UUID()
    /// Midday, so that messages minutes apart share a day in any time zone.
    private let start = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_700_000_000))!

    private func message(at offset: TimeInterval, body: String = "hello", isOutgoing: Bool = false, localFile: Bool = false) -> ChatMessage {
        ChatMessage(
            id: UUID(), conversationID: conversationID, stanzaID: UUID().uuidString, fromJID: "bob@example.com", body: body,
            timestamp: start.addingTimeInterval(offset), isOutgoing: isOutgoing, isDelivered: false, isEdited: false, type: "chat",
            attachments: localFile ? [.locallySaved(id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/notes.txt"))] : []
        )
    }

    private func rows(
        _ messages: [ChatMessage],
        chat: TranscriptRows.Details = TranscriptRows.Details(timestampStyle: .grouped),
        transfers: [FileTransferService.ActiveTransfer] = [],
        previews: [UUID: LinkPreview] = [:]
    ) -> [TranscriptRow] {
        TranscriptRows.chat(
            items: messages.map(TimelineItem.message), details: chat,
            transfers: transfers, receivingTransfers: [], linkPreview: { previews[$0.id] }
        )
    }

    /// The indices at which two row lists of one length differ.
    private func changed(_ old: [TranscriptRow], _ new: [TranscriptRow]) -> [Int] {
        old.indices.filter { old[$0] != new[$0] }
    }

    @Test func `equal inputs give equal rows`() {
        let messages = (0 ..< 5).map { message(at: TimeInterval($0 * 10)) }

        #expect(rows(messages) == rows(messages))
    }

    @Test func `a prepend changes only the row that was first`() {
        let messages = (0 ..< 5).map { message(at: TimeInterval($0 * 10)) }
        let before = rows(messages)

        let after = rows([message(at: -10)] + messages)

        // It no longer starts the day, nor its group.
        #expect(changed(before, Array(after.dropFirst())) == [0])
    }

    @Test func `an append changes only the row that was last`() {
        let messages = (0 ..< 5).map { message(at: TimeInterval($0 * 10)) }
        let before = rows(messages)

        let after = rows(messages + [message(at: 60)])

        #expect(changed(before, Array(after.dropLast())) == [4])
    }

    @Test func `a link preview arriving changes exactly its message's row`() {
        let messages = (0 ..< 5).map { message(at: TimeInterval($0 * 10)) }
        let preview = LinkPreview(url: "https://example.com", title: "Example", fetchedAt: Date())

        #expect(changed(rows(messages), rows(messages, previews: [messages[2].id: preview])) == [2])
    }

    @Test func `a transfer's progress changes exactly its message's row`() {
        var messages = (0 ..< 5).map { message(at: TimeInterval($0 * 10)) }
        messages[3] = message(at: 30, body: "", isOutgoing: true, localFile: true)
        let transfer = { (progress: Double) in
            FileTransferService.ActiveTransfer(
                id: messages[3].id, accountID: accountID, fileName: "notes.txt", fileSize: 3,
                state: .transferring(progress: progress), method: .jingle
            )
        }

        #expect(changed(rows(messages, transfers: [transfer(0.2)]), rows(messages, transfers: [transfer(0.6)])) == [3])
    }

    @Test func `a search result changes exactly its message's row`() {
        let messages = (0 ..< 5).map { message(at: TimeInterval($0 * 10)) }
        var chat = TranscriptRows.Details(timestampStyle: .grouped)
        chat.searchResults = [messages[1].id]

        #expect(changed(rows(messages), rows(messages, chat: chat)) == [1])
    }

    @Test func `the top slot stands above the messages while there is history left to load`() {
        let messages = (0 ..< 3).map { message(at: TimeInterval($0 * 10)) }
        var chat = TranscriptRows.Details(timestampStyle: .grouped)
        #expect(rows(messages, chat: chat).map(\.id) == messages.map(\.id))

        chat.showsTopSlot = true
        #expect(rows(messages, chat: chat).first == TranscriptRow(id: TranscriptRow.topSlotID, kind: .topSlot(isLoading: false)))

        chat.isLoadingOlder = true
        #expect(rows(messages, chat: chat).first?.kind == .topSlot(isLoading: true))
    }

    @Test func `a note that is the first item of a day carries the date, and the message after it does not`() {
        let nextDay: TimeInterval = 86400
        let note = TimelineNote(conversationID: conversationID, timestamp: start.addingTimeInterval(nextDay), kind: .encryptionEnabledByContact)
        let items: [TimelineItem] = [.message(message(at: 0)), .note(note), .message(message(at: nextDay + 10))]

        let rows = TranscriptRows.chat(
            items: items, details: TranscriptRows.Details(timestampStyle: .grouped),
            transfers: [], receivingTransfers: [], linkPreview: { _ in nil }
        )

        guard case let .note(_, _, noteStartsDay) = rows[1].kind, case let .message(after) = rows[2].kind else {
            Issue.record("Expected a note row and a message row")
            return
        }
        #expect(noteStartsDay)
        #expect(!after.startsDay)
    }

    struct ImageChat {
        let isGroupchat: Bool
        let contactName: String?
        let loadsOnSight: Bool
    }

    @Test(arguments: [
        ImageChat(isGroupchat: false, contactName: "Bob", loadsOnSight: true),
        ImageChat(isGroupchat: false, contactName: nil, loadsOnSight: false),
        ImageChat(isGroupchat: true, contactName: "Bob", loadsOnSight: false)
    ])
    func `incoming images load on sight only in a one-to-one chat with a contact`(chat: ImageChat) {
        let details = TranscriptRows.Details(isGroupchat: chat.isGroupchat, contactName: chat.contactName)

        guard case let .message(row) = rows([message(at: 0)], chat: details)[0].kind else {
            Issue.record("Expected a message row")
            return
        }
        #expect(row.loadsIncomingImagesOnSight == chat.loadsOnSight)
    }

    @Test func `a file waiting to be accepted names the chat, and one being received stands after the messages`() {
        let sent = message(at: 0, body: "", isOutgoing: true, localFile: true)
        let transfer = { (id: UUID, state: FileTransferService.TransferState, direction: FileTransferService.TransferDirection) in
            FileTransferService.ActiveTransfer(
                id: id, accountID: accountID, fileName: "notes.txt", fileSize: 3, state: state, method: .jingle, direction: direction
            )
        }
        let receiving = transfer(UUID(), .transferring(progress: 0.5), .incoming)

        let rows = TranscriptRows.chat(
            items: [.message(sent)], details: TranscriptRows.Details(displayName: "Bob"),
            transfers: [transfer(sent.id, .negotiating, .outgoing)], receivingTransfers: [receiving], linkPreview: { _ in nil }
        )

        guard case let .message(row) = rows[0].kind else {
            Issue.record("Expected a message row")
            return
        }
        #expect(row.transferStatus == .waiting(recipient: "Bob"))
        #expect(rows.last == TranscriptRow(id: receiving.id, kind: .receivingFile(
            TranscriptRow.ReceivingFile(fileName: "notes.txt", fileSize: 3, status: .receiving(progress: 0.5))
        )))
    }

    @Test func `a reply carries its quote only while the quoted message is loaded`() {
        let quoted = message(at: 0, body: "the original")
        var reply = message(at: 10, body: "the reply")
        reply.replyToID = quoted.stanzaID

        let withQuoted = rows([quoted, reply])
        let withoutQuoted = rows([reply])

        guard case let .message(loaded) = withQuoted[1].kind, case let .message(alone) = withoutQuoted[0].kind else {
            Issue.record("Expected message rows")
            return
        }
        #expect(loaded.replyQuote == TranscriptRow.ReplyQuote(senderName: "bob@example.com", previewText: "the original"))
        #expect(alone.replyQuote == nil)
    }

    @Test func `a History row carries the stored position and no reply quote`() {
        let quoted = message(at: 0)
        var reply = message(at: 10)
        reply.replyToID = quoted.stanzaID
        let position = MessagePosition(isFirstInGroup: false, isLastInGroup: true)

        let rows = TranscriptRows.history(
            items: [.message(quoted), .message(reply)], positions: [reply.id: position],
            details: TranscriptRows.Details(isGroupchat: true, displayName: "Bob", searchResults: [reply.id]), transfers: []
        )

        guard case let .message(row) = rows[1].kind else {
            Issue.record("Expected a message row")
            return
        }
        #expect(row.position == position)
        #expect(row.replyQuote == nil)
        #expect(!row.loadsIncomingImagesOnSight)
        #expect(row.isGroupchat)
        #expect(row.isSearchResult)
        #expect(!row.startsDay)
    }

    @Test func `a History row of a file being sent directly carries its status`() {
        let sent = message(at: 0, body: "", isOutgoing: true, localFile: true)
        let transfer = FileTransferService.ActiveTransfer(
            id: sent.id, accountID: accountID, fileName: "notes.txt", fileSize: 3, state: .transferring(progress: 0.4), method: .jingle
        )

        let rows = TranscriptRows.history(
            items: [.message(sent)], positions: [:], details: TranscriptRows.Details(displayName: "Bob"), transfers: [transfer]
        )

        guard case let .message(row) = rows[0].kind else {
            Issue.record("Expected a message row")
            return
        }
        #expect(row.transferStatus == .sending(progress: 0.4))
    }
}
