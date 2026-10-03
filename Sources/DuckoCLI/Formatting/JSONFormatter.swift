import DuckoCore
import DuckoXMPP
import Foundation

struct JSONFormatter: CLIFormatter {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    // MARK: - CLIFormatter

    func formatMessage(_ message: ChatMessage, accountJID: BareJID? = nil) -> String {
        var dict: [String: String] = [
            "type": "message",
            "direction": message.isOutgoing ? "outgoing" : "incoming",
            "from": message.fromJID,
            "body": message.body,
            "timestamp": formatTimestamp(message.timestamp)
        ]
        if message.body.hasPrefix("/me ") {
            dict["action"] = "true"
            if message.isOutgoing, let accountJID {
                dict["actor"] = accountJID.description
            }
        }
        if message.isDelivered {
            dict["delivered"] = "true"
        }
        if message.isDisplayed {
            dict["read"] = "true"
        }
        if message.isEncrypted {
            dict["encrypted"] = "true"
        }
        if message.isUndecryptable {
            dict["undecryptable"] = "true"
        }
        if message.isEdited {
            dict["edited"] = "true"
        }
        if let errorText = message.errorText {
            dict["error"] = errorText
        }
        let extraAttachments = message.attachments.filter { $0.url != message.body }
        if !extraAttachments.isEmpty {
            dict["attachments"] = extraAttachments.map(\.url).joined(separator: ",")
        }
        return encode(dict)
    }

    func formatNote(_ note: TimelineNote, contactName: String) -> String {
        encode([
            "type": "note",
            "kind": note.kind.rawValue,
            "text": note.text(contactName: contactName),
            "timestamp": formatTimestamp(note.timestamp)
        ])
    }

    func formatEmptyResult(_ result: CLIEmptyResult) -> String {
        switch result {
        case .accounts:
            encode(["type": "accounts_empty"])
        case let .roster(accountID):
            encode(["type": "roster_empty", "account": accountID.uuidString])
        case let .bookmarks(accountID):
            encode(["type": "bookmarks_empty", "account": accountID.uuidString])
        case .rooms:
            encode(["type": "rooms_empty"])
        case let .roomParticipants(room):
            encode(["type": "room_participants_empty", "room": room])
        case .channels:
            encode(["type": "searched_channels_empty"])
        case .messages:
            encode(["type": "messages_empty"])
        case let .omemoIdentity(accountID):
            encode(["type": "omemo_identity_empty", "account": accountID.uuidString])
        case let .omemoDevices(jid, accountID):
            encode(["type": "omemo_devices_empty", "account": accountID.uuidString, "jid": jid])
        }
    }

    func formatRosterCommand(_ outcome: RosterCommandOutcome) -> String {
        encode([
            "type": "roster_command", "operation": outcome.operation.rawValue,
            "account": outcome.accountID.uuidString, "jid": outcome.jid,
            "remote_status": "confirmed", "local_status": outcome.localStatus.rawValue,
            "subscription_status": outcome.subscriptionStatus.rawValue,
            "result": outcome.isComplete ? "complete" : "partial", "message": outcome.message
        ])
    }

    func formatAccount(_ account: Account) -> String {
        encode([
            "type": "account",
            "id": account.id.uuidString,
            "jid": account.jid.description,
            "isEnabled": account.isEnabled ? "true" : "false"
        ])
    }

    func formatContactWithPresence(_ contact: Contact, presence: PresenceService.PresenceStatus?) -> String {
        var dict: [String: String] = [
            "type": "contact",
            "jid": contact.jid.description,
            "subscription": contact.subscription.rawValue,
            "presence": (presence ?? .offline).rawValue
        ]
        if let name = contact.name {
            dict["name"] = name
        }
        if let localAlias = contact.localAlias {
            dict["localAlias"] = localAlias
        }
        if !contact.groups.isEmpty {
            dict["groups"] = contact.groups.joined(separator: ",")
        }
        return encode(dict)
    }

    func formatGroupHeader(_ group: ContactGroup) -> String {
        encode([
            "type": "group_header",
            "name": group.name,
            "count": "\(group.contacts.count)"
        ])
    }

    func formatPresence(jid: BareJID, status: String, message: String?) -> String {
        var dict: [String: String] = [
            "type": "presence",
            "jid": jid.description,
            "status": status
        ]
        if let message {
            dict["message"] = message
        }
        return encode(dict)
    }

    func formatError(_ error: any Error) -> String {
        if let error = error as? RosterCommandError {
            return encode([
                "type": "error", "operation": error.operation.rawValue,
                "account": error.accountID.uuidString, "jid": error.jid,
                "remote_status": error.status.rawValue, "local_status": "notStarted",
                "subscription_status": "notRequested", "message": error.localizedDescription
            ])
        }
        return encode([
            "type": "error",
            "message": error.localizedDescription
        ])
    }

    func formatEvent(_ event: XMPPEvent, accountID: UUID) -> String? {
        let account = accountID.uuidString
        return switch event {
        case let .connected(jid): encode(["type": "connected", "jid": jid.description, "account": account])
        case let .streamResumed(jid): encode(["type": "stream_resumed", "jid": jid.description, "account": account])
        case let .disconnected(reason): formatDisconnect(reason, account: account)
        case let .authenticationFailed(message): encode(["type": "authentication_failed", "message": message, "account": account])
        case let .messageReceived(message): formatIncomingMessage(message, account: account)
        case let .messageCarbonReceived(forwarded): formatCarbonEvent(forwarded, isOutgoing: false, account: account)
        case let .messageCarbonSent(forwarded): formatCarbonEvent(forwarded, isOutgoing: true, account: account)
        case let .presenceSubscriptionRequest(from: jid): encode(["type": "subscription_request", "from": jid.description])
        case let .presenceSubscriptionApproved(from: jid): encode(["type": "subscription_approved", "from": jid.description])
        case let .presenceSubscriptionRevoked(from: jid): encode(["type": "subscription_revoked", "from": jid.description])
        case let .deliveryReceiptReceived(messageID, from): encode(["type": "delivery_receipt", "messageID": messageID, "from": from.bareJID.description, "account": account])
        case let .chatMarkerReceived(messageID, .displayed, from): encode(["type": "read_marker", "messageID": messageID, "from": from.bareJID.description, "account": account])
        case let .messageCorrected(originalID, newBody, from): encode(["type": "message_corrected", "originalID": originalID, "newBody": newBody, "from": from.bareJID.description, "account": account])
        case let .messageError(_, from, error): formatMessageError(from: from, error: error, account: account)
        case let .messageRetracted(originalID, from): encode(["type": "message_retracted", "original_id": originalID, "from": from.bareJID.description, "account": account])
        case let .messageModerated(originalID, moderator, room, reason): formatModeratedMessage(originalID: originalID, moderator: moderator, room: room, reason: reason, account: account)
        case let .roomJoined(room, occupancy, isNewlyCreated): formatRoomJoinedEvent(room: room, occupancy: occupancy, isNewlyCreated: isNewlyCreated, account: account)
        case let .roomOccupantJoined(room, occupant): encode(["type": "room_occupant_joined", "room": room.description, "nickname": occupant.nickname, "account": account])
        case let .roomOccupantLeft(room, occupant, reason): formatOccupantLeftEvent(room: room, occupant: occupant, reason: reason, account: account)
        case let .roomOccupantNickChanged(room, oldNickname, occupant): encode(["type": "room_nick_changed", "room": room.description, "old_nickname": oldNickname, "new_nickname": occupant.nickname, "account": account])
        case let .roomSubjectChanged(room, subject, setter): formatRoomSubjectEvent(room: room, subject: subject, setter: setter, account: account)
        case let .roomInviteReceived(invite): formatRoomInvite(invite: invite, account: account)
        case let .roomMessageReceived(message): formatIncomingRoomMessage(message, account: account)
        case let .mucPrivateMessageReceived(message): formatIncomingPrivateMessage(message, account: account)
        case let .roomDestroyed(room, reason, alternate): formatRoomDestroyedEvent(room: room, reason: reason, alternate: alternate, account: account)
        case .mucSelfPingFailed: nil
        case let .jingleFileTransferReceived(offer): formatFileOfferEvent(offer, account: account)
        case let .jingleFileTransferProgress(sid, bytesTransferred, totalBytes): formatTransferProgress(sid: sid, bytesTransferred: bytesTransferred, totalBytes: totalBytes, account: account)
        case let .jingleFileTransferCompleted(sid, transport): encode(["type": "jingle_transfer_completed", "sid": sid, "transport": transport.rawValue, "account": account])
        case let .jingleFileTransferFailed(sid, reason): encode(["type": "jingle_transfer_failed", "sid": sid, "reason": reason.rawValue, "account": account])
        case let .oobIQOfferReceived(offer): formatOOBIQOfferEvent(offer, account: account)
        case let .serviceOutageReceived(info): formatOutageEvent(info, account: account)
        case .presenceReceived, .iqReceived,
             .rosterUpdated,
             .presenceUpdated,
             .archivedMessagesLoaded,
             .chatStateChanged, .chatMarkerReceived,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .jingleChecksumReceived,
             .blockListLoaded, .contactBlocked, .contactUnblocked:
            nil
        case let .omemoDeviceListReceived(jid, devices): encode(["type": "omemo_device_list", "jid": jid.description, "devices": devices.map(String.init).joined(separator: ","), "account": account])
        case let .omemoSessionEstablished(jid, deviceID, identityKey): formatOMEMOSession(jid: jid, deviceID: deviceID, identityKey: identityKey, account: account)
        case let .omemoRecipientsPartial(conversation, dropped): formatOMEMORecipientsPartial(conversation: conversation, dropped: dropped, account: account)
        case .omemoEncryptedMessageReceived, .omemoSessionAdvanced: nil
        }
    }

    private func formatMessageError(from: JID, error: XMPPStanzaError, account: String) -> String {
        var dict: [String: String] = [
            "type": "message_error",
            "from": from.bareJID.description,
            "condition": error.condition.rawValue,
            "account": account
        ]
        if let text = error.text { dict["text"] = text }
        return encode(dict)
    }

    private func formatModeratedMessage(originalID: String, moderator: String, room: BareJID, reason: String?, account: String) -> String {
        var dict: [String: String] = ["type": "message_moderated", "original_id": originalID, "moderator": moderator, "room": room.description, "account": account]
        if let reason { dict["reason"] = reason }
        return encode(dict)
    }

    private func formatRoomInvite(invite: RoomInvite, account: String) -> String {
        var dict: [String: String] = [
            "type": "room_invite",
            "room": invite.room.description,
            "from": invite.from.bareJID.description,
            "account": account
        ]
        if let reason = invite.reason { dict["reason"] = reason }
        return encode(dict)
    }

    private func formatTransferProgress(sid: String, bytesTransferred: Int64, totalBytes: Int64, account: String) -> String {
        let (progress, _) = jingleProgressState(bytesTransferred: bytesTransferred, totalBytes: totalBytes)
        return encode([
            "type": "jingle_transfer_progress",
            "sid": sid,
            "progress": "\(Int(progress * 100))",
            "bytesTransferred": "\(bytesTransferred)",
            "totalBytes": "\(totalBytes)",
            "account": account
        ])
    }

    private func formatOMEMOSession(jid: BareJID, deviceID: UInt32, identityKey: [UInt8], account: String) -> String {
        let fingerprint = identityKey.map { String(format: "%02x", $0) }.joined()
        return encode([
            "type": "omemo_session_established",
            "jid": jid.description,
            "deviceID": "\(deviceID)",
            "fingerprint": fingerprint,
            "account": account
        ])
    }

    /// Structured per-device drops so JSON consumers can parse without
    /// splitting on a custom `<jid>/<deviceID>` mini-format. The envelope
    /// shape diverges from this file's flat-dict pattern intentionally —
    /// dropped recipients are the only event payload with a real list.
    private func formatOMEMORecipientsPartial(
        conversation: BareJID, dropped: [DroppedOMEMORecipient], account: String
    ) -> String {
        let envelope = OMEMORecipientsPartialJSON(
            type: "omemo_recipients_partial",
            conversation: conversation.description,
            dropped: dropped.map {
                OMEMORecipientsPartialJSON.DroppedDevice(jid: $0.jid.description, deviceID: $0.deviceID)
            },
            droppedCount: dropped.count,
            account: account
        )
        return encode(envelope)
    }

    private func formatCarbonEvent(_ forwarded: ForwardedMessage, isOutgoing: Bool, account: String) -> String? {
        let jid = isOutgoing ? forwarded.message.to?.bareJID : forwarded.message.from?.bareJID
        let oob = forwarded.message.oobData
        let body = forwarded.message.body ?? oob.first?.url
        guard let jid, let body else { return nil }
        let jidKey = isOutgoing ? "to" : "from"
        let direction = isOutgoing ? "outgoing" : "incoming"
        var dict: [String: String] = [
            "type": "message", "direction": direction, "carbon": "true",
            jidKey: jid.description, "body": body,
            "account": account, "timestamp": formatTimestamp(Date())
        ]
        if body.hasPrefix("/me ") {
            dict["action"] = "true"
        }
        let extraOOB = oob.filter { $0.url != body }
        if !extraOOB.isEmpty {
            dict["attachments"] = extraOOB.map(\.url).joined(separator: ",")
        }
        return encode(dict)
    }

    private func formatDisconnect(_ reason: DisconnectReason, account: String) -> String {
        var dict: [String: String] = ["type": "disconnected", "account": account]
        switch reason {
        case .requested:
            dict["reason"] = "requested"
        case let .streamError(condition, text):
            dict["reason"] = "stream_error"
            if let condition { dict["condition"] = condition.rawValue }
            if let text { dict["text"] = text }
        case let .connectionLost(message):
            dict["reason"] = "connection_lost"
            dict["message"] = message
        case let .redirect(host, port):
            dict["reason"] = "redirect"
            dict["host"] = host
            if let port { dict["port"] = "\(port)" }
        }
        return encode(dict)
    }

    private func formatIncomingMessage(_ message: XMPPMessage, account: String) -> String? {
        guard let from = message.from?.bareJID else { return nil }
        let oob = message.oobData
        let body = message.body ?? oob.first?.url
        guard let body else { return nil }
        var dict: [String: String] = [
            "type": "message", "direction": "incoming", "from": from.description,
            "body": body, "account": account, "timestamp": formatTimestamp(Date())
        ]
        if body.hasPrefix("/me ") {
            dict["action"] = "true"
        }
        let extraOOB = oob.filter { $0.url != body }
        if !extraOOB.isEmpty {
            dict["attachments"] = extraOOB.map(\.url).joined(separator: ",")
        }
        return encode(dict)
    }

    private func formatOOBIQOfferEvent(_ offer: OOBIQOffer, account: String) -> String {
        var dict: [String: String] = [
            "type": "oob_iq_offer",
            "id": offer.id,
            "offerId": offer.offerID,
            "url": offer.url,
            "from": offer.from.bareJID.description,
            "account": account
        ]
        if let desc = offer.desc { dict["desc"] = desc }
        return encode(dict)
    }

    private func formatOutageEvent(_ info: ServiceOutageInfo, account: String) -> String {
        var dict: [String: String] = ["type": "service_outage", "account": account]
        if let desc = info.description { dict["description"] = desc }
        if let end = info.expectedEnd { dict["expected_end"] = end }
        if let alt = info.alternativeDomain { dict["alternative_domain"] = alt }
        return encode(dict)
    }

    func formatTransferProgress(fileName: String, fileSize: Int64, progress: Double) -> String {
        encode([
            "type": "transfer_progress",
            "fileName": fileName,
            "fileSize": formatByteCount(fileSize),
            "progress": "\(Int(progress * 100))"
        ])
    }

    func formatFileMessage(fileName: String, url: String, fileSize: Int64?) -> String {
        var dict: [String: String] = [
            "type": "file",
            "fileName": fileName,
            "url": url
        ]
        if let fileSize {
            dict["fileSize"] = formatByteCount(fileSize)
            dict["fileSizeBytes"] = "\(fileSize)"
        }
        return encode(dict)
    }

    private func formatFileOfferEvent(_ offer: JingleFileOffer, account: String) -> String {
        encode([
            "type": "file_offer",
            "fileName": offer.fileName,
            "fileSize": formatByteCount(offer.fileSize),
            "fileSizeBytes": "\(offer.fileSize)",
            "from": offer.from.bareJID.description,
            "sid": offer.sid,
            "offerId": offer.offerID,
            "account": account
        ])
    }

    func formatJingleTransferProgress(fileName: String, fileSize: Int64, progress: Double, state: String) -> String {
        encode([
            "type": "jingle_transfer_progress",
            "fileName": fileName,
            "fileSize": formatByteCount(fileSize),
            "progress": "\(Int(progress * 100))",
            "state": state
        ])
    }

    func formatJingleTransferCompleted(sid: String, transport: JingleTransportKind) -> String {
        encode([
            "type": "jingle_transfer_completed",
            "sid": sid,
            "transport": transport.rawValue
        ])
    }

    func formatJingleTransferFailed(sid: String, reason: JingleTransferFailureReason) -> String {
        encode([
            "type": "jingle_transfer_failed",
            "sid": sid,
            "reason": reason.rawValue
        ])
    }

    func formatTypingIndicator(from jid: BareJID, state: ChatState) -> String? {
        encode([
            "type": "typing",
            "jid": jid.description,
            "state": state.rawValue
        ])
    }

    // MARK: - Room Formatting

    func formatRoom(_ room: DiscoveredRoom) -> String {
        var dict: [String: String] = [
            "type": "room",
            "jid": room.jidString
        ]
        if let name = room.name {
            dict["name"] = name
        }
        return encode(dict)
    }

    func formatBookmark(_ bookmark: RoomBookmark) -> String {
        var dict: [String: String] = [
            "type": "bookmark",
            "jid": bookmark.jidString,
            "autojoin": bookmark.autojoin ? "true" : "false"
        ]
        if let name = bookmark.name { dict["name"] = name }
        if let nick = bookmark.nickname { dict["nickname"] = nick }
        return encode(dict)
    }

    func formatRoomParticipant(_ participant: RoomParticipant) -> String {
        var dict: [String: String] = [
            "type": "room_participant",
            "nickname": participant.nickname,
            "role": participant.role.rawValue,
            "affiliation": participant.affiliation.rawValue
        ]
        if let jid = participant.jidString {
            dict["jid"] = jid
        }
        return encode(dict)
    }

    func formatRoomParticipantGroupHeader(_ group: RoomParticipantGroup) -> String {
        encode([
            "type": "room_participant_group",
            "affiliation": group.affiliation.displayName,
            "count": "\(group.participants.count)"
        ])
    }

    func formatRoomJoinedConfirmation(room: String, nickname: String, participantCount: Int, subject: String?) -> String {
        var dict: [String: String] = [
            "type": "room_joined",
            "room": room,
            "nickname": nickname,
            "participants": "\(participantCount)"
        ]
        if let subject, !subject.isEmpty {
            dict["subject"] = subject
        }
        return encode(dict)
    }

    private func formatRoomJoinedEvent(room: BareJID, occupancy: RoomOccupancy, isNewlyCreated: Bool, account: String) -> String {
        var dict: [String: String] = [
            "type": "room_joined", "room": room.description,
            "nickname": occupancy.nickname,
            "participants": "\(occupancy.occupants.count)",
            "account": account
        ]
        if isNewlyCreated {
            dict["newly_created"] = "true"
        }
        if occupancy.flags.contains(.nonAnonymous) {
            dict["non_anonymous"] = "true"
        }
        if occupancy.flags.contains(.logged) {
            dict["logged"] = "true"
        }
        if let subject = occupancy.subject {
            dict["subject"] = subject
        }
        return encode(dict)
    }

    private func formatOccupantLeftEvent(room: BareJID, occupant: RoomOccupant, reason: OccupantLeaveReason?, account: String) -> String {
        var dict: [String: String] = [
            "type": "room_occupant_left",
            "room": room.description,
            "nickname": occupant.nickname,
            "account": account
        ]
        switch reason {
        case let .kicked(r):
            dict["leave_reason"] = "kicked"
            if let r { dict["reason_text"] = r }
        case let .banned(r):
            dict["leave_reason"] = "banned"
            if let r { dict["reason_text"] = r }
        case let .affiliationChanged(r):
            dict["leave_reason"] = "affiliation_changed"
            if let r { dict["reason_text"] = r }
        case .serviceShutdown:
            dict["leave_reason"] = "service_shutdown"
        case nil:
            break
        }
        return encode(dict)
    }

    private func formatRoomDestroyedEvent(room: BareJID, reason: String?, alternate: BareJID?, account: String) -> String {
        var dict: [String: String] = [
            "type": "room_destroyed",
            "room": room.description,
            "account": account
        ]
        if let reason { dict["reason"] = reason }
        if let alternate { dict["alternate"] = alternate.description }
        return encode(dict)
    }

    private func formatRoomSubjectEvent(room: BareJID, subject: String?, setter: JID?, account: String) -> String {
        var dict: [String: String] = [
            "type": "room_subject_changed",
            "room": room.description,
            "account": account
        ]
        if let subject { dict["subject"] = subject }
        if let setter { dict["setter"] = setter.bareJID.description }
        return encode(dict)
    }

    private func formatIncomingRoomMessage(_ message: XMPPMessage, account: String) -> String? {
        guard let from = message.from else { return nil }
        let oob = message.oobData
        let body = message.body ?? oob.first?.url
        guard let body else { return nil }
        let nickname = nicknameFromJID(from)
        var dict: [String: String] = [
            "type": "room_message", "direction": "incoming",
            "room": from.bareJID.description, "nickname": nickname,
            "body": body, "account": account,
            "timestamp": formatTimestamp(Date())
        ]
        if body.hasPrefix("/me ") {
            dict["action"] = "true"
        }
        let extraOOB = oob.filter { $0.url != body }
        if !extraOOB.isEmpty {
            dict["attachments"] = extraOOB.map(\.url).joined(separator: ",")
        }
        return encode(dict)
    }

    private func formatIncomingPrivateMessage(_ message: XMPPMessage, account: String) -> String? {
        guard let from = message.from else { return nil }
        let oob = message.oobData
        let body = message.body ?? oob.first?.url
        guard let body else { return nil }
        let nickname = nicknameFromJID(from)
        var dict: [String: String] = [
            "type": "muc_private_message", "direction": "incoming",
            "room": from.bareJID.description, "nickname": nickname,
            "body": body, "account": account,
            "timestamp": formatTimestamp(Date())
        ]
        if body.hasPrefix("/me ") {
            dict["action"] = "true"
        }
        let extraOOB = oob.filter { $0.url != body }
        if !extraOOB.isEmpty {
            dict["attachments"] = extraOOB.map(\.url).joined(separator: ",")
        }
        return encode(dict)
    }

    func formatTLSInfo(_ info: TLSInfo) -> String {
        encode(TLSInfoOutput(info: info, expires: info.certificateExpiry.map(formatTimestamp)))
    }

    func formatServerInfo(_ info: ServerInfo) -> String {
        var dict = ["type": "server_info"]
        for address in info.contactAddresses {
            let key = address.type.rawValue
            if let existing = dict[key] {
                dict[key] = existing + "," + address.address
            } else {
                dict[key] = address.address
            }
        }
        return encode(dict)
    }

    func formatRegistrationForm(_ form: RegistrationFormInfo) -> String {
        var dict: [String: String] = [
            "type": "registration_form",
            "form_kind": form.formKind == .dataForm ? "data_form" : "legacy",
            "is_registered": form.isRegistered ? "true" : "false"
        ]
        if let instructions = form.instructions { dict["instructions"] = instructions }
        switch form.formKind {
        case .legacy:
            if form.hasUsername { dict["has_username"] = "true" }
            if form.hasPassword { dict["has_password"] = "true" }
            if form.hasEmail { dict["has_email"] = "true" }
        case .dataForm:
            for field in form.dataFormFields where field.isUserEditable {
                dict["field_\(field.variable)"] = field.values.joined(separator: ",")
            }
        }
        return encode(dict)
    }

    func formatSearchedChannel(_ channel: SearchedChannel) -> String {
        var dict: [String: String] = [
            "type": "searched_channel",
            "jid": channel.jidString
        ]
        if let name = channel.name { dict["name"] = name }
        if let userCount = channel.userCount { dict["users"] = "\(userCount)" }
        if let isOpen = channel.isOpen { dict["is_open"] = isOpen ? "true" : "false" }
        if let description = channel.description { dict["description"] = description }
        return encode(dict)
    }

    func formatOMEMOFingerprint(_ fingerprint: String) -> String {
        encode(["type": "omemo_fingerprint", "fingerprint": fingerprint])
    }

    func formatOMEMODevice(_ device: OMEMODeviceInfo) -> String {
        var dict: [String: String] = [
            "type": "omemo_device",
            "jid": device.peerJID,
            "deviceID": "\(device.deviceID)",
            "trust": device.trustLevel.rawValue
        ]
        if !device.fingerprint.isEmpty { dict["fingerprint"] = device.fingerprint }
        return encode(dict)
    }

    func formatOMEMOTrustChange(jid: String, deviceID: UInt32, trustLevel: OMEMOTrustLevel) -> String {
        encode([
            "type": "omemo_trust",
            "jid": jid,
            "deviceID": "\(deviceID)",
            "trust": trustLevel.rawValue
        ])
    }

    func formatProfile(_ profile: ProfileInfo) -> String {
        var json = ProfileJSON()
        json.fullName = profile.fullName
        json.nickname = profile.nickname
        json.givenName = profile.givenName
        json.familyName = profile.familyName
        json.organization = profile.organization
        json.title = profile.title
        json.role = profile.role
        let emailAddresses = profile.emails.map(\.address).filter { !$0.isEmpty }
        if !emailAddresses.isEmpty { json.emails = emailAddresses }
        let phoneNumbers = profile.telephones.map(\.number).filter { !$0.isEmpty }
        if !phoneNumbers.isEmpty { json.phones = phoneNumbers }
        json.url = profile.url
        json.birthday = profile.birthday
        json.note = profile.note
        return encode(json)
    }

    /// Synthesized `Encodable` references each stored property in
    /// `encode(to:)`, but Periphery's analyzer still flags them as
    /// assign-only. Suppress per-property; the alternative — a manual
    /// `encode(to:)` matching `ProfileJSON` — would re-introduce the
    /// stringly-typed `CodingKeys` boilerplate the structured envelope was
    /// meant to avoid.
    private struct OMEMORecipientsPartialJSON: Encodable {
        // periphery:ignore
        let type: String
        // periphery:ignore
        let conversation: String
        // periphery:ignore
        let dropped: [DroppedDevice]
        // periphery:ignore
        let droppedCount: Int
        // periphery:ignore
        let account: String

        struct DroppedDevice: Encodable {
            // periphery:ignore
            let jid: String
            // periphery:ignore
            let deviceID: UInt32
        }
    }

    private struct ProfileJSON: Encodable {
        var type = "profile"
        var fullName: String?
        var nickname: String?
        var givenName: String?
        var familyName: String?
        var organization: String?
        var title: String?
        var role: String?
        var emails: [String]?
        var phones: [String]?
        var url: String?
        var birthday: String?
        var note: String?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encodeIfPresent(fullName, forKey: .fullName)
            try container.encodeIfPresent(nickname, forKey: .nickname)
            try container.encodeIfPresent(givenName, forKey: .givenName)
            try container.encodeIfPresent(familyName, forKey: .familyName)
            try container.encodeIfPresent(organization, forKey: .organization)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(role, forKey: .role)
            try container.encodeIfPresent(emails, forKey: .emails)
            try container.encodeIfPresent(phones, forKey: .phones)
            try container.encodeIfPresent(url, forKey: .url)
            try container.encodeIfPresent(birthday, forKey: .birthday)
            try container.encodeIfPresent(note, forKey: .note)
        }

        private enum CodingKeys: String, CodingKey {
            case type, fullName, nickname, givenName, familyName
            case organization, title, role, emails, phones, url, birthday, note
        }
    }

    private func encode(_ value: some Encodable) -> String {
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    /// ISO 8601 without fractional seconds for cleaner JSON output.
    private func formatTimestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }
}

private struct TLSInfoOutput: Encodable {
    let info: TLSInfo
    let expires: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case tlsVersion = "tls_version"
        case cipherSuite = "cipher_suite"
        case subject, issuer, expires, sha256
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("tls_info", forKey: .type)
        try container.encode(info.protocolVersion, forKey: .tlsVersion)
        try container.encode(info.cipherSuite, forKey: .cipherSuite)
        try container.encodeIfPresent(info.certificateSubject, forKey: .subject)
        try container.encodeIfPresent(info.certificateIssuer, forKey: .issuer)
        try container.encodeIfPresent(expires, forKey: .expires)
        try container.encodeIfPresent(info.certificateSHA256, forKey: .sha256)
    }
}
