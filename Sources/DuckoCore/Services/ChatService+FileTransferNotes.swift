import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.chat")

extension ChatService {
    /// Notes in the chat with `jid` that the file `fileName` they were sending directly did not arrive, and why.
    func recordIncomingFileFailure(fileName: String, from jid: BareJID, reason: String, accountID: UUID) async {
        let conversation: Conversation
        do {
            conversation = try await findOrCreateConversation(for: jid, accountID: accountID)
            try await transcripts.appendNote(TimelineNote(
                conversationID: conversation.id, kind: .incomingFileFailed, fileName: fileName, detail: reason
            ))
        } catch {
            log.warning("Could not note a file that did not arrive")
            log.debug("Could not note that \(fileName) from \(jid) did not arrive: \(error)")
            return
        }
        bumpRevision(for: conversation.id)
    }
}
