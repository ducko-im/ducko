import DuckoCore
import Foundation

extension JSONFormatter {
    func formatCommandResult(_ result: CLICommandResult) -> String {
        var dict = commandResultFields(result)
        dict["type"] = "command_result"
        dict["message"] = result.message
        return encode(dict)
    }

    private func commandResultFields(_ result: CLICommandResult) -> [String: String] {
        switch result {
        case .unregisterCancelled: ["action": "unregister_account", "result": "cancelled"]
        case let .accountUnregistered(historyDeleted):
            ["action": "unregister_account", "result": "unregistered", "history_deleted": historyDeleted ? "true" : "false"]
        case .registrationSubmitted: ["action": "submit_registration"]
        case .passwordChanged: ["action": "change_password"]
        case let .blocked(jid): ["action": "block", "jid": jid]
        case let .unblocked(jid): ["action": "unblock", "jid": jid]
        case let .directTransferStarted(fileName, jid): ["action": "send_file_directly", "file_name": fileName, "jid": jid]
        case let .transferAccepted(offerID, directory): ["action": "accept_transfer", "offer_id": offerID, "directory": directory]
        case let .transferDeclined(offerID): ["action": "decline_transfer", "offer_id": offerID]
        case let .transferCanceled(fileName): ["action": "cancel_transfer", "file_name": fileName]
        case let .messageRetracted(id): ["action": "retract", "original_id": id]
        case let .messageEdited(id): ["action": "edit", "original_id": id]
        case let .preference(_, key, enabled, changed):
            ["action": changed ? "set_preference" : "get_preference", "key": key, "enabled": enabled ? "true" : "false"]
        case let .encryption(jid, enabled): ["action": "set_encryption", "jid": jid, "enabled": enabled ? "true" : "false"]
        case let .omemoSetupRetried(accountID): ["action": "retry_omemo_setup", "account": accountID.uuidString]
        case let .directedPresenceSent(jid): ["action": "send_presence", "jid": jid]
        case let .subscriptionApproved(jid): ["action": "approve_subscription", "jid": jid]
        case let .subscriptionDenied(jid): ["action": "deny_subscription", "jid": jid]
        case let .roomLeft(room): ["action": "leave_room", "room": room]
        case let .roomDestroyed(room): ["action": "destroy_room", "room": room]
        case let .currentRoom(room): ["action": "current_room", "room": room]
        case let .voiceChanged(nickname, granted): ["action": granted ? "grant_voice" : "revoke_voice", "nickname": nickname]
        case let .kicked(nickname, room): ["action": "kick", "nickname": nickname, "room": room]
        case let .roomConfigSubmitted(room): ["action": "submit_room_config", "room": room]
        case let .moderated(serverID): ["action": "moderate", "original_id": serverID]
        case let .privateMessageSent(nickname): ["action": "send_private_message", "nickname": nickname]
        case let .ownAvatar(hash): ["action": "own_avatar", "hash": hash]
        case let .avatar(jid, hash, mimeType, size): ["action": "avatar", "jid": jid, "hash": hash, "mime_type": mimeType, "size": "\(size)"]
        case let .avatarSaved(path, hash, mimeType, size):
            ["action": "save_avatar", "path": path, "hash": hash, "mime_type": mimeType, "size": "\(size)"]
        case let .avatarPublished(hash, size): ["action": "publish_avatar", "hash": hash, "size": "\(size)"]
        case let .bookmarkAdded(jid): ["action": "add_bookmark", "jid": jid]
        case let .bookmarkRemoved(jid): ["action": "remove_bookmark", "jid": jid]
        case let .accountRegistered(jid): ["action": "register_account", "jid": jid]
        }
    }

    func formatUsageError(_ line: String) -> String {
        encode(["type": "error", "message": line])
    }

    func formatHelp(_ text: String) -> String {
        encode(["type": "help", "text": text])
    }

    func formatTransfer(_ transfer: FileTransferService.ActiveTransfer) -> String {
        var dict: [String: String] = [
            "type": "transfer",
            "file_name": transfer.fileName,
            "file_size": formatByteCount(transfer.fileSize),
            "file_size_bytes": "\(transfer.fileSize)",
            "direction": transferDirectionName(transfer),
            "method": transferMethodName(transfer),
            "account": transfer.accountID.uuidString
        ]
        dict["sid"] = transfer.sid
        dict["offer_id"] = transfer.offerID
        switch transfer.state {
        case .requestingSlot: dict["state"] = "requesting_slot"
        case let .uploading(progress):
            dict["state"] = "uploading"
            dict["progress"] = percentage(progress)
        case let .completed(url):
            dict["state"] = "completed"
            dict["url"] = url
        case let .failed(reason):
            dict["state"] = "failed"
            dict["reason"] = reason
        case .negotiating: dict["state"] = "negotiating"
        case .connectingTransport: dict["state"] = "connecting"
        case let .transferring(progress):
            dict["state"] = "transferring"
            dict["progress"] = percentage(progress)
            dict.merge(rateFields(transfer.rate)) { $1 }
        case .awaitingAcceptance: dict["state"] = "awaiting_acceptance"
        case .completedTransfer: dict["state"] = "completed"
        case let .received(fileURL):
            dict["state"] = "received"
            dict["path"] = fileURL.path
        }
        return encode(dict)
    }

    /// A progress fraction as a whole percentage, or nil when the fraction is not finite, as for a transfer whose
    /// size is zero.
    private func percentage(_ fraction: Double) -> String? {
        fraction.isFinite ? "\(Int(fraction * 100))" : nil
    }

    func formatAffiliationGroupHeader(_ affiliation: RoomAffiliation, count: Int) -> String {
        encode(["type": "affiliation_group", "affiliation": affiliation.rawValue, "count": "\(count)"])
    }

    func formatAffiliation(_ item: RoomAffiliationItem) -> String {
        var dict = ["type": "affiliation", "jid": item.jidString, "affiliation": item.affiliation.rawValue]
        dict["nickname"] = item.nickname
        return encode(dict)
    }
}
