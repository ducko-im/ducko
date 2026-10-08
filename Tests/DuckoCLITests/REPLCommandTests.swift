import Testing
@testable import DuckoCLI

struct REPLCommandTests {
    @Test(arguments: ["quit", "exit", "  exit\t", "\thelp  "])
    func `control words retain whitespace and alias behavior`(input: String) {
        let expected: REPLCommand.Kind = input.contains("help") ? .help : .quit
        #expect(REPLCommand(input).kind == expected)
    }

    @Test(arguments: [
        "", "send", "/send a hi", "Send a hi", "/add", "/reply", "/remove", "/approve", "/deny", "/edit", "/retract", "/search", "/searchall", "/encrypt", "/pref", "/directed-presence",
        "/roster extra", "/who extra", "/profile extra", "/transfers extra", "/connection-info extra", "/unregister-account extra", "help extra", "quit extra", "exit extra",
        "/joiner room", "/join\troom", "send\ta hi", "/pm\nAlice hi", "/unknown"
    ])
    func `unrecognized forms stay unknown`(input: String) {
        #expect(REPLCommand(input).kind == nil)
    }

    @Test(arguments: [
        ("send alice@example.com hello", REPLCommand.Kind.send),
        ("/add alice@example.com", .add), ("/remove alice@example.com", .remove),
        ("/reply alice@example.com hi", .reply), ("/retract alice@example.com", .retract),
        ("/edit alice@example.com revised", .edit), ("/search alice@example.com query", .search), ("/searchall two words", .searchAll),
        ("/approve alice@example.com", .approve), ("/deny alice@example.com", .deny),
        ("/directed-presence alice@example.com", .directedPresence),
        ("/encrypt alice@example.com on", .encrypt), ("/pref chatstates off", .pref)
    ])
    func `argument requiring commands retain their grammar`(input: String, expected: REPLCommand.Kind) {
        #expect(REPLCommand(input).kind == expected)
    }

    @Test(arguments: [
        REPLCommand.Kind.status, .history, .checkRegistration, .submitRegistration, .join, .leave, .members, .topic,
        .nick, .destroy, .voice, .kick, .pm, .affiliations, .config, .moderate, .sendfile, .senddirect, .accept, .decline,
        .rooms, .avatar
    ])
    func `optional arguments and operation usage errors remain recognized`(kind: REPLCommand.Kind) {
        #expect(REPLCommand(kind.rawValue).kind == kind)
        #expect(REPLCommand(kind.rawValue + " arbitrary argument").kind == kind)
    }

    @Test
    func `quoted arguments remain intact for the nickname parser`() throws {
        let input = #"/pm   "Alice \"Ace\" Smith" hello  there"#
        let command = REPLCommand(input)
        #expect(command.kind == .pm)
        #expect(command.input == input)
        #expect(command.arguments == #"  "Alice \"Ace\" Smith" hello  there"#)
        let parsed = try parseNicknameArgument(command.arguments)
        #expect(parsed.nickname == #"Alice "Ace" Smith"#)
        #expect(parsed.trailingArgument == "hello  there")
    }

    @Test(arguments: [#"/pm "Alice"trailing hi"#, #"/pm "unterminated"#, #"/kick "bad\escape""#])
    func `argument errors are still the specialized parser's responsibility`(input: String) {
        let command = REPLCommand(input)
        #expect(command.kind != nil)
        #expect(throws: CLIError.self) { _ = try parseNicknameArgument(command.arguments) }
    }

    @Test
    func `help preserves text and order and documents every command`() {
        #expect(REPLCommand.help == expectedREPLHelp)
        for kind in REPLCommand.Kind.allCases {
            #expect(kind.helpLines.allSatisfy { $0.hasPrefix("  " + kind.rawValue + " ") })
        }
    }

    @Test(arguments: [String?.none, "first@rooms.example.com"])
    func `room changes distinguish retaining clearing and selecting`(current: String?) {
        #expect(RoomSelectionChange.unchanged.applying(to: current) == current)
        #expect(RoomSelectionChange.clear.applying(to: current) == nil)
        #expect(RoomSelectionChange.select("second@rooms.example.com").applying(to: current) == "second@rooms.example.com")
    }
}

private let expectedREPLHelp = """
Commands:
  send <jid> <message>     Send a message
  /roster                  Show contacts with presence
  /status [status] [msg]   Get or set presence
  /who                     Show online contacts
  /add <jid> [name]        Add contact to roster
  /remove <jid>            Remove contact from roster
  /history <jid> [limit]   Show message history
  /profile                 View own vCard profile
  /reply <jid> <message>   Reply to last incoming message
  /retract <jid>           Retract last sent message
  /edit <jid> <new-body>   Edit last sent message
  /search <jid> <query>    Search message history
  /searchall <query>       Search all conversations
  /approve <jid>           Approve subscription request
  /deny <jid>              Deny subscription request
  /directed-presence <jid> Send directed presence to a JID
  /unregister-account      Unregister account from server
  /check-registration [jid]  Show server registration form
  /submit-registration [jid] Submit registration to server/component
  /join <room> [nick]      Join a MUC room
  /leave [room]            Leave a MUC room
  /members [room]          Show room occupants
  /topic [room] [text]     View or set room topic
  /nick <nickname>         Change nickname in current room
  /destroy [reason]        Destroy current room
  /voice grant|revoke <n>  Grant/revoke voice
  /kick <nick> [reason]    Kick occupant; quote names w/ spaces
  /pm <nick> <message>     PM an occupant; quote names w/ spaces
  /affiliations [type]     List affiliations
  /config [submit-default] Show room config or accept defaults
  /moderate [reason]       Moderate last message in room
  /sendfile [jid] <path>   Send a file
  /senddirect <jid> <path> Send a file directly to the contact's device
  /accept [id]             Accept incoming file transfer into Downloads
  /decline [id]            Decline incoming file transfer
  /transfers               List active transfers
  /rooms [service]         Discover available rooms
  /avatar [jid]            View avatar info (own or contact's)
  /connection-info         Show TLS connection info
  /encrypt <jid> on|off    Toggle OMEMO encryption for a conversation
  /pref chatstates on|off  Toggle chat state notifications
  /pref markers on|off      Toggle displayed markers (read receipts)
  help                     Show this help
  quit                     Disconnect and exit
"""
