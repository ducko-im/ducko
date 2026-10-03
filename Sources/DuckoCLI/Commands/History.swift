import ArgumentParser
import DuckoCore
import DuckoXMPP

extension DuckoCLI {
    struct History: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "View message history"
        )

        @OptionGroup var global: GlobalOptions

        @OptionGroup var accountOption: AccountOption

        @Argument(help: "The JID to view history for")
        var jid: String

        @Option(name: .long, help: "Maximum number of messages (default: 20)")
        var limit: Int = 20

        @Option(name: .long, help: "Show messages before this ISO 8601 date")
        var before: String?

        @Option(name: .long, help: "Filter messages by keyword (case-insensitive)")
        var search: String?

        @Flag(name: .long, help: "Fetch from server when local history is empty (requires connection)")
        var server: Bool = false

        func run() async throws {
            let formatter = global.formatter

            guard let bareJID = BareJID.parse(jid) else {
                throw CLIError.invalidJID(jid)
            }

            let context = try await MainActor.run {
                try CLIBootstrap.setUp(formatter: formatter)
            }
            let env = context.environment

            let selectedAccount = try await resolveAccount(accountOption.account, environment: env)

            if let search {
                let messages = try await searchHistory(
                    jid: bareJID, query: search, limit: limit,
                    environment: env, accountID: selectedAccount.id
                )
                printHistory(messages, formatter: formatter, accountJID: selectedAccount.jid)
                return
            }

            let beforeDate = try parseBeforeDate(before)
            var messages = try await fetchHistory(
                jid: bareJID, before: beforeDate, limit: limit,
                environment: env, accountID: selectedAccount.id
            )

            if server, messages.isEmpty {
                let password = CredentialHelper.getPassword(for: selectedAccount.jid.description, using: env.credentialStore)
                guard let password else { throw CLIError.noPassword }
                messages = try await ConnectedOperation.run(environment: env, account: selectedAccount, password: password) {
                    let (serverMessages, _) = try await env.chatService.fetchServerHistory(
                        jid: bareJID, accountID: selectedAccount.id, before: beforeDate, limit: limit
                    )
                    return serverMessages
                }
            }

            let notes = try await fetchHistoryNotes(
                jid: bareJID, among: messages, before: beforeDate,
                environment: env, accountID: selectedAccount.id
            )
            printHistory(messages, notes: notes, formatter: formatter, accountJID: selectedAccount.jid)
        }
    }
}
