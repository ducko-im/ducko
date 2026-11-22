import ArgumentParser
import Darwin

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

    /// ArgumentParser's own entry point, plus the process-wide stdout policy and the JSON `error` record of a command
    /// that fails once it runs. Parsing, help and version output stay ArgumentParser's.
    static func main() async {
        // Ignore SIGPIPE so a `write()` to a closed pipe, such as stdout piped into a reader that exits early, returns
        // `EPIPE` instead of silently killing the process with signal 13. Sockets already suppress SIGPIPE (NIO's
        // channels and DuckoXMPP's raw sockets), so this covers stdout and every other descriptor.
        signal(SIGPIPE, SIG_IGN)
        // Piped stdout is block-buffered, so a reader would see output only when the buffer fills or the process exits.
        // Line buffering hands over each line as it is printed, including lines printed from background tasks.
        setvbuf(stdout, nil, _IOLBF, 0)

        var command: any ParsableCommand
        do {
            command = try await asyncParseAsRoot()
        } catch {
            exit(withError: error)
        }
        do {
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            if let record = commandFailureRecord(for: error, command: command) {
                print(record)
            }
            exit(withError: error)
        }
    }
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
