import ArgumentParser
import DuckoCore
import DuckoXMPP
import Foundation

extension DuckoCLI {
    struct Account: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage XMPP accounts",
            subcommands: [List.self, Add.self, Set.self, Delete.self, Unregister.self, Register.self, CheckRegistration.self],
            defaultSubcommand: List.self
        )

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "List configured accounts"
            )

            @OptionGroup var global: GlobalOptions

            func run() async throws {
                let formatter = global.formatter

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }
                let env = context.environment

                try await env.accountService.loadAccounts()
                let accounts = await MainActor.run { env.accountService.accounts }

                guard !accounts.isEmpty else {
                    print(formatter.formatEmptyResult(.accounts))
                    return
                }

                for account in accounts {
                    print(formatter.formatAccount(account))
                }
            }
        }

        struct Add: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Add a new XMPP account"
            )

            @Argument(help: "The bare JID (e.g. alice@example.com)")
            var jid: String

            @Option(name: .long, help: "Password (prompted if omitted)")
            var password: String?

            @OptionGroup var endpoint: ConnectionEndpointOptions

            @Flag(name: .long, help: "Add the account without connecting to validate (offline setup)")
            var noConnect = false

            @Flag(name: .long, help: "Send the password to a server that offers only PLAIN")
            var allowPlain = false

            func run() async throws {
                guard BareJID.parse(jid) != nil else {
                    throw CLIError.invalidJID(jid)
                }

                guard let resolvedPassword = try password ?? CredentialHelper.getPassword() else {
                    throw CLIError.noPassword
                }

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: PlainFormatter())
                }
                let env = context.environment
                let effectivePort = endpoint.host == nil ? nil : Int(endpoint.port ?? 5222)

                if noConnect {
                    let accountID = try await env.accountService.createAccount(
                        jidString: jid, host: endpoint.host, port: effectivePort, connectOnLaunch: false, allowsPLAIN: allowPlain
                    )
                    await env.accountService.savePassword(accountID: accountID, password: resolvedPassword)
                } else {
                    let accountID: UUID
                    do {
                        accountID = try await env.accountService.createAndConnect(
                            jidString: jid,
                            password: resolvedPassword,
                            host: endpoint.host,
                            port: effectivePort,
                            allowsPLAIN: allowPlain
                        ) { accountID in
                            try await waitForConnected(accountID: accountID, environment: env)
                        }
                    } catch {
                        if AccountService.isPLAINRefusal(error) {
                            printToStandardError(plainRefusalHint(.accountAdd(host: endpoint.host, port: endpoint.port), jid: jid))
                        }
                        throw error
                    }
                    await env.accountService.disconnect(accountID: accountID)
                }

                print("Account added: \(jid)")
            }
        }

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Change an account's sign-in settings without connecting"
            )

            @OptionGroup var global: GlobalOptions

            @Argument(help: "The bare JID of the account")
            var jid: String

            @Flag(
                inversion: .prefixedNo, exclusivity: .exclusive,
                help: "Whether a server that offers only PLAIN gets the password. A sign-in that doesn't send it turns this off again."
            )
            var allowPlain: Bool?

            @Flag(inversion: .prefixedNo, exclusivity: .exclusive, help: "Whether the connection must be encrypted")
            var requireTLS: Bool?

            func validate() throws {
                if allowPlain == nil, requireTLS == nil {
                    throw ValidationError("Specify --allow-plain/--no-allow-plain or --require-tls/--no-require-tls.")
                }
            }

            func run() async throws {
                let formatter = global.formatter
                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }
                let env = context.environment

                var account = try await resolveAccount(byJID: jid, environment: env)
                if let requireTLS {
                    account.requireTLS = requireTLS
                    try await env.accountService.updateAccount(account)
                }
                if let allowPlain {
                    try await env.accountService.setAllowsPLAIN(allowPlain, for: account.id)
                }

                let saved = try await resolveAccount(byJID: jid, environment: env)
                print(formatter.formatAccount(saved))
                if allowPlain == true {
                    printToStandardError("A sign-in that doesn't send the password turns PLAIN off again.")
                }
            }
        }

        struct Delete: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Delete an XMPP account"
            )

            @Argument(help: "The bare JID of the account to delete")
            var jid: String

            @Flag(name: .long, help: "Also delete chat history for the account")
            var includeHistory = false

            func run() async throws {
                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: PlainFormatter())
                }
                let env = context.environment

                let account = try await resolveAccount(byJID: jid, environment: env)

                await env.removeAccount(account.id, includeHistory: includeHistory)
                print("Account deleted: \(jid)")
                if includeHistory {
                    print("Chat history deleted.")
                }
            }
        }

        struct Unregister: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Unregister an account from the server via XEP-0077"
            )

            @Argument(help: "The bare JID of the account to unregister")
            var jid: String

            @Flag(name: .long, help: "Also delete chat history for the account")
            var includeHistory = false

            func run() async throws {
                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: PlainFormatter())
                }
                let env = context.environment

                let account = try await resolveAccount(byJID: jid, environment: env)

                print("WARNING: This will permanently unregister \(jid) from the server.")
                if includeHistory {
                    print("Chat history will also be deleted.")
                }
                print("Type 'yes' to confirm:")
                guard readLine()?.trimmingCharacters(in: .whitespaces) == "yes" else {
                    print("Cancelled.")
                    return
                }

                guard let password = try CredentialHelper.getPassword(for: account.jid.description, using: env.credentialStore) else {
                    throw CLIError.noPassword
                }

                try await ConnectedOperation.run(environment: env, account: account, password: password) {
                    try await env.cancelAccount(account.id, includeHistory: includeHistory)
                    print("Account unregistered: \(jid)")
                    if includeHistory {
                        print("Chat history deleted.")
                    }
                }
            }
        }

        struct Register: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Register a new account on a server via XEP-0077"
            )

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Server domain (e.g. example.com)")
            var server: String

            @Option(name: .long, help: "Username for the new account")
            var username: String

            @Option(name: .long, help: "Password for the new account (prompted if omitted)")
            var password: String?

            @Option(name: .long, help: "Email address (optional)")
            var email: String?

            @OptionGroup var endpoint: ConnectionEndpointOptions

            func run() async throws {
                guard let resolvedPassword = try password ?? CredentialHelper.getPassword() else {
                    throw CLIError.noPassword
                }

                let formatter = global.formatter

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }

                let outcome = try await context.environment.accountService.registerAccount(
                    domain: server,
                    username: username,
                    password: resolvedPassword,
                    email: email,
                    host: endpoint.host,
                    port: endpoint.port ?? 5222
                ) { accountID in
                    try await waitForConnected(accountID: accountID, environment: context.environment)
                }
                let accountID = switch outcome {
                case let .registered(accountID): accountID
                case let .needsMoreFields(pending): try await completeRegistration(pending, formatter: formatter)
                }
                let jid = await MainActor.run {
                    context.environment.accountService.accounts.first { $0.id == accountID }?.jid.description
                }
                await context.environment.accountService.disconnect(accountID: accountID)
                print("Account registered: \(jid ?? "\(username)@\(server)")")
            }
        }

        struct CheckRegistration: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "check-registration",
                abstract: "Show a server's registration form without registering (XEP-0077)"
            )

            @OptionGroup var global: GlobalOptions

            @Option(name: .long, help: "Server domain (e.g. example.com)")
            var server: String

            @OptionGroup var endpoint: ConnectionEndpointOptions

            func run() async throws {
                let formatter = global.formatter

                let context = try await MainActor.run {
                    try CLIBootstrap.setUp(formatter: formatter)
                }

                let form = try await context.environment.accountService.retrieveRegistrationForm(
                    domain: server, host: endpoint.host, port: endpoint.port ?? 5222
                )
                print(formatter.formatRegistrationForm(form))
            }
        }
    }
}

struct ConnectionEndpointOptions: ParsableArguments {
    @Option(name: .long, help: "Override hostname for connection")
    var host: String?

    @Option(name: .long, help: "Port for --host (default 5222)")
    var port: UInt16?

    /// The override applies only when both are set and otherwise falls back to SRV/domain
    /// discovery, so a lone `--port` would silently no-op.
    func validate() throws {
        if port != nil, host == nil {
            throw ValidationError("--port requires --host")
        }
    }
}
