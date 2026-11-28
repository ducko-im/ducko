import Foundation

/// The outcome of a command that changed something or answered a single question, which the human-readable formatters
/// print as `message` and JSON as a `command_result` record.
enum CLICommandResult {
    case unregisterCancelled
    case accountUnregistered(historyDeleted: Bool)
    case registrationSubmitted
    case passwordChanged
    case blocked(jid: String)
    case unblocked(jid: String)
    case directTransferStarted(fileName: String, jid: String)
    case transferAccepted(offerID: String, directory: String)
    case transferDeclined(offerID: String)
    case transferCanceled(fileName: String)
    case encryptedFileSaved(path: String)
    case messageRetracted(id: String)
    case messageEdited(id: String)
    /// A preference read, or set when `changed`.
    case preference(name: String, key: String, enabled: Bool, changed: Bool)
    case encryption(jid: String, enabled: Bool)
    case omemoSetupRetried(accountID: UUID)
    case directedPresenceSent(jid: String)
    case subscriptionApproved(jid: String)
    case subscriptionDenied(jid: String)
    case roomLeft(room: String)
    case roomDestroyed(room: String)
    case currentRoom(room: String)
    case voiceChanged(nickname: String, granted: Bool)
    case kicked(nickname: String, room: String)
    case roomConfigSubmitted(room: String)
    case moderated(serverID: String)
    case privateMessageSent(nickname: String)
    case ownAvatar(hash: String)
    case avatar(jid: String, hash: String, mimeType: String, size: Int)
    case avatarSaved(path: String, hash: String, mimeType: String, size: Int)
    case avatarPublished(hash: String, size: Int)
    case bookmarkAdded(jid: String)
    case bookmarkRemoved(jid: String)
    case accountRegistered(jid: String)

    var message: String {
        switch self {
        case .unregisterCancelled: "Cancelled."
        case let .accountUnregistered(historyDeleted): "Account unregistered." + (historyDeleted ? "\nChat history deleted." : "")
        case .registrationSubmitted: "Registration submitted successfully."
        case .passwordChanged: "Password changed."
        case let .blocked(jid): "Blocked \(jid)."
        case let .unblocked(jid): "Unblocked \(jid)."
        case let .directTransferStarted(fileName, jid): "Sending \(fileName) to \(jid) directly. Use /transfers to check progress."
        case let .transferAccepted(offerID, directory): "Accepted file transfer: \(offerID), saving to \(directory)"
        case let .transferDeclined(offerID): "Declined file transfer: \(offerID)"
        case let .transferCanceled(fileName): "Canceled file transfer: \(fileName)"
        case let .encryptedFileSaved(path): "Saved encrypted file to \(path)"
        case let .messageRetracted(id): "Retracted message: \(id)"
        case let .messageEdited(id): "Edited message: \(id)"
        case let .preference(name, _, enabled, changed):
            changed ? "\(name) \(enabled ? "enabled" : "disabled")." : "\(name): \(enabled ? "on" : "off")"
        case let .encryption(jid, enabled): "Encryption \(enabled ? "enabled" : "disabled") for \(jid)."
        case .omemoSetupRetried: "Retrying OMEMO setup."
        case let .directedPresenceSent(jid): "Sent directed presence to \(jid)."
        case let .subscriptionApproved(jid): "Approved subscription from \(jid)."
        case let .subscriptionDenied(jid): "Denied subscription from \(jid)."
        case let .roomLeft(room): "Left \(room)."
        case let .roomDestroyed(room): "Room \(room) destroyed."
        case let .currentRoom(room): "Current room: \(room)"
        case let .voiceChanged(nickname, granted): granted ? "Granted voice to \(nickname)." : "Revoked voice from \(nickname)."
        case let .kicked(nickname, room): "Kicked \(nickname) from \(room)."
        case let .roomConfigSubmitted(room): "Submitted default room configuration for \(room)."
        case let .moderated(serverID): "Moderated message (server-id: \(serverID))."
        case let .privateMessageSent(nickname): "PM to \(nickname) sent."
        case let .ownAvatar(hash): "Own avatar hash: \(hash)"
        case let .avatar(jid, hash, mimeType, size): "Avatar for \(jid):\n  Hash: \(hash)\n  Type: \(mimeType)\n  Size: \(size) bytes"
        case let .avatarSaved(path, hash, mimeType, size): "Saved avatar to \(path)\nHash: \(hash)\nType: \(mimeType)\nSize: \(size) bytes"
        case let .avatarPublished(hash, size): "Avatar published successfully.\nHash: \(hash)\nSize: \(size) bytes"
        case let .bookmarkAdded(jid): "Added bookmark for \(jid)."
        case let .bookmarkRemoved(jid): "Removed bookmark for \(jid)."
        case let .accountRegistered(jid): "Account registered: \(jid)"
        }
    }
}
