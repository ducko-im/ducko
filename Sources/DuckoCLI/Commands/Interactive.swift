import ArgumentParser
import DuckoCore

extension DuckoCLI {
    struct Interactive: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start interactive REPL mode"
        )

        @OptionGroup var global: GlobalOptions

        @OptionGroup var accountOption: AccountOption

        func run() async throws {
            let formatter = global.formatter

            let prepared = try await ConnectedOperation.prepare(formatter: formatter, account: accountOption.account, isInteractive: true)
            let env = prepared.environment
            await MainActor.run { env.bookmarksService.autoJoinEnabled = true }
            let selectedAccount = prepared.account
            let password = prepared.password
            let accountJID = selectedAccount.jid

            try await connectHeldSession(env, account: selectedAccount, password: password)

            printToStandardError("Connected. Type 'help' for commands, 'quit' to exit.")

            // Run readLine loop in Task.detached (blocking I/O must not run on cooperative thread)
            let accountID = selectedAccount.id
            await Task.detached {
                await runREPL(formatter: formatter, environment: env, accountID: accountID, accountJID: accountJID)
            }.value
        }
    }
}
