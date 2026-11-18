import Foundation
import Testing
@testable import DuckoCore

struct TimelineNoteTests {
    @Test
    func `A file that did not arrive is noted with its name, its sender and why`() {
        let note = TimelineNote(
            conversationID: UUID(), kind: .incomingFileFailed, fileName: "report.pdf", detail: "The contact went offline"
        )

        #expect(note.text(contactName: "Bob") == "report.pdf from Bob did not arrive: The contact went offline")
    }
}
