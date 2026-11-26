import DuckoCore
import DuckoXMPP
import Foundation

protocol CLIFormatter: Sendable {
    func formatMessage(_ message: ChatMessage, accountJID: BareJID?) -> String
    func formatNote(_ note: TimelineNote, contactName: String) -> String
    /// The line that introduces one day of one conversation in the results of a search over all conversations.
    func formatSearchDay(jid: JID, day: Date, matchCount: Int) -> String
    func formatEmptyResult(_ result: CLIEmptyResult) -> String
    func formatCommandResult(_ result: CLICommandResult) -> String
    /// A REPL line saying a command was typed wrong: its usage, or that the command or preference is unknown. JSON
    /// prints it as an `error` record.
    func formatUsageError(_ line: String) -> String
    func formatHelp(_ text: String) -> String
    func formatRosterCommand(_ outcome: RosterCommandOutcome) -> String
    func formatAccount(_ account: Account) -> String
    func formatPresence(jid: BareJID, status: String, message: String?) -> String
    func formatContactWithPresence(_ contact: Contact, presence: PresenceService.PresenceStatus?) -> String
    func formatGroupHeader(_ group: ContactGroup) -> String
    func formatError(_ error: any Error) -> String
    func formatEvent(_ event: XMPPEvent, accountID: UUID) -> String?
    /// An encrypted message as it was stored on arrival in `conversation`, printed the way `history` prints a stored
    /// message, except that a `/me` line the user sent from another device names the row's sender address rather than
    /// the account's. A room's message names its sender as a room line does, `room/nick`, after `[PM]` in a private chat.
    func formatEncryptedMessage(_ message: ChatMessage, in conversation: Conversation, accountID: UUID) -> String
    /// `jid` is `room/nick` for an occupant typing in a room, and a bare address otherwise.
    func formatTypingIndicator(from jid: JID, state: ChatState) -> String?
    func formatRoom(_ room: DiscoveredRoom) -> String
    func formatRoomParticipant(_ participant: RoomParticipant) -> String
    func formatRoomParticipantGroupHeader(_ group: RoomParticipantGroup) -> String
    func formatAffiliationGroupHeader(_ affiliation: RoomAffiliation, count: Int) -> String
    func formatAffiliation(_ item: RoomAffiliationItem) -> String
    func formatTransferProgress(fileName: String, fileSize: Int64, progress: Double) -> String
    func formatFileMessage(fileName: String, url: String, fileSize: Int64?) -> String
    func formatTransfer(_ transfer: FileTransferService.ActiveTransfer) -> String
    func formatBookmark(_ bookmark: RoomBookmark) -> String
    func formatBlockListEntry(_ entry: BlockListEntry) -> String
    func formatProfile(_ profile: ProfileInfo) -> String
    func formatTLSInfo(_ info: TLSInfo) -> String
    func formatServerInfo(_ info: ServerInfo) -> String
    func formatDataForm(_ form: DataFormInfo) -> String
    func formatRegistrationForm(_ form: RegistrationFormInfo) -> String
    func formatSearchedChannel(_ channel: SearchedChannel) -> String
    func formatOMEMOFingerprint(_ fingerprint: String) -> String
    func formatOMEMODevice(_ device: OMEMODeviceInfo) -> String
    func formatOMEMOTrustChange(jid: String, deviceID: UInt32, trustLevel: OMEMOTrustLevel) -> String
    func formatOMEMOSessionReset(_ report: OMEMOSessionResetReport) -> String
}

enum CLIEmptyResult {
    case accounts
    case roster(accountID: UUID)
    case bookmarks(accountID: UUID)
    case blockList(accountID: UUID)
    case rooms
    case roomParticipants(room: String)
    case channels
    case messages
    case omemoIdentity(accountID: UUID)
    case omemoDevices(jid: String, accountID: UUID)
    case onlineContacts
    case transfers
    case affiliations(RoomAffiliation, room: String)
    case roomConfig(room: String)
    case connectionInfo
    case ownAvatar
    case avatar(jid: String)
    case recentMessage(RecentMessagePurpose)
    case moderatableMessage

    /// The command that looked for the message, which JSON reports as `purpose`.
    enum RecentMessagePurpose: String {
        case retract, edit, reply
    }

    var message: String {
        switch self {
        case .accounts: "No accounts configured."
        case .roster: "No contacts in roster."
        case .bookmarks: "No bookmarks."
        case .blockList: "No blocked addresses."
        case .rooms: "No rooms found."
        case .roomParticipants: "No participants in room."
        case .channels: "No channels found."
        case .messages: "No messages found."
        case .omemoIdentity: "No OMEMO identity found."
        case let .omemoDevices(jid, _): "No known OMEMO devices for \(jid)."
        case .onlineContacts: "No contacts online."
        case .transfers: "No active transfers."
        case let .affiliations(affiliation, _): "No \(affiliation.displayName.lowercased())s."
        case .roomConfig: "No configuration fields."
        case .connectionInfo: "No TLS connection info available."
        case .ownAvatar: "No avatar set."
        case let .avatar(jid): "No avatar found for \(jid)."
        case .recentMessage(.retract): "No recent outgoing message to retract."
        case .recentMessage(.edit): "No recent outgoing message to edit."
        case .recentMessage(.reply): "No recent incoming message to reply to."
        case .moderatableMessage: "No moderatable message found."
        }
    }
}

/// What the human-readable formatters print when a sign-in is refused because the server offered only PLAIN. A command
/// whose own connect is refused follows it with a hint on standard error.
let plainSignInRefusedLine = XMPPClientError.plainSignInRefusedDescription

/// An account's sign-in settings as the human-readable formatters list them.
func accountSecurityText(_ account: Account) -> String {
    let tls = "TLS: \(account.requireTLS ? "required" : "optional")"
    switch account.signInMethod {
    case .password:
        return "Sign-in: password, PLAIN: \(account.allowsPLAIN ? "allowed" : "refused"), \(tls)"
    case .browser:
        return "Sign-in: browser, \(tls)"
    }
}

/// `message` with its sender written as a room line names them: `room/nick` in a room, after `[PM]` in a room's private
/// chat. A 1:1 message stays as it is.
func namingRoomSender(of message: ChatMessage, in conversation: Conversation) -> ChatMessage {
    var named = message
    if conversation.type == .groupchat {
        named.fromJID = "\(conversation.jid)/\(message.fromJID)"
    } else if let nickname = conversation.occupantNickname {
        named.fromJID = "[PM] \(conversation.jid)/\(nickname)"
    }
    return named
}

func jingleProgressState(bytesTransferred: Int64, totalBytes: Int64) -> (progress: Double, state: String) {
    let progress = Double(bytesTransferred) / Double(totalBytes)
    let state = progress < 1.0 ? "transferring" : "finishing"
    return (progress, state)
}

/// A direct transfer's rate and time left as the human-readable formatters append them to its progress, or nothing
/// while the rate is not known.
func transferRateSuffix(_ rate: TransferRate?) -> String {
    rate.map { " · \($0.displayText)" } ?? ""
}

/// The line the human-readable formatters print for a setup attempt's outcome.
func omemoSetupLine(_ status: OMEMOSetupStatus) -> String {
    switch status {
    case .complete: "OMEMO: this device's encryption setup is complete"
    case .incomplete: "OMEMO: this device's encryption setup is incomplete; encrypted replies may not reach it"
    case let .refused(condition): "OMEMO: the server refused this device's encryption keys: \(condition.displayText)"
    }
}

/// A data form field's values as one line of text, with a text-private value hidden.
func dataFormValueText(_ field: RoomConfigField) -> String {
    hidesDataFormValue(field) ? obscuredDataFormValue : field.values.joined(separator: ", ")
}

/// Whether output shows `obscuredDataFormValue` in place of the field's value: a text-private field that has one.
func hidesDataFormValue(_ field: RoomConfigField) -> Bool {
    field.type == "text-private" && field.values.contains { !$0.isEmpty }
}

/// Shown in place of a text-private field's value or a legacy registration password.
let obscuredDataFormValue = "********"

/// The label of a CAPTCHA challenge's field: its question or instruction, else its type.
func captchaChallengeLabel(_ challenge: CaptchaChallenge, in form: RegistrationFormInfo) -> String {
    form.dataForm.fields.first { $0.id == challenge.fieldID }?.displayLabel ?? challenge.variable
}

/// What output says about a CAPTCHA challenge beyond its field: where its image is, and whether Ducko can play it.
func captchaChallengeNotes(_ challenge: CaptchaChallenge) -> [String] {
    var notes: [String] = []
    switch challenge.image {
    case .inline: notes.append("image sent with the form")
    case let .link(url): notes.append("image at \(url.absoluteString)")
    case .unavailable: notes.append("Ducko couldn't display the image")
    case nil: break
    }
    if !challenge.isPlayable { notes.append("Ducko can't play this challenge, use the web page") }
    return notes
}

/// Shown when Ducko can't answer the server's CAPTCHA.
let captchaUnanswerableNote = "Ducko can't answer this server's challenge."

/// A legacy registration field's value as output shows it, with the password obscured.
func registrationFieldValueText(_ field: RegistrationField) -> String {
    field.isSecret && !field.value.isEmpty ? obscuredDataFormValue : field.value
}

func omemoFingerprintText(_ device: OMEMODeviceInfo) -> String {
    device.fingerprint.isEmpty ? "(no fingerprint)" : OMEMODeviceInfo.formatFingerprint(device.fingerprint)
}

func omemoTrustChangeText(jid: String, deviceID: UInt32, trustLevel: OMEMOTrustLevel) -> String {
    "\(trustLevel.rawValue.capitalized) device \(deviceID) for \(jid)."
}

/// The line above the devices of a session reset, which says so when there were none.
func omemoSessionResetHeading(_ report: OMEMOSessionResetReport) -> String {
    report.devices.isEmpty ? "No OMEMO devices to reset for \(report.peerJID)." : "Reset the OMEMO sessions with \(report.peerJID):"
}

/// A transfer as `/transfers` lists it in the human-readable formats.
func transferLineText(_ transfer: FileTransferService.ActiveTransfer) -> String {
    let sidSuffix = if let sid = transfer.sid, transfer.method == .jingle { " (sid: \(sid))" } else { "" }
    return "  \(transfer.fileName) (\(formatByteCount(transfer.fileSize))) [\(transferDirectionName(transfer))/\(transferMethodName(transfer))] "
        + formatTransferState(transfer) + sidSuffix
}

/// A transfer's direction as every format names it.
func transferDirectionName(_ transfer: FileTransferService.ActiveTransfer) -> String {
    transfer.direction == .outgoing ? "outgoing" : "incoming"
}

/// A transfer's method as every format names it.
func transferMethodName(_ transfer: FileTransferService.ActiveTransfer) -> String {
    switch transfer.method {
    case .httpUpload: "http"
    case .jingle: "jingle"
    }
}

/// The line above a room's affiliation list in the human-readable formats.
func affiliationGroupHeaderText(_ affiliation: RoomAffiliation, count: Int) -> String {
    "--- \(affiliation.displayName)s (\(count)) ---"
}

/// One entry of a room's affiliation list in the human-readable formats.
func affiliationText(_ item: RoomAffiliationItem) -> String {
    "  \(item.jidString)" + (item.nickname.map { " (\($0))" } ?? "")
}

func formatByteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func nicknameFromJID(_ jid: JID) -> String {
    occupantNickname(jid) ?? jid.bareJID.description
}

/// The nickname a room occupant's address carries, or nil for the room's own address.
func occupantNickname(_ jid: JID?) -> String? {
    guard case let .full(occupant) = jid else { return nil }
    return occupant.resourcePart
}

/// A room subject change as text, or nil for an empty subject from the room's own address. A room without a subject
/// sends such an empty one to each occupant who joins (XEP-0045).
func roomSubjectText(room: BareJID, subject: String?, setter: JID?) -> String? {
    switch (subject, occupantNickname(setter)) {
    case (nil, nil): nil
    case let (nil, nickname?): "\(room): topic cleared by \(nickname)"
    case let (subject?, nickname?): "\(room): topic changed by \(nickname): \(subject)"
    case let (subject?, nil): "\(room): topic: \(subject)"
    }
}

/// A search result day as text. The day is given as its UTC date, the span one transcript file covers.
func searchDayText(jid: JID, day: Date, matchCount: Int) -> String {
    "--- \(jid), \(iso8601Day(day)) (\(matchCount == 1 ? "1 match" : "\(matchCount) matches")) ---"
}

func iso8601Day(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle().year().month().day())
}

func iso8601(_ date: Date) -> String {
    date.formatted(
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    )
}

/// When a live message was sent, as `ChatService` stores it. The account's JID is taken from the message's addressee,
/// the account it came in on.
func sentTime(of message: XMPPMessage) -> Date {
    DelayStamp(in: message, accountJID: message.to?.bareJID)?.sentTime ?? Date()
}

/// Whether a carbon's message prints from its event. A retraction's body (XEP-0424) is only the fallback for clients
/// that cannot retract, so it never prints. An encrypted message's body and links are outside its encryption, so it
/// prints once stored, through `formatEncryptedMessage`.
func printsFromEvent(carbon message: XMPPMessage) -> Bool {
    !message.isEncrypted && message.element.child(named: "retract", namespace: XMPPNamespaces.messageRetract) == nil
}

/// The attachments a message's sender line has not already named, each printed on a line of its own. An attachment
/// whose URL is the body is named by the body, and the first attachment of an empty body by `previewText`.
func attachmentsBelowSenderLine(_ message: ChatMessage) -> [Attachment] {
    message.attachments.enumerated()
        .filter { index, attachment in attachment.url != message.body && !(message.body.isEmpty && index == 0) }
        .map(\.element)
}

func oobFileName(_ url: String) -> String {
    Attachment.fileName(forLink: url)
}

func occupantLeaveText(_ reason: OccupantLeaveReason?) -> String {
    switch reason {
    case let .kicked(r):
        "was kicked" + (r.map { ": \($0)" } ?? "")
    case let .banned(r):
        "was banned" + (r.map { ": \($0)" } ?? "")
    case let .affiliationChanged(r):
        "was removed (affiliation change)" + (r.map { ": \($0)" } ?? "")
    case .serviceShutdown:
        "was removed (service shutdown)"
    case nil:
        "left"
    }
}
