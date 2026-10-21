import DuckoCore
import DuckoXMPP
import Foundation

protocol CLIFormatter: Sendable {
    func formatMessage(_ message: ChatMessage, accountJID: BareJID?) -> String
    func formatNote(_ note: TimelineNote, contactName: String) -> String
    /// The line that introduces one day of one conversation in the results of a search over all conversations.
    func formatSearchDay(jid: JID, day: Date, matchCount: Int) -> String
    func formatEmptyResult(_ result: CLIEmptyResult) -> String
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
    func formatTypingIndicator(from jid: BareJID, state: ChatState) -> String?
    func formatRoom(_ room: DiscoveredRoom) -> String
    func formatRoomParticipant(_ participant: RoomParticipant) -> String
    func formatRoomParticipantGroupHeader(_ group: RoomParticipantGroup) -> String
    func formatTransferProgress(fileName: String, fileSize: Int64, progress: Double) -> String
    func formatFileMessage(fileName: String, url: String, fileSize: Int64?) -> String
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
        }
    }
}

/// What the human-readable formatters print when a sign-in is refused because the server offered only PLAIN.
let plainSignInRefusedLine =
    "\(XMPPClientError.plainSignInRefused.localizedDescription). Run 'ducko account reset-security <jid>' to send the password anyway."

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

func formatByteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func nicknameFromJID(_ jid: JID) -> String {
    FullJID.parse(jid.description)?.resourcePart ?? jid.bareJID.description
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
