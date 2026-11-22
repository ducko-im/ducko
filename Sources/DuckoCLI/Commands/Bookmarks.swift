import ArgumentParser
import DuckoCore

extension DuckoCLI {
    struct Bookmarks: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bookmarks",
            abstract: "Manage PEP bookmarks",
            subcommands: [List.self, Add.self, Remove.self],
            defaultSubcommand: List.self
        )

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "List server-side bookmarks"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    await env.bookmarksService.loadBookmarks(accountID: selectedAccount.id)
                    let bookmarks = await MainActor.run { env.bookmarksService.bookmarks }

                    guard !bookmarks.isEmpty else {
                        print(formatter.formatEmptyResult(.bookmarks(accountID: selectedAccount.id)))
                        return
                    }

                    for bookmark in bookmarks {
                        print(formatter.formatBookmark(bookmark))
                    }
                }
            }
        }

        struct Add: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Add a bookmark"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The room JID")
            var jid: String

            @Option(name: .long, help: "Display name for the room")
            var name: String?

            @Option(name: .long, help: "Nickname to use in the room")
            var nickname: String?

            @Flag(name: .long, help: "Auto-join room on connect")
            var autojoin = false

            @Option(name: .long, help: "Room password")
            var password: String?

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    let bookmark = RoomBookmark(
                        jidString: jid,
                        name: name,
                        autojoin: autojoin,
                        nickname: nickname,
                        password: password
                    )
                    try await env.bookmarksService.addBookmark(bookmark, accountID: selectedAccount.id)

                    print(formatter.formatCommandResult(.bookmarkAdded(jid: jid)))
                }
            }
        }

        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Remove a bookmark"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The room JID to remove")
            var jid: String

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    try await env.bookmarksService.removeBookmark(jidString: jid, accountID: selectedAccount.id)

                    print(formatter.formatCommandResult(.bookmarkRemoved(jid: jid)))
                }
            }
        }
    }
}
