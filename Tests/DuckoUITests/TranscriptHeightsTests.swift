import AppKit
import DuckoCore
import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoUI

/// Measures real hosted rows, without a window, and counts how often it is asked to.
@MainActor
private final class HeightsFixture {
    let preferences = PreferencesFixture()
    let themeEngine: ThemeEngine
    private let environment = AppEnvironment(store: MockPersistenceStore(), transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore())
    private let consent = RemoteImageConsent()
    private let measurer = TranscriptRowMeasurer()
    private(set) var measureCount = 0

    init() {
        self.themeEngine = preferences.makeThemeEngine()
    }

    /// Rows are drawn as the History window draws them, or as the chat does when set.
    var context = TranscriptRowContext.history

    /// A chat with nothing loaded, which is enough to draw a chat row.
    func drawAsChat() {
        context = .chat(ChatWindowState(jidString: "bob@example.com", accountID: nil, environment: environment))
    }

    /// What the list does for a row within reach at each settle.
    func settle(_ heights: inout TranscriptHeights, _ row: TranscriptRow, width: CGFloat) -> CGFloat {
        heights.prepare(width: width, theme: themeEngine.current)
        if !heights.isMeasured(row) {
            measureCount += 1
            let content = TranscriptRowView(row: row, context: context, environment: environment, theme: themeEngine, remoteImageConsent: consent)
            _ = heights.record(measurer.height(of: content, width: width), for: row)
        }
        return heights.height(of: row.id)
    }

    /// Another theme, whose larger avatar and padding change what a row measures.
    func selectAnotherTheme() throws {
        let other = try #require(themeEngine.availableThemes.first { $0 != themeEngine.current })
        themeEngine.selectTheme(other)
    }

    /// A theme that draws the date once per day and no time under a message, so a row's own line under the bubble
    /// holds only its marks.
    func selectGroupedTimestamps() throws {
        let grouped = try #require(themeEngine.availableThemes.first { $0.timestampStyle == .grouped })
        themeEngine.selectTheme(grouped)
    }

    /// The height of `row` at `width`, measured afresh.
    func height(of row: TranscriptRow, width: CGFloat = 400) -> CGFloat {
        var heights = TranscriptHeights()
        return settle(&heights, row, width: width)
    }
}

@MainActor
struct TranscriptHeightsTests {
    private let long = String(repeating: "A message long enough to wrap onto several lines. ", count: 8)

    private func row(
        isOutgoing: Bool, isDelivered: Bool = false, attachments: [DuckoCore.Attachment] = [], transferStatus: DirectTransferStatus? = nil,
        isFirstInGroup: Bool = true, startsDay: Bool = false
    ) -> TranscriptRow {
        let message = ChatMessage(
            id: UUID(), conversationID: UUID(), fromJID: "bob@example.com", body: attachments.isEmpty ? "A line of text" : "",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), isOutgoing: isOutgoing, isDelivered: isDelivered, isEdited: false,
            type: "chat", attachments: attachments
        )
        return TranscriptRow(id: message.id, kind: .message(TranscriptRow.Message(
            message: message, position: MessagePosition(isFirstInGroup: isFirstInGroup, isLastInGroup: true), isGroupchat: false,
            startsDay: startsDay, replyQuote: nil, linkPreview: nil, transferStatus: transferStatus, actionSenderName: "", loadsIncomingImagesOnSight: false,
            isSearchResult: false
        )))
    }

    @Test func `a height is reused for an equal row at the same width`() {
        let fixture = HeightsFixture()
        var heights = TranscriptHeights()
        let row = makeTranscriptRow(body: long)

        let first = fixture.settle(&heights, row, width: 400)
        let second = fixture.settle(&heights, makeTranscriptRow(id: row.id, body: long), width: 400)

        #expect(first > TranscriptHeights.estimate)
        #expect(second == first)
        #expect(fixture.measureCount == 1)
    }

    @Test func `a changed value, a changed width, and a changed theme each measure again`() throws {
        let fixture = HeightsFixture()
        var heights = TranscriptHeights()
        let row = makeTranscriptRow(body: long)
        let wide = fixture.settle(&heights, row, width: 400)

        let short = fixture.settle(&heights, makeTranscriptRow(id: row.id, body: "Short"), width: 400)
        #expect(fixture.measureCount == 2)
        #expect(short < wide)

        let narrow = fixture.settle(&heights, row, width: 250)
        #expect(fixture.measureCount == 3)
        #expect(narrow > wide)

        try fixture.selectAnotherTheme()
        _ = fixture.settle(&heights, row, width: 250)
        #expect(fixture.measureCount == 4)
    }

    @Test func `the last known height stays on as the estimate after a width change`() {
        let fixture = HeightsFixture()
        var heights = TranscriptHeights()
        let row = makeTranscriptRow(body: long)
        let measured = fixture.settle(&heights, row, width: 400)

        heights.prepare(width: 300, theme: fixture.themeEngine.current)

        #expect(!heights.isMeasured(row))
        #expect(heights.height(of: row.id) == measured)
    }

    @Test func `rows the list no longer has are dropped`() {
        let fixture = HeightsFixture()
        var heights = TranscriptHeights()
        let kept = makeTranscriptRow(body: long)
        let gone = makeTranscriptRow(body: long)
        _ = fixture.settle(&heights, kept, width: 400)
        _ = fixture.settle(&heights, gone, width: 400)

        heights.keep([kept.id])

        #expect(heights.isMeasured(kept))
        #expect(heights.height(of: gone.id) == TranscriptHeights.estimate)
    }

    @Test func `a tab that was not showing when the theme changed measures again when it is next settled`() throws {
        let fixture = HeightsFixture()
        var shown = TranscriptHeights()
        var hidden = TranscriptHeights()
        let row = makeTranscriptRow(body: long)
        _ = fixture.settle(&shown, row, width: 400)
        _ = fixture.settle(&hidden, row, width: 400)
        #expect(fixture.measureCount == 2)

        // Only the tab that is showing is settled when the theme changes.
        try fixture.selectAnotherTheme()
        _ = fixture.settle(&shown, row, width: 400)
        #expect(fixture.measureCount == 3)

        _ = fixture.settle(&hidden, row, width: 400)
        #expect(fixture.measureCount == 4)
    }

    @Test func `an outgoing row is as tall before its delivery mark as after, where timestamps are grouped`() throws {
        let fixture = HeightsFixture()
        try fixture.selectGroupedTimestamps()

        #expect(fixture.height(of: row(isOutgoing: true)) == fixture.height(of: row(isOutgoing: true, isDelivered: true)))
    }

    @Test func `a file sent directly keeps its row's height from waiting to sent`() {
        let fixture = HeightsFixture()
        let file = DuckoCore.Attachment.locallySaved(id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/notes.txt"))
        // A name too long for one line of a narrow list, which the waiting line must not wrap over.
        let longName = String(repeating: "a-long-name-", count: 10)
        let heights = [DirectTransferStatus.waiting(recipient: longName), .sending(progress: 0.4), .sent].map {
            fixture.height(of: row(isOutgoing: true, attachments: [file], transferStatus: $0), width: 300)
        }

        #expect(Set(heights).count == 1)
    }

    @Test func `the reason a direct transfer failed runs over as many lines as it needs`() {
        let fixture = HeightsFixture()
        let file = DuckoCore.Attachment.locallySaved(id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/notes.txt"))
        let reason = String(repeating: "The contact's device did not take the file. ", count: 6)
        let height = { (status: DirectTransferStatus) in
            fixture.height(of: row(isOutgoing: true, attachments: [file], transferStatus: status), width: 300)
        }

        // At least two lines more than a state that takes one.
        #expect(height(.failed(reason)) - height(.sent) > 20)
    }

    @Test func `a row that continues a group sits closer to the one before it than a row that starts one`() {
        let fixture = HeightsFixture()

        #expect(fixture.height(of: row(isOutgoing: false)) - fixture.height(of: row(isOutgoing: false, isFirstInGroup: false)) == 6)
    }

    @Test func `the first row of a day is taller by its date, in a chat for a message and anywhere for a note`() {
        let fixture = HeightsFixture()
        let note = { (startsDay: Bool) in
            let note = TimelineNote(conversationID: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000), kind: .encryptionEnabledByContact)
            return TranscriptRow(id: note.id, kind: .note(note, contactName: "Bob", startsDay: startsDay))
        }
        let date = fixture.height(of: note(true)) - fixture.height(of: note(false))
        #expect(date > 0)

        fixture.drawAsChat()
        #expect(fixture.height(of: row(isOutgoing: false, startsDay: true)) - fixture.height(of: row(isOutgoing: false)) == date)
    }
}
