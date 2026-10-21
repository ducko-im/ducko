import Foundation

enum CLIError: Error, LocalizedError {
    case noAccounts
    case accountNotFound(String)
    case noPassword
    case noHiddenInput(field: String)
    case hiddenInputTooLong(maxBytes: Int)
    case invalidJID(String)
    case connectionFailed(String)
    case connectionTimeout
    case invalidPresenceStatus(String)
    case invalidDuration(String)
    case durationTooLong(String)
    case invalidDate(String)
    case noMUCService
    case noRoomSpecified
    case fileNotFound(String)
    case noConversationTarget
    /// An address that names none of the account's conversations.
    case noConversation(String)
    case invalidTransferMethod(String)
    case noIncomingOffers
    case malformedQuotedArgument(String)
    case omemoDeviceNotFound(deviceID: UInt32, jid: String)
    case unlistedOption(String)
    case notYesOrNo(String)
    case registrationRedirected
    case inputEnded(field: String)

    var errorDescription: String? {
        switch self {
        case .noAccounts:
            "No accounts configured. Run 'ducko account add <jid>' to add one."
        case let .accountNotFound(id):
            "Account not found: \(id)"
        case .noPassword:
            "No password provided. Run in a terminal to enter interactively."
        case let .noHiddenInput(field):
            "No \(field) provided. Run in a terminal to enter it interactively."
        case let .hiddenInputTooLong(maxBytes):
            "Hidden input can be at most \(maxBytes) bytes long."
        case let .invalidJID(jid):
            "Invalid JID: \(jid)"
        case let .connectionFailed(message):
            message
        case .connectionTimeout:
            "Connection timed out after 30 seconds"
        case let .invalidPresenceStatus(status):
            "Invalid presence status: \(status). Valid values: available, away, xa, dnd, offline"
        case let .invalidDuration(token):
            "Invalid duration: \(token). Use a positive whole number with a unit s, m, or h (e.g. 30s, 15m, 2h)."
        case let .durationTooLong(token):
            "Duration too long: \(token). The maximum is 24h; use --keep-alive to hold indefinitely."
        case let .invalidDate(string):
            "Invalid ISO 8601 date: \(string)"
        case .noMUCService:
            "No MUC service found on this server."
        case .noRoomSpecified:
            "No room specified. Join a room with /join or provide a room JID."
        case let .fileNotFound(path):
            "File not found: \(path)"
        case .noConversationTarget:
            "No conversation target. Use: /sendfile [jid] <path>"
        case let .noConversation(address):
            "No conversation with \(address)"
        case let .invalidTransferMethod(method):
            "Invalid transfer method: \(method). Valid values: auto, http, jingle"
        case .noIncomingOffers:
            "No incoming file transfer offers."
        case let .malformedQuotedArgument(detail):
            "Invalid nickname argument: \(detail). Quote nicknames containing spaces, e.g. \"Alice Smith\"."
        case let .omemoDeviceNotFound(deviceID, jid):
            "Device \(deviceID) not found for \(jid)."
        case let .unlistedOption(value):
            "\(value) is not one of the listed options."
        case let .notYesOrNo(value):
            "\(value) is not yes or no."
        case .registrationRedirected:
            "The server registers accounts only on the web page shown above."
        case let .inputEnded(field):
            "Input ended before \(field) had a value."
        }
    }
}
