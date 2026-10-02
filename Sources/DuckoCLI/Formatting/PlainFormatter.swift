import DuckoCore
import DuckoXMPP
import Foundation

struct PlainFormatter: CLIFormatter {
    func formatMessage(_ message: ChatMessage, accountJID: BareJID? = nil) -> String {
        let timestamp = iso8601(message.timestamp)
        let direction = message.isOutgoing ? "->" : "<-"
        let displayJID = message.isOutgoing ? (accountJID?.description ?? message.fromJID) : message.fromJID
        let body = if message.isUndecryptable {
            "\(message.fromJID): error: \(ChatMessage.undecryptableText)"
        } else if message.body.hasPrefix("/me ") {
            "* \(displayJID) \(message.body.dropFirst(4))"
        } else {
            // A received file has no text of its own, so the sender line names the file rather than reading as empty.
            "\(message.fromJID): \(message.previewText)"
        }
        var line = "[\(timestamp)] \(direction) \(body)"
        if message.isEncrypted {
            line += " [encrypted]"
        }
        if message.isEdited {
            line += " [edited]"
        }
        if message.isOutgoing, message.isDelivered {
            line += " [delivered]"
        }
        if let errorText = message.errorText {
            line += " [error: \(errorText)]"
        }
        for attachment in attachmentsBelowSenderLine(message) {
            line += "\n" + formatFileMessage(fileName: attachment.displayFileName, url: attachment.url, fileSize: attachment.fileSize)
        }
        return line
    }

    func formatEmptyResult(_ result: CLIEmptyResult) -> String {
        result.message
    }

    func formatRosterCommand(_ outcome: RosterCommandOutcome) -> String {
        outcome.message
    }

    func formatAccount(_ account: Account) -> String {
        "\(account.jid) (\(account.id))"
    }

    func formatContactWithPresence(_ contact: Contact, presence: PresenceService.PresenceStatus?) -> String {
        let indicator = switch presence {
        case .available:
            "[+]"
        case .away, .xa:
            "[~]"
        case .dnd:
            "[-]"
        case .offline, .none:
            "[ ]"
        }
        let displayName = contact.localAlias ?? contact.name ?? contact.jid.description
        return "\(indicator) \(displayName) (\(contact.jid)) [\(contact.subscription.rawValue)]"
    }

    func formatGroupHeader(_ group: ContactGroup) -> String {
        "--- \(group.name) (\(group.contacts.count)) ---"
    }

    func formatPresence(jid: BareJID, status: String, message: String?) -> String {
        if let message {
            return "\(jid) is \(status): \(message)"
        }
        return "\(jid) is \(status)"
    }

    func formatError(_ error: any Error) -> String {
        "error: \(error.localizedDescription)"
    }

    func formatEvent(_ event: XMPPEvent, accountID: UUID) -> String? {
        switch event {
        case let .connected(jid): "connected as \(jid)"
        case let .streamResumed(jid): "stream resumed as \(jid)"
        case let .disconnected(reason): formatDisconnect(reason)
        case let .authenticationFailed(message): "authentication failed: \(message)"
        case let .messageReceived(message): formatIncomingMessage(message)
        case let .messageCarbonReceived(forwarded): formatCarbonEvent(forwarded, isOutgoing: false)
        case let .messageCarbonSent(forwarded): formatCarbonEvent(forwarded, isOutgoing: true)
        case let .presenceSubscriptionRequest(from: jid): "Subscription request from \(jid)"
        case let .presenceSubscriptionApproved(from: jid): "Subscription approved by \(jid)"
        case let .presenceSubscriptionRevoked(from: jid): "Subscription revoked by \(jid)"
        case let .deliveryReceiptReceived(messageID, from): "delivery receipt: \(messageID) from \(from.bareJID)"
        case let .messageCorrected(_, newBody, from): "message corrected by \(from.bareJID): \(newBody)"
        case let .messageError(_, from, error): "message error from \(from.bareJID): \(error.displayText)"
        case let .messageRetracted(originalID, from): "[retracted] message retracted by \(from.bareJID) (id: \(originalID))"
        case let .messageModerated(originalID, moderator, room, reason): formatModeratedMessage(originalID: originalID, moderator: moderator, room: room, reason: reason)
        case let .roomJoined(room, occupancy, isNewlyCreated): formatRoomJoinedMUC(room: room, occupancy: occupancy, isNewlyCreated: isNewlyCreated)
        case let .roomOccupantJoined(room, occupant): "\(room): \(occupant.nickname) joined"
        case let .roomOccupantLeft(room, occupant, reason): formatOccupantLeftMUC(room: room, occupant: occupant, reason: reason)
        case let .roomOccupantNickChanged(room, oldNickname, occupant): "\(room): \(oldNickname) is now known as \(occupant.nickname)"
        case let .roomSubjectChanged(room, subject, setter): formatRoomSubject(room: room, subject: subject, setter: setter)
        case let .roomInviteReceived(invite): formatRoomInviteMUC(invite)
        case let .roomMessageReceived(message): formatIncomingRoomMessage(message)
        case let .mucPrivateMessageReceived(message): formatIncomingPrivateMessage(message)
        case let .roomDestroyed(room, reason, alternate): formatRoomDestroyedMUC(room: room, reason: reason, alternate: alternate)
        case .mucSelfPingFailed: nil
        case let .jingleFileTransferReceived(offer): formatFileOffer(fileName: offer.fileName, fileSize: offer.fileSize, from: offer.from.bareJID.description, offerID: offer.offerID)
        case let .jingleFileTransferProgress(sid, bytesTransferred, totalBytes): formatTransferProgress(sid: sid, bytesTransferred: bytesTransferred, totalBytes: totalBytes)
        case let .jingleFileTransferCompleted(sid, transport): formatJingleTransferCompleted(sid: sid, transport: transport)
        case let .jingleFileTransferFailed(sid, reason): formatJingleTransferFailed(sid: sid, reason: reason)
        case let .oobIQOfferReceived(offer): formatOOBOffer(offer: offer)
        case let .serviceOutageReceived(info): formatOutageEvent(info)
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
        case let .omemoDeviceListReceived(jid, devices): "OMEMO devices for \(jid): \(devices.map(String.init).joined(separator: ", "))"
        case let .omemoSessionEstablished(jid, deviceID, _): "OMEMO session established with \(jid) device \(deviceID)"
        case let .omemoRecipientsPartial(conversation, dropped): "OMEMO: skipped \(dropped.count) device(s) for \(conversation) — bundles missing"
        case .omemoEncryptedMessageReceived, .omemoSessionAdvanced: nil
        }
    }

    private func formatModeratedMessage(originalID: String, moderator: String, room: BareJID, reason: String?) -> String {
        let reasonStr = reason.map { ": \($0)" } ?? ""
        return "[moderated] message moderated by \(moderator) in \(room) (id: \(originalID))\(reasonStr)"
    }

    private func formatRoomSubject(room: BareJID, subject: String?, setter: JID?) -> String {
        let who = setter?.bareJID.description ?? "someone"
        let topic = subject ?? "(cleared)"
        return "\(room): topic changed by \(who): \(topic)"
    }

    private func formatTransferProgress(sid: String, bytesTransferred: Int64, totalBytes: Int64) -> String {
        let (progress, state) = jingleProgressState(bytesTransferred: bytesTransferred, totalBytes: totalBytes)
        return formatJingleTransferProgress(
            fileName: sid, fileSize: totalBytes, progress: progress, state: state
        )
    }

    private func formatOOBOffer(offer: OOBIQOffer) -> String {
        let fileName = oobFileName(offer.url)
        return formatFileOffer(
            fileName: fileName, fileSize: 0,
            from: offer.from.bareJID.description, offerID: offer.offerID
        )
    }

    private func formatOutageEvent(_ info: ServiceOutageInfo) -> String {
        var line = "Service outage"
        if let desc = info.description {
            line += ": \(desc)"
        }
        if let end = info.expectedEnd {
            line += " (expected end: \(end))"
        }
        if let alt = info.alternativeDomain {
            line += " [alternative: \(alt)]"
        }
        return line
    }

    private func formatCarbonEvent(_ forwarded: ForwardedMessage, isOutgoing: Bool) -> String? {
        let jid = isOutgoing ? forwarded.message.to?.bareJID : forwarded.message.from?.bareJID
        let oob = forwarded.message.oobData
        let body = forwarded.message.body ?? oob.first?.url
        guard let jid, let body else { return nil }
        let timestamp = iso8601(Date())
        let direction = isOutgoing ? "->" : "<-"
        let formatted = if body.hasPrefix("/me ") {
            "* \(jid) \(body.dropFirst(4))"
        } else {
            "\(jid): \(body)"
        }
        var line = "[\(timestamp)] \(direction) \(formatted) [carbon]"
        for item in oob where item.url != body {
            line += "\n" + formatFileMessage(fileName: oobFileName(item.url), url: item.url, fileSize: nil)
        }
        return line
    }

    private func formatIncomingMessage(_ message: XMPPMessage) -> String? {
        guard let from = message.from?.bareJID else { return nil }
        let oob = message.oobData
        let body = message.body ?? oob.first?.url
        guard let body else { return nil }
        let timestamp = iso8601(Date())
        let formatted = if body.hasPrefix("/me ") {
            "* \(from) \(body.dropFirst(4))"
        } else {
            "\(from): \(body)"
        }
        var line = "[\(timestamp)] <- \(formatted)"
        for item in oob where item.url != body {
            line += "\n" + formatFileMessage(fileName: oobFileName(item.url), url: item.url, fileSize: nil)
        }
        return line
    }

    private func formatRoomJoinedMUC(room: BareJID, occupancy: RoomOccupancy, isNewlyCreated: Bool) -> String {
        var line = "Joined \(room) as \(occupancy.nickname) (\(occupancy.occupants.count) participants)"
        if isNewlyCreated {
            line += " [new room]"
        }
        if occupancy.flags.contains(.nonAnonymous) {
            line += " [non-anonymous]"
        }
        if occupancy.flags.contains(.logged) {
            line += " [logged]"
        }
        if let subject = occupancy.subject, !subject.isEmpty {
            line += " — topic: \(subject)"
        }
        return line
    }

    private func formatOccupantLeftMUC(room: BareJID, occupant: RoomOccupant, reason: OccupantLeaveReason?) -> String {
        "\(room): \(occupant.nickname) \(occupantLeaveText(reason))"
    }

    private func formatRoomInviteMUC(_ invite: RoomInvite) -> String {
        var line = "Room invite: \(invite.from.bareJID) invites you to \(invite.room)"
        if let reason = invite.reason {
            line += " (\(reason))"
        }
        return line
    }

    private func formatRoomDestroyedMUC(room: BareJID, reason: String?, alternate: BareJID?) -> String {
        var line = "Room \(room) was destroyed"
        if let reason {
            line += " (\(reason))"
        }
        if let alternate {
            line += " → \(alternate)"
        }
        return line
    }

    private func formatIncomingRoomMessage(_ message: XMPPMessage) -> String? {
        guard let from = message.from else { return nil }
        let oob = message.oobData
        let body = message.body ?? oob.first?.url
        guard let body else { return nil }
        let nickname = nicknameFromJID(from)
        let timestamp = iso8601(Date())
        let formatted = if body.hasPrefix("/me ") {
            "* \(nickname) \(body.dropFirst(4))"
        } else {
            "\(from.bareJID)/\(nickname): \(body)"
        }
        var line = "[\(timestamp)] <- \(formatted)"
        for item in oob where item.url != body {
            line += "\n" + formatFileMessage(fileName: oobFileName(item.url), url: item.url, fileSize: nil)
        }
        return line
    }

    private func formatIncomingPrivateMessage(_ message: XMPPMessage) -> String? {
        guard let from = message.from else { return nil }
        let oob = message.oobData
        let body = message.body ?? oob.first?.url
        guard let body else { return nil }
        let nickname = nicknameFromJID(from)
        let timestamp = iso8601(Date())
        let formatted = if body.hasPrefix("/me ") {
            "[PM] * \(nickname) \(body.dropFirst(4))"
        } else {
            "[PM] \(from.bareJID)/\(nickname): \(body)"
        }
        var line = "[\(timestamp)] <- \(formatted)"
        for item in oob where item.url != body {
            line += "\n" + formatFileMessage(fileName: oobFileName(item.url), url: item.url, fileSize: nil)
        }
        return line
    }

    private func formatDisconnect(_ reason: DisconnectReason) -> String {
        switch reason {
        case .requested:
            return "disconnected"
        case let .streamError(condition, text):
            return "disconnected: \(AccountService.streamErrorMessage(condition: condition, text: text))"
        case let .connectionLost(message):
            return "disconnected: \(AccountService.connectionLostMessage(message))"
        case let .redirect(host, port):
            let target = port.map { "\(host):\($0)" } ?? host
            return "redirected to \(target)"
        }
    }

    // MARK: - Room Formatting

    func formatRoom(_ room: DiscoveredRoom) -> String {
        if let name = room.name {
            return "\(name) (\(room.jidString))"
        }
        return room.jidString
    }

    func formatBookmark(_ bookmark: RoomBookmark) -> String {
        var line = bookmark.name ?? bookmark.jidString
        if bookmark.name != nil {
            line += " (\(bookmark.jidString))"
        }
        if bookmark.autojoin {
            line += " [autojoin]"
        }
        if let nick = bookmark.nickname {
            line += " nick: \(nick)"
        }
        return line
    }

    func formatRoomParticipant(_ participant: RoomParticipant) -> String {
        var line = "  \(participant.nickname)"
        if let jid = participant.jidString {
            line += " (\(jid))"
        }
        line += " [\(participant.role.rawValue)]"
        return line
    }

    func formatRoomParticipantGroupHeader(_ group: RoomParticipantGroup) -> String {
        "--- \(group.affiliation.displayName) (\(group.participants.count)) ---"
    }

    func formatRoomJoinedConfirmation(room: String, nickname: String, participantCount: Int, subject: String?) -> String {
        var line = "Joined \(room) as \(nickname) (\(participantCount) participants)"
        if let subject, !subject.isEmpty {
            line += "\nTopic: \(subject)"
        }
        return line
    }

    func formatTransferProgress(fileName: String, fileSize: Int64, progress: Double) -> String {
        let percent = Int(progress * 100)
        return "Uploading \(fileName) (\(formatByteCount(fileSize))): \(percent)%"
    }

    func formatFileMessage(fileName: String, url: String, fileSize: Int64?) -> String {
        var line = "File: \(fileName)"
        if let fileSize {
            line += " (\(formatByteCount(fileSize)))"
        }
        line += "\n  \(url)"
        return line
    }

    func formatFileOffer(fileName: String, fileSize: Int64, from: String, offerID: String) -> String {
        "[File offer] \(fileName) (\(formatByteCount(fileSize))) from \(from) (\(offerID)) — /accept or /decline"
    }

    func formatJingleTransferProgress(fileName: String, fileSize: Int64, progress: Double, state: String) -> String {
        let percent = Int(progress * 100)
        return "\(fileName) (\(formatByteCount(fileSize))): \(state) \(percent)%"
    }

    func formatJingleTransferCompleted(sid: String, transport: JingleTransportKind) -> String {
        "Transfer completed: \(sid) — \(transportLabel(for: transport))"
    }

    func formatJingleTransferFailed(sid: String, reason: JingleTransferFailureReason) -> String {
        "Transfer failed: \(sid) — \(reason.displayText)"
    }

    private func transportLabel(for transport: JingleTransportKind) -> String {
        switch transport {
        case .socks5: "SOCKS5"
        case .ibb: "IBB"
        }
    }

    func formatTypingIndicator(from jid: BareJID, state: ChatState) -> String? {
        state == .composing ? "[\(jid) is typing...]" : nil
    }

    func formatTLSInfo(_ info: TLSInfo) -> String {
        var lines: [String] = []
        lines.append("TLS Version: \(info.protocolVersion)")
        lines.append("Cipher Suite: \(info.cipherSuite ?? "Not available")")
        if let subject = info.certificateSubject {
            lines.append("Subject: \(subject)")
        }
        if let issuer = info.certificateIssuer {
            lines.append("Issuer: \(issuer)")
        }
        if let expiry = info.certificateExpiry {
            lines.append("Expires: \(iso8601(expiry))")
        }
        if let fingerprint = info.certificateSHA256 {
            lines.append("SHA-256: \(fingerprint)")
        }
        return lines.joined(separator: "\n")
    }

    func formatServerInfo(_ info: ServerInfo) -> String {
        guard !info.contactAddresses.isEmpty else {
            return "(no server contact information)"
        }
        var lines: [String] = []
        let grouped = Dictionary(grouping: info.contactAddresses, by: \.type)
        for type in ContactAddressType.allCases {
            guard let addresses = grouped[type], !addresses.isEmpty else { continue }
            lines.append("\(type.displayName):")
            for address in addresses {
                lines.append("  \(address.address)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func formatRegistrationForm(_ form: RegistrationFormInfo) -> String {
        var lines: [String] = []
        let kindLabel = form.formKind == .dataForm ? "Data Form" : "Legacy"
        lines.append("Registration Form (\(kindLabel))")
        lines.append("Status: \(form.isRegistered ? "Registered" : "Not registered")")
        if let instructions = form.instructions, !instructions.isEmpty {
            lines.append("Instructions: \(instructions)")
        }
        switch form.formKind {
        case .legacy:
            lines.append("Fields:")
            if form.hasUsername { lines.append("  Username: (required)") }
            if form.hasPassword { lines.append("  Password: (required)") }
            if form.hasEmail { lines.append("  Email: (optional)") }
        case .dataForm:
            lines.append("Fields:")
            for field in form.dataFormFields where field.isUserEditable {
                let label = field.displayLabel
                let value = field.values.joined(separator: ", ")
                lines.append("  \(label): \(value.isEmpty ? "(empty)" : value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func formatSearchedChannel(_ channel: SearchedChannel) -> String {
        var line = channel.name ?? channel.jidString
        if channel.name != nil {
            line += " (\(channel.jidString))"
        }
        if let userCount = channel.userCount {
            line += " \(userCount) users"
        }
        if let isOpen = channel.isOpen {
            line += isOpen ? " [open]" : " [closed]"
        }
        return line
    }

    func formatOMEMOFingerprint(_ fingerprint: String) -> String {
        OMEMODeviceInfo.formatFingerprint(fingerprint)
    }

    func formatOMEMODevice(_ device: OMEMODeviceInfo) -> String {
        "  \(device.deviceID)  \(omemoFingerprintText(device))  [\(device.trustLevel.rawValue)]"
    }

    func formatOMEMOTrustChange(jid: String, deviceID: UInt32, trustLevel: OMEMOTrustLevel) -> String {
        omemoTrustChangeText(jid: jid, deviceID: deviceID, trustLevel: trustLevel)
    }

    func formatProfile(_ profile: ProfileInfo) -> String {
        var lines: [String] = []
        appendProfileNameFields(profile, to: &lines)
        appendProfileDetailFields(profile, to: &lines)
        if lines.isEmpty { return "(no profile data)" }
        return lines.joined(separator: "\n")
    }

    private func appendProfileNameFields(_ profile: ProfileInfo, to lines: inout [String]) {
        if let fullName = profile.fullName { lines.append("Full Name: \(fullName)") }
        if let nickname = profile.nickname { lines.append("Nickname: \(nickname)") }
        if let givenName = profile.givenName { lines.append("Given Name: \(givenName)") }
        if let familyName = profile.familyName { lines.append("Family Name: \(familyName)") }
        if let organization = profile.organization { lines.append("Organization: \(organization)") }
        if let title = profile.title { lines.append("Title: \(title)") }
        if let role = profile.role { lines.append("Role: \(role)") }
    }

    private func appendProfileDetailFields(_ profile: ProfileInfo, to lines: inout [String]) {
        for email in profile.emails where !email.address.isEmpty {
            lines.append("Email: \(email.address)")
        }
        for tel in profile.telephones where !tel.number.isEmpty {
            lines.append("Phone: \(tel.number)")
        }
        if let url = profile.url { lines.append("URL: \(url)") }
        if let birthday = profile.birthday { lines.append("Birthday: \(birthday)") }
        if let note = profile.note { lines.append("Note: \(note)") }
    }
}
