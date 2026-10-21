import ArgumentParser
import DuckoCore

extension DuckoCLI {
    struct Blocklist: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "blocklist",
            abstract: "Manage the server-side block list",
            subcommands: [List.self, Add.self, Remove.self],
            defaultSubcommand: List.self
        )

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "List blocked addresses"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    let entries = try await env.rosterService.loadBlockList(accountID: selectedAccount.id)

                    guard !entries.isEmpty else {
                        print(formatter.formatEmptyResult(.blockList(accountID: selectedAccount.id)))
                        return
                    }

                    for entry in entries {
                        print(formatter.formatBlockListEntry(entry))
                    }
                }
            }
        }

        struct Add: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Block an address"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The JID to block; a full JID blocks only that device")
            var jid: String

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    try await env.rosterService.blockContact(jidString: jid, accountID: selectedAccount.id)

                    print("Blocked \(jid).")
                }
            }
        }

        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Unblock an address"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The JID to unblock, exactly as the block list shows it")
            var jid: String

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    try await env.rosterService.unblockContact(jidString: jid, accountID: selectedAccount.id)

                    print("Unblocked \(jid).")
                }
            }
        }
    }
}
