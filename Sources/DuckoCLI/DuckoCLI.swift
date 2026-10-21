import ArgumentParser

@main
struct DuckoCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ducko",
        abstract: "Ducko XMPP client",
        version: "0.1.0",
        subcommands: [
            Send.self,
            Roster.self,
            Presence.self,
            Profile.self,
            History.self,
            Room.self,
            Bookmarks.self,
            Blocklist.self,
            Avatar.self,
            Account.self,
            ServerInfoCommand.self,
            OMEMO.self,
            Logs.self,
            Import.self,
            Interactive.self
        ],
        defaultSubcommand: Interactive.self
    )
}

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Output format: plain, ansi, json")
    var output: OutputFormat?

    var resolvedFormat: OutputFormat {
        output ?? .defaultForTerminal
    }

    var formatter: any CLIFormatter {
        resolvedFormat.makeFormatter()
    }
}

struct AccountOption: ParsableArguments {
    @Option(name: .long, help: "Account UUID (uses first account if omitted)")
    var account: String?
}
