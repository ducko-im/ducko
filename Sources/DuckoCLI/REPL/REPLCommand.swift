import Foundation

/// Recognizes the command keyword without interpreting its command-specific arguments.
struct REPLCommand {
    enum Kind: String, CaseIterable {
        case send
        case roster = "/roster"
        case status = "/status"
        case who = "/who"
        case add = "/add"
        case remove = "/remove"
        case history = "/history"
        case profile = "/profile"
        case reply = "/reply"
        case retract = "/retract"
        case edit = "/edit"
        case search = "/search"
        case searchAll = "/searchall"
        case approve = "/approve"
        case deny = "/deny"
        case directedPresence = "/directed-presence"
        case unregisterAccount = "/unregister-account"
        case checkRegistration = "/check-registration"
        case submitRegistration = "/submit-registration"
        case join = "/join"
        case leave = "/leave"
        case members = "/members"
        case topic = "/topic"
        case nick = "/nick"
        case destroy = "/destroy"
        case voice = "/voice"
        case kick = "/kick"
        case pm = "/pm"
        case affiliations = "/affiliations"
        case config = "/config"
        case moderate = "/moderate"
        case sendfile = "/sendfile"
        case senddirect = "/senddirect"
        case accept = "/accept"
        case decline = "/decline"
        case transfers = "/transfers"
        case rooms = "/rooms"
        case avatar = "/avatar"
        case connectionInfo = "/connection-info"
        case encrypt = "/encrypt"
        case pref = "/pref"
        case help
        case quit

        var helpLines: [String] {
            switch self {
            case .send: ["  send <jid> <message>     Send a message"]
            case .roster: ["  /roster                  Show contacts with presence"]
            case .status: ["  /status [status] [msg]   Get or set presence"]
            case .who: ["  /who                     Show online contacts"]
            case .add: ["  /add <jid> [name]        Add contact to roster"]
            case .remove: ["  /remove <jid>            Remove contact from roster"]
            case .history: ["  /history <jid> [limit]   Show message history"]
            case .profile: ["  /profile                 View own vCard profile"]
            case .reply: ["  /reply <jid> <message>   Reply to last incoming message"]
            case .retract: ["  /retract <jid>           Retract last sent message"]
            case .edit: ["  /edit <jid> <new-body>   Edit last sent message"]
            case .search: ["  /search <jid> <query>    Search message history"]
            case .searchAll: ["  /searchall <query>       Search all conversations"]
            case .approve: ["  /approve <jid>           Approve subscription request"]
            case .deny: ["  /deny <jid>              Deny subscription request"]
            case .directedPresence: ["  /directed-presence <jid> Send directed presence to a JID"]
            case .unregisterAccount: ["  /unregister-account      Unregister account from server"]
            case .checkRegistration: ["  /check-registration [jid]  Show server registration form"]
            case .submitRegistration: ["  /submit-registration [jid] Submit registration to server/component"]
            case .join: ["  /join <room> [nick]      Join a MUC room"]
            case .leave: ["  /leave [room]            Leave a MUC room"]
            case .members: ["  /members [room]          Show room occupants"]
            case .topic: ["  /topic [room] [text]     View or set room topic"]
            case .nick: ["  /nick <nickname>         Change nickname in current room"]
            case .destroy: ["  /destroy [reason]        Destroy current room"]
            case .voice: ["  /voice grant|revoke <n>  Grant/revoke voice"]
            case .kick: ["  /kick <nick> [reason]    Kick occupant; quote names w/ spaces"]
            case .pm: ["  /pm <nick> <message>     PM an occupant; quote names w/ spaces"]
            case .affiliations: ["  /affiliations [type]     List affiliations"]
            case .config: ["  /config [submit-default] Show room config or accept defaults"]
            case .moderate: ["  /moderate [reason]       Moderate last message in room"]
            case .sendfile: ["  /sendfile [jid] <path>   Send a file"]
            case .senddirect: ["  /senddirect <jid> <path> Send a file directly to the contact's device"]
            case .accept: ["  /accept [id]             Accept incoming file transfer into Downloads"]
            case .decline: ["  /decline [id]            Decline incoming file transfer"]
            case .transfers: ["  /transfers               List active transfers"]
            case .rooms: ["  /rooms [service]         Discover available rooms"]
            case .avatar: ["  /avatar [jid]            View avatar info (own or contact's)"]
            case .connectionInfo: ["  /connection-info         Show TLS connection info"]
            case .encrypt: ["  /encrypt <jid> on|off    Toggle OMEMO encryption for a conversation"]
            case .pref: ["  /pref chatstates on|off  Toggle chat state notifications", "  /pref markers on|off      Toggle displayed markers (read receipts)"]
            case .help: ["  help                     Show this help"]
            case .quit: ["  quit                     Disconnect and exit"]
            }
        }

        fileprivate func accepts(hasArguments: Bool) -> Bool {
            switch self {
            case .send, .add, .remove, .reply, .retract, .edit, .search, .searchAll, .approve, .deny, .directedPresence, .encrypt, .pref: hasArguments
            case .roster, .who, .profile, .unregisterAccount, .transfers, .connectionInfo, .help, .quit: !hasArguments
            case .status, .history, .checkRegistration, .submitRegistration, .join, .leave, .members, .topic, .nick, .destroy, .voice, .kick, .pm, .affiliations, .config, .moderate, .sendfile, .senddirect, .accept, .decline, .rooms, .avatar: true
            }
        }
    }

    let kind: Kind?
    let input: String
    /// Text after the first literal space, including any remaining whitespace and quotes.
    let arguments: String

    init(_ line: String) {
        let input = line.trimmingCharacters(in: .whitespaces)
        self.input = input
        let separator = input.firstIndex(of: " ")
        let keyword = separator.map { String(input[..<$0]) } ?? input
        self.arguments = separator.map { String(input[input.index(after: $0)...]) } ?? ""
        let candidate = keyword == "exit" ? Kind.quit : Kind(rawValue: keyword)
        self.kind = candidate.flatMap { $0.accepts(hasArguments: separator != nil) ? $0 : nil }
    }

    static var help: String {
        (["Commands:"] + Kind.allCases.flatMap(\.helpLines)).joined(separator: "\n")
    }
}

enum RoomSelectionChange: Equatable {
    case unchanged
    case clear
    case select(String)

    func applying(to currentRoom: String?) -> String? {
        switch self {
        case .unchanged: currentRoom
        case .clear: nil
        case let .select(room): room
        }
    }
}
