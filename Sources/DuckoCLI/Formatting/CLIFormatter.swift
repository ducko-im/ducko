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
    func formatTypingIndicator(from jid: BareJID, state: ChatState) -> String?
    func formatRoom(_ room: DiscoveredRoom) -> String
    func formatRoomParticipant(_ participant: RoomParticipant) -> String
    func formatRoomParticipantGroupHeader(_ group: RoomParticipantGroup) -> String
    func formatRoomJoinedConfirmation(room: String, nickname: String, participantCount: Int, subject: String?) -> String
    func formatTransferProgress(fileName: String, fileSize: Int64, progress: Double) -> String
    func formatFileMessage(fileName: String, url: String, fileSize: Int64?) -> String
    func formatBookmark(_ bookmark: RoomBookmark) -> String
    func formatProfile(_ profile: ProfileInfo) -> String
    func formatTLSInfo(_ info: TLSInfo) -> String
    func formatServerInfo(_ info: ServerInfo) -> String
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
        case .rooms: "No rooms found."
        case .roomParticipants: "No participants in room."
        case .channels: "No channels found."
        case .messages: "No messages found."
        case .omemoIdentity: "No OMEMO identity found."
        case let .omemoDevices(jid, _): "No known OMEMO devices for \(jid)."
        }
    }
}

func jingleProgressState(bytesTransferred: Int64, totalBytes: Int64) -> (progress: Double, state: String) {
    let progress = Double(bytesTransferred) / Double(totalBytes)
    let state = progress < 1.0 ? "transferring" : "finishing"
    return (progress, state)
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
