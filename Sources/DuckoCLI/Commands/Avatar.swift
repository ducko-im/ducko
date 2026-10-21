import ArgumentParser
import DuckoCore
import DuckoXMPP
import Foundation
import UniformTypeIdentifiers

extension DuckoCLI {
    struct Avatar: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "avatar",
            abstract: "Manage user avatars",
            subcommands: [Get.self, Set.self]
        )

        struct Get: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Fetch and save a contact's avatar"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The JID to fetch the avatar from")
            var jid: String

            @Option(name: .long, help: "File path to save the avatar (default: <jid>.<ext> from the avatar type)")
            var save: String?

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    guard let bareJID = BareJID.parse(jid) else {
                        throw CLIError.invalidJID(jid)
                    }

                    guard let avatar = await env.avatarService.fetchAvatar(for: bareJID, accountID: selectedAccount.id) else {
                        print("No avatar found for \(jid).")
                        return
                    }

                    let ext = UTType(mimeType: avatar.mimeType)?.preferredFilenameExtension ?? "png"
                    let filePath = save ?? "\(jid).\(ext)"
                    try avatar.data.write(to: URL(fileURLWithPath: filePath))

                    print("Saved avatar to \(filePath)")
                    print("Hash: \(avatar.hash)")
                    print("Type: \(avatar.mimeType)")
                    print("Size: \(avatar.data.count) bytes")
                }
            }
        }

        struct Set: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Publish own avatar from an image file"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "Path to the image file, published as PNG")
            var path: String

            func run() async throws {
                let formatter = global.formatter

                let prepared = try await ConnectedOperation.prepare(formatter: formatter, account: accountOption.account)
                let env = prepared.environment
                let selectedAccount = prepared.account
                let password = prepared.password

                let imageData = try Data(contentsOf: URL(fileURLWithPath: path))

                try await ConnectedOperation.run(environment: env, account: selectedAccount, password: password) {
                    let avatar = try await env.avatarService.publishAvatar(imageData: imageData, accountID: selectedAccount.id)

                    print("Avatar published successfully.")
                    print("Hash: \(avatar.hash)")
                    print("Size: \(avatar.data.count) bytes")
                }
            }
        }
    }
}
