import ArgumentParser
import DuckoCore
import Foundation

extension DuckoCLI {
    struct Room: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage multi-user chat rooms",
            subcommands: [ListRooms.self, Join.self, Members.self, Send.self],
            defaultSubcommand: ListRooms.self
        )

        struct ListRooms: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "list",
                abstract: "Discover available rooms on a MUC service"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Option(name: .long, help: "MUC service JID (auto-discovered if omitted)")
            var service: String?

            @Option(name: [.customShort("q"), .long], help: "Search for channels by keyword (XEP-0433)")
            var search: String?

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    if let search {
                        let channels = try await env.chatService.searchChannels(keyword: search, accountID: selectedAccount.id).channels
                        for channel in channels {
                            print(formatter.formatSearchedChannel(channel))
                        }
                        if channels.isEmpty {
                            print(formatter.formatEmptyResult(.channels))
                        }
                    } else {
                        let serviceJID = try await resolveMUCService(service, environment: env, accountID: selectedAccount.id)
                        let rooms = try await env.chatService.discoverRooms(on: serviceJID, accountID: selectedAccount.id)
                        printDiscoveredRooms(rooms, formatter: formatter)
                    }
                }
            }
        }

        struct Join: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Join a room and monitor messages"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The room JID")
            var jid: String

            @Option(name: .long, help: "Nickname to use (defaults to local part of account JID)")
            var nickname: String?

            func run() async throws {
                let formatter = global.formatter

                let prepared = try await ConnectedOperation.prepare(formatter: formatter, account: accountOption.account, isInteractive: true)
                let env = prepared.environment
                let selectedAccount = prepared.account
                let password = prepared.password

                try await env.accountService.connect(accountID: selectedAccount.id, password: password)
                try await waitForConnected(accountID: selectedAccount.id, environment: env)

                let nick = nickname ?? defaultNickname(for: selectedAccount)
                try await env.chatService.joinRoomAwaitingEcho(
                    jidString: jid, nickname: nick,
                    accountID: selectedAccount.id, timeout: .seconds(15), remember: false
                )

                let participantCount = await MainActor.run { env.chatService.participantCount(forRoomJIDString: jid, accountID: selectedAccount.id) }
                print(formatter.formatRoomJoinedConfirmation(room: jid, nickname: nick, participantCount: participantCount, subject: nil))
                print("Type 'send <message>' to send, 'quit' to leave.")

                let accountID = selectedAccount.id
                let roomJID = jid
                await Task.detached {
                    await runRoomLoop(roomJID: roomJID, formatter: formatter, environment: env, accountID: accountID)
                }.value
            }
        }

        struct Members: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Show room occupants"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The room JID")
            var jid: String

            @Option(name: .long, help: "Nickname to use (defaults to local part of account JID)")
            var nickname: String?

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    let nick = nickname ?? defaultNickname(for: selectedAccount)
                    try await env.chatService.joinRoomAwaitingEcho(
                        jidString: jid, nickname: nick,
                        accountID: selectedAccount.id, timeout: .seconds(15), remember: false
                    )

                    await printRoomMembers(jidString: jid, accountID: selectedAccount.id, environment: env, formatter: formatter)

                    try await env.chatService.leaveRoom(jidString: jid, accountID: selectedAccount.id, forget: false)
                }
            }
        }

        struct Send: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Send a message to a room"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The room JID")
            var jid: String

            @Argument(help: "The message body")
            var body: String

            @Option(name: .long, help: "Nickname to use (defaults to local part of account JID)")
            var nickname: String?

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    let nick = nickname ?? defaultNickname(for: selectedAccount)
                    try await env.chatService.joinRoomAwaitingEcho(
                        jidString: jid, nickname: nick,
                        accountID: selectedAccount.id, timeout: .seconds(15), remember: false
                    )

                    try await env.chatService.sendGroupMessage(toJIDString: jid, body: body, accountID: selectedAccount.id)

                    try await env.chatService.leaveRoom(jidString: jid, accountID: selectedAccount.id, forget: false)
                }
            }
        }
    }
}

private func runRoomLoop(roomJID: String, formatter: any CLIFormatter, environment: AppEnvironment, accountID: UUID) async {
    while let line = readLine() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }

        if trimmed == "quit" || trimmed == "exit" {
            break
        }

        if trimmed.hasPrefix("send ") {
            let body = String(trimmed.dropFirst(5))
            do {
                try await environment.chatService.sendGroupMessage(toJIDString: roomJID, body: body, accountID: accountID)
            } catch {
                print(formatter.formatError(error))
            }
        } else {
            print("Commands: send <message>, quit")
        }
    }

    // quit or stdin closed
    try? await environment.chatService.leaveRoom(jidString: roomJID, accountID: accountID, forget: false)
    await environment.accountService.disconnect(accountID: accountID)
    Foundation.exit(0)
}
