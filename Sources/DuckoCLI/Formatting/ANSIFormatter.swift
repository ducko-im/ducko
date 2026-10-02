import DuckoCore
import DuckoXMPP
import Foundation

struct ANSIFormatter: CLIFormatter {
    // MARK: - ANSI Codes

    private enum Color {
        static let reset = "\u{001B}[0m"
        static let red = "\u{001B}[31m"
        static let green = "\u{001B}[32m"
        static let yellow = "\u{001B}[33m"
        static let cyan = "\u{001B}[36m"
        static let dim = "\u{001B}[2m"
        static let bold = "\u{001B}[1m"
    }

    // MARK: - CLIFormatter

    func formatMessage(_ message: ChatMessage, accountJID: BareJID? = nil) -> String {
        let timestamp = iso8601(message.timestamp)
        let direction = message.isOutgoing ? "->" : "<-"
        let color = message.isOutgoing ? Color.cyan : Color.green
        let displayJID = message.isOutgoing ? (accountJID?.description ?? message.fromJID) : message.fromJID
        let body = if message.isUndecryptable {
            "\(message.fromJID): \(Color.red)error: \(ChatMessage.undecryptableText)"
        } else if message.body.hasPrefix("/me ") {
            "* \(displayJID) \(message.body.dropFirst(4))"
        } else {
            // A received file has no text of its own, so the sender line names the file rather than reading as empty.
            "\(message.fromJID): \(styledBody(message.previewText))"
        }
        var line = "\(Color.dim)[\(timestamp)]\(Color.reset) \(color)\(direction) \(body)\(Color.reset)"
        if message.isEncrypted {
            line += " \(Color.green)\(Color.dim)[encrypted]\(Color.reset)"
        }
        if message.isEdited {
            line += " \(Color.dim)[edited]\(Color.reset)"
        }
        if message.isOutgoing, message.isDelivered {
            line += " \(Color.green)\u{2713}\(Color.reset)"
        }
        if let errorText = message.errorText {
            line += " \(Color.red)[error: \(errorText)]\(Color.reset)"
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
        "\(outcome.isComplete ? Color.green : Color.yellow)\(outcome.message)\(Color.reset)"
    }

    func formatAccount(_ account: Account) -> String {
        "\(Color.bold)\(account.jid)\(Color.reset) \(Color.dim)(\(account.id))\(Color.reset)"
    }

    func formatContactWithPresence(_ contact: Contact, presence: PresenceService.PresenceStatus?) -> String {
        let isOffline = presence == .offline || presence == nil
        let dot = isOffline ? "○" : "●"
        let color = switch presence {
        case .available:
            Color.green
        case .away, .xa:
            Color.yellow
        case .dnd:
            Color.red
        case .offline, .none:
            Color.dim
        }
        let displayName = contact.localAlias ?? contact.name ?? contact.jid.description
        return "\(color)\(dot)\(Color.reset) \(Color.bold)\(displayName)\(Color.reset) (\(contact.jid)) \(Color.dim)[\(contact.subscription.rawValue)]\(Color.reset)"
    }

    func formatGroupHeader(_ group: ContactGroup) -> String {
        "\(Color.bold)--- \(group.name) (\(group.contacts.count)) ---\(Color.reset)"
    }

    func formatPresence(jid: BareJID, status: String, message: String?) -> String {
        let color: String = switch status {
        case "available", "chat":
            Color.green
        case "dnd":
            Color.red
        default:
            Color.yellow
        }
        if let message {
            return "\(color)\(jid)\(Color.reset) is \(color)\(status)\(Color.reset): \(message)"
        }
        return "\(color)\(jid)\(Color.reset) is \(color)\(status)\(Color.reset)"
    }

    func formatError(_ error: any Error) -> String {
        "\(Color.red)error: \(error.localizedDescription)\(Color.reset)"
    }

    func formatEvent(_ event: XMPPEvent, accountID: UUID) -> String? {
        switch event {
        case let .connected(jid): "\(Color.green)connected as \(jid)\(Color.reset)"
        case let .streamResumed(jid): "\(Color.green)stream resumed as \(jid)\(Color.reset)"
        case let .disconnected(reason): formatDisconnect(reason)
        case let .authenticationFailed(message): "\(Color.red)authentication failed: \(message)\(Color.reset)"
        case let .messageReceived(message): formatIncomingMessage(message)
        case let .messageCarbonReceived(forwarded): formatCarbonEvent(forwarded, isOutgoing: false)
        case let .messageCarbonSent(forwarded): formatCarbonEvent(forwarded, isOutgoing: true)
        case let .presenceSubscriptionRequest(from: jid): "\(Color.yellow)⚡ Subscription request from \(jid) — use /approve or /deny\(Color.reset)"
        case let .presenceSubscriptionApproved(from: jid): "\(Color.green)✓ Subscription approved by \(jid)\(Color.reset)"
        case let .presenceSubscriptionRevoked(from: jid): "\(Color.yellow)✗ Subscription revoked by \(jid)\(Color.reset)"
        case let .deliveryReceiptReceived(messageID, from): "\(Color.dim)\u{2713} delivery receipt: \(messageID) from \(from.bareJID)\(Color.reset)"
        case let .messageCorrected(_, newBody, from): "\(Color.yellow)message corrected by \(from.bareJID): \(newBody)\(Color.reset)"
        case let .messageError(_, from, error): "\(Color.red)message error from \(from.bareJID): \(error.displayText)\(Color.reset)"
        case let .messageRetracted(originalID, from): "\(Color.dim)\u{2298} message retracted by \(from.bareJID) (id: \(originalID))\(Color.reset)"
        case let .messageModerated(originalID, moderator, room, reason): formatModeratedMessage(originalID: originalID, moderator: moderator, room: room, reason: reason)
        case let .roomJoined(room, occupancy, isNewlyCreated): formatRoomJoinedMUC(room: room, occupancy: occupancy, isNewlyCreated: isNewlyCreated)
        case let .roomOccupantJoined(room, occupant): "\(Color.yellow)\(room): \(occupant.nickname) joined\(Color.reset)"
        case let .roomOccupantLeft(room, occupant, reason): formatOccupantLeftMUC(room: room, occupant: occupant, reason: reason)
        case let .roomOccupantNickChanged(room, oldNickname, occupant): "\(Color.yellow)\(room): \(oldNickname) is now known as \(occupant.nickname)\(Color.reset)"
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
        case let .omemoDeviceListReceived(jid, devices): "\(Color.dim)OMEMO devices for \(jid): \(devices.map(String.init).joined(separator: ", "))\(Color.reset)"
        case let .omemoSessionEstablished(jid, deviceID, _): "\(Color.green)OMEMO session established with \(jid) device \(deviceID)\(Color.reset)"
        case let .omemoRecipientsPartial(conversation, dropped): "\(Color.yellow)⚠ OMEMO: skipped \(dropped.count) device(s) for \(conversation) — bundles missing\(Color.reset)"
        case .omemoEncryptedMessageReceived, .omemoSessionAdvanced: nil
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
        }
    }

    private func formatModeratedMessage(originalID: String, moderator: String, room: BareJID, reason: String?) -> String {
        let reasonStr = reason.map { ": \($0)" } ?? ""
        return "\(Color.dim)\u{2298} message moderated by \(moderator) in \(room) (id: \(originalID))\(reasonStr)\(Color.reset)"
    }

    private func formatRoomSubject(room: BareJID, subject: String?, setter: JID?) -> String {
        let who = setter?.bareJID.description ?? "someone"
        let topic = subject ?? "(cleared)"
        return "\(Color.yellow)\(room): topic changed by \(who): \(topic)\(Color.reset)"
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
        var line = "\(Color.yellow)Service outage"
        if let desc = info.description {
            line += ": \(desc)"
        }
        if let end = info.expectedEnd {
            line += " (expected end: \(end))"
        }
        if let alt = info.alternativeDomain {
            line += " [alternative: \(alt)]"
        }
        line += "\(Color.reset)"
        return line
    }

    // MARK: - Room Formatting

    func formatRoom(_ room: DiscoveredRoom) -> String {
        if let name = room.name {
            return "\(Color.bold)\(name)\(Color.reset) (\(room.jidString))"
        }
        return room.jidString
    }

    func formatBookmark(_ bookmark: RoomBookmark) -> String {
        var line = "\(Color.bold)\(bookmark.name ?? bookmark.jidString)\(Color.reset)"
        if bookmark.name != nil {
            line += " (\(bookmark.jidString))"
        }
        if bookmark.autojoin {
            line += " \(Color.green)[autojoin]\(Color.reset)"
        }
        if let nick = bookmark.nickname {
            line += " \(Color.dim)nick: \(nick)\(Color.reset)"
        }
        return line
    }

    func formatRoomParticipant(_ participant: RoomParticipant) -> String {
        var line = "  \(Color.green)\(participant.nickname)\(Color.reset)"
        if let jid = participant.jidString {
            line += " (\(jid))"
        }
        line += " \(Color.dim)[\(participant.role.rawValue)]\(Color.reset)"
        return line
    }

    func formatRoomParticipantGroupHeader(_ group: RoomParticipantGroup) -> String {
        "\(Color.bold)--- \(group.affiliation.displayName) (\(group.participants.count)) ---\(Color.reset)"
    }

    func formatRoomJoinedConfirmation(room: String, nickname: String, participantCount: Int, subject: String?) -> String {
        var line = "\(Color.green)Joined \(Color.bold)\(room)\(Color.reset)\(Color.green) as \(nickname) (\(participantCount) participants)\(Color.reset)"
        if let subject, !subject.isEmpty {
            line += "\n\(Color.dim)Topic: \(subject)\(Color.reset)"
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
        let color = isOutgoing ? Color.cyan : Color.green
        let formatted = if body.hasPrefix("/me ") {
            "* \(jid) \(body.dropFirst(4))"
        } else {
            "\(jid): \(styledBody(body))"
        }
        var line = "\(Color.dim)[\(timestamp)]\(Color.reset) \(color)\(direction) \(formatted) [carbon]\(Color.reset)"
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
            "\(from): \(styledBody(body))"
        }
        var line = "\(Color.dim)[\(timestamp)]\(Color.reset) \(Color.green)<- \(formatted)\(Color.reset)"
        for item in oob where item.url != body {
            line += "\n" + formatFileMessage(fileName: oobFileName(item.url), url: item.url, fileSize: nil)
        }
        return line
    }

    private func formatRoomJoinedMUC(room: BareJID, occupancy: RoomOccupancy, isNewlyCreated: Bool) -> String {
        var line = "\(Color.green)Joined \(Color.bold)\(room)\(Color.reset)\(Color.green) as \(occupancy.nickname) (\(occupancy.occupants.count) participants)\(Color.reset)"
        if isNewlyCreated {
            line += " \(Color.yellow)[new room]\(Color.reset)"
        }
        if occupancy.flags.contains(.nonAnonymous) {
            line += " \(Color.yellow)[non-anonymous]\(Color.reset)"
        }
        if occupancy.flags.contains(.logged) {
            line += " \(Color.yellow)[logged]\(Color.reset)"
        }
        if let subject = occupancy.subject, !subject.isEmpty {
            line += " \(Color.dim)— topic: \(subject)\(Color.reset)"
        }
        return line
    }

    private func formatOccupantLeftMUC(room: BareJID, occupant: RoomOccupant, reason: OccupantLeaveReason?) -> String {
        "\(Color.yellow)\(room): \(occupant.nickname) \(occupantLeaveText(reason))\(Color.reset)"
    }

    private func formatRoomInviteMUC(_ invite: RoomInvite) -> String {
        var line = "\(Color.yellow)Room invite: \(invite.from.bareJID) invites you to \(Color.bold)\(invite.room)\(Color.reset)"
        if let reason = invite.reason {
            line += "\(Color.yellow) (\(reason))\(Color.reset)"
        }
        return line
    }

    private func formatRoomDestroyedMUC(room: BareJID, reason: String?, alternate: BareJID?) -> String {
        var line = "\(Color.red)Room \(room) was destroyed\(Color.reset)"
        if let reason {
            line += " \(Color.dim)(\(reason))\(Color.reset)"
        }
        if let alternate {
            line += " \(Color.dim)→ \(alternate)\(Color.reset)"
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
            "\(from.bareJID)/\(nickname): \(styledBody(body))"
        }
        var line = "\(Color.dim)[\(timestamp)]\(Color.reset) \(Color.green)<- \(formatted)\(Color.reset)"
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
            "[PM] \(from.bareJID)/\(nickname): \(styledBody(body))"
        }
        var line = "\(Color.dim)[\(timestamp)]\(Color.reset) \(Color.cyan)<- \(formatted)\(Color.reset)"
        for item in oob where item.url != body {
            line += "\n" + formatFileMessage(fileName: oobFileName(item.url), url: item.url, fileSize: nil)
        }
        return line
    }

    private func styledBody(_ body: String) -> String {
        let blocks = MessageStylingParser.parse(body)
        return MessageStylingANSIRenderer.render(blocks)
    }

    private func formatDisconnect(_ reason: DisconnectReason) -> String {
        switch reason {
        case .requested:
            return "\(Color.yellow)disconnected\(Color.reset)"
        case let .streamError(condition, text):
            return "\(Color.red)disconnected: \(AccountService.streamErrorMessage(condition: condition, text: text))\(Color.reset)"
        case let .connectionLost(message):
            return "\(Color.red)disconnected: \(AccountService.connectionLostMessage(message))\(Color.reset)"
        case let .redirect(host, port):
            let target = port.map { "\(host):\($0)" } ?? host
            return "\(Color.yellow)redirected to \(target)\(Color.reset)"
        }
    }

    func formatTransferProgress(fileName: String, fileSize: Int64, progress: Double) -> String {
        "\r\(Color.cyan)\(fileName)\(Color.reset) (\(formatByteCount(fileSize))) \(progressBar(progress)) \(Int(progress * 100))%"
    }

    func formatFileMessage(fileName: String, url: String, fileSize: Int64?) -> String {
        var line = "\(Color.bold)\u{1F4CE} \(fileName)\(Color.reset)"
        if let fileSize {
            line += " (\(formatByteCount(fileSize)))"
        }
        line += "\n  \(Color.cyan)\(url)\(Color.reset)"
        return line
    }

    func formatFileOffer(fileName: String, fileSize: Int64, from: String, offerID: String) -> String {
        "\(Color.yellow)\u{1F4E5} [File offer] \(fileName) (\(formatByteCount(fileSize))) from \(from) (\(offerID)) \u{2014} /accept or /decline\(Color.reset)"
    }

    func formatJingleTransferProgress(fileName: String, fileSize: Int64, progress: Double, state: String) -> String {
        "\r\(Color.cyan)\(fileName)\(Color.reset) (\(formatByteCount(fileSize))) \(progressBar(progress)) \(state) \(Int(progress * 100))%"
    }

    func formatJingleTransferCompleted(sid: String, transport: JingleTransportKind) -> String {
        "\(Color.green)\u{2705} Transfer completed: \(sid) \u{2014} \(transportLabel(for: transport))\(Color.reset)"
    }

    func formatJingleTransferFailed(sid: String, reason: JingleTransferFailureReason) -> String {
        "\(Color.red)Transfer failed: \(sid) \u{2014} \(reason.displayText)\(Color.reset)"
    }

    private func transportLabel(for transport: JingleTransportKind) -> String {
        switch transport {
        case .socks5: "SOCKS5"
        case .ibb: "IBB"
        }
    }

    private func progressBar(_ progress: Double) -> String {
        let barWidth = 20
        let filled = Int(progress * Double(barWidth))
        let empty = barWidth - filled
        let bar = String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: empty)
        return "\(Color.green)\(bar)\(Color.reset)"
    }

    func formatTypingIndicator(from jid: BareJID, state: ChatState) -> String? {
        state == .composing ? "\(Color.dim)[\(jid) is typing...]\(Color.reset)" : nil
    }

    func formatTLSInfo(_ info: TLSInfo) -> String {
        var lines: [String] = []
        lines.append("\(Color.bold)TLS Version:\(Color.reset) \(info.protocolVersion)")
        lines.append("\(Color.bold)Cipher Suite:\(Color.reset) \(info.cipherSuite ?? "Not available")")
        if let subject = info.certificateSubject {
            lines.append("\(Color.bold)Subject:\(Color.reset) \(subject)")
        }
        if let issuer = info.certificateIssuer {
            lines.append("\(Color.bold)Issuer:\(Color.reset) \(issuer)")
        }
        if let expiry = info.certificateExpiry {
            lines.append("\(Color.bold)Expires:\(Color.reset) \(iso8601(expiry))")
        }
        if let fingerprint = info.certificateSHA256 {
            lines.append("\(Color.bold)SHA-256:\(Color.reset) \(fingerprint)")
        }
        return lines.joined(separator: "\n")
    }

    func formatServerInfo(_ info: ServerInfo) -> String {
        guard !info.contactAddresses.isEmpty else {
            return "\(Color.dim)(no server contact information)\(Color.reset)"
        }
        var lines: [String] = []
        let grouped = Dictionary(grouping: info.contactAddresses, by: \.type)
        for type in ContactAddressType.allCases {
            guard let addresses = grouped[type], !addresses.isEmpty else { continue }
            lines.append("\(Color.bold)\(type.displayName):\(Color.reset)")
            for address in addresses {
                lines.append("  \(Color.cyan)\(address.address)\(Color.reset)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func formatRegistrationForm(_ form: RegistrationFormInfo) -> String {
        var lines: [String] = []
        let kindLabel = form.formKind == .dataForm ? "Data Form" : "Legacy"
        lines.append("\(Color.bold)Registration Form (\(kindLabel))\(Color.reset)")
        let statusColor = form.isRegistered ? Color.green : Color.dim
        lines.append("\(Color.bold)Status:\(Color.reset) \(statusColor)\(form.isRegistered ? "Registered" : "Not registered")\(Color.reset)")
        if let instructions = form.instructions, !instructions.isEmpty {
            lines.append("\(Color.bold)Instructions:\(Color.reset) \(instructions)")
        }
        switch form.formKind {
        case .legacy:
            lines.append("\(Color.bold)Fields:\(Color.reset)")
            if form.hasUsername { lines.append("  \(Color.cyan)Username\(Color.reset): (required)") }
            if form.hasPassword { lines.append("  \(Color.cyan)Password\(Color.reset): (required)") }
            if form.hasEmail { lines.append("  \(Color.cyan)Email\(Color.reset): (optional)") }
        case .dataForm:
            lines.append("\(Color.bold)Fields:\(Color.reset)")
            for field in form.dataFormFields where field.isUserEditable {
                let label = field.displayLabel
                let value = field.values.joined(separator: ", ")
                lines.append("  \(Color.cyan)\(label)\(Color.reset): \(value.isEmpty ? "\(Color.dim)(empty)\(Color.reset)" : value)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func formatSearchedChannel(_ channel: SearchedChannel) -> String {
        var line = "\(Color.bold)\(channel.name ?? channel.jidString)\(Color.reset)"
        if channel.name != nil {
            line += " (\(channel.jidString))"
        }
        if let userCount = channel.userCount {
            line += " \(Color.dim)\(userCount) users\(Color.reset)"
        }
        if let isOpen = channel.isOpen {
            let badge = isOpen ? "\(Color.green)[open]\(Color.reset)" : "\(Color.red)[closed]\(Color.reset)"
            line += " \(badge)"
        }
        return line
    }

    func formatOMEMOFingerprint(_ fingerprint: String) -> String {
        "\(Color.bold)\(OMEMODeviceInfo.formatFingerprint(fingerprint))\(Color.reset)"
    }

    func formatOMEMODevice(_ device: OMEMODeviceInfo) -> String {
        let color = device.trustLevel.isTrustedForEncryption ? Color.green : Color.yellow
        return "  \(Color.bold)\(device.deviceID)\(Color.reset)  \(omemoFingerprintText(device))  \(color)[\(device.trustLevel.rawValue)]\(Color.reset)"
    }

    func formatOMEMOTrustChange(jid: String, deviceID: UInt32, trustLevel: OMEMOTrustLevel) -> String {
        let color = trustLevel.isTrustedForEncryption ? Color.green : Color.yellow
        return "\(color)\(omemoTrustChangeText(jid: jid, deviceID: deviceID, trustLevel: trustLevel))\(Color.reset)"
    }

    func formatProfile(_ profile: ProfileInfo) -> String {
        var lines: [String] = []
        appendProfileNameFields(profile, to: &lines)
        appendProfileDetailFields(profile, to: &lines)
        if lines.isEmpty {
            return "\(Color.dim)(no profile data)\(Color.reset)"
        }
        return lines.joined(separator: "\n")
    }

    private func appendProfileNameFields(_ profile: ProfileInfo, to lines: inout [String]) {
        if let fullName = profile.fullName {
            lines.append("\(Color.bold)Full Name:\(Color.reset) \(fullName)")
        }
        if let nickname = profile.nickname {
            lines.append("\(Color.bold)Nickname:\(Color.reset) \(nickname)")
        }
        if let givenName = profile.givenName {
            lines.append("\(Color.bold)Given Name:\(Color.reset) \(givenName)")
        }
        if let familyName = profile.familyName {
            lines.append("\(Color.bold)Family Name:\(Color.reset) \(familyName)")
        }
        if let organization = profile.organization {
            lines.append("\(Color.bold)Organization:\(Color.reset) \(organization)")
        }
        if let title = profile.title {
            lines.append("\(Color.bold)Title:\(Color.reset) \(title)")
        }
        if let role = profile.role {
            lines.append("\(Color.bold)Role:\(Color.reset) \(role)")
        }
    }

    private func appendProfileDetailFields(_ profile: ProfileInfo, to lines: inout [String]) {
        for email in profile.emails where !email.address.isEmpty {
            lines.append("\(Color.bold)Email:\(Color.reset) \(email.address)")
        }
        for tel in profile.telephones where !tel.number.isEmpty {
            lines.append("\(Color.bold)Phone:\(Color.reset) \(tel.number)")
        }
        if let url = profile.url {
            lines.append("\(Color.bold)URL:\(Color.reset) \(Color.cyan)\(url)\(Color.reset)")
        }
        if let birthday = profile.birthday {
            lines.append("\(Color.bold)Birthday:\(Color.reset) \(birthday)")
        }
        if let note = profile.note {
            lines.append("\(Color.bold)Note:\(Color.reset) \(note)")
        }
    }
}
