import ArgumentParser
import DuckoCore

extension DuckoCLI {
    struct OMEMO: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "omemo",
            abstract: "OMEMO encryption management",
            subcommands: [Fingerprint.self, Devices.self, Trust.self, Untrust.self, Verify.self, Reset.self]
        )

        struct Fingerprint: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Display your own OMEMO device fingerprint"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    let fingerprint = await env.omemoService.ownFingerprint(accountID: selectedAccount.id)
                    if let fingerprint {
                        print(formatter.formatOMEMOFingerprint(fingerprint))
                    } else {
                        print(formatter.formatEmptyResult(.omemoIdentity(accountID: selectedAccount.id)))
                    }
                }
            }
        }

        struct Devices: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "List a contact's OMEMO devices with trust status"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The contact JID")
            var jid: String

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    for line in await omemoDeviceLines(jid: jid, accountID: selectedAccount.id, environment: env, formatter: formatter) {
                        print(line)
                    }
                }
            }
        }

        struct Trust: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Trust a contact's OMEMO device"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The contact JID")
            var jid: String

            @Argument(help: "The device ID to trust")
            var deviceID: UInt32

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    let device = try await omemoDevice(jid: jid, deviceID: deviceID, accountID: selectedAccount.id, environment: env)
                    try await env.omemoService.trustDevice(
                        accountID: selectedAccount.id, peerJID: jid,
                        deviceID: deviceID, fingerprint: device.fingerprint
                    )
                    print(formatter.formatOMEMOTrustChange(jid: jid, deviceID: deviceID, trustLevel: .trusted))
                }
            }
        }

        struct Untrust: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Untrust a contact's OMEMO device"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The contact JID")
            var jid: String

            @Argument(help: "The device ID to untrust")
            var deviceID: UInt32

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    try await env.omemoService.untrustDevice(
                        accountID: selectedAccount.id, peerJID: jid, deviceID: deviceID
                    )
                    print(formatter.formatOMEMOTrustChange(jid: jid, deviceID: deviceID, trustLevel: .untrusted))
                }
            }
        }

        struct Verify: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Mark a contact's OMEMO device verified after comparing its fingerprint"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The contact JID")
            var jid: String

            @Argument(help: "The device ID to verify")
            var deviceID: UInt32

            @Argument(help: "The fingerprint you compared, as 'omemo devices' shows it")
            var fingerprint: [String]

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    try await verifyOMEMODevice(
                        jid: jid, deviceID: deviceID, fingerprint: fingerprint.joined(separator: " "),
                        accountID: selectedAccount.id, environment: env
                    )
                    print(formatter.formatOMEMOTrustChange(jid: jid, deviceID: deviceID, trustLevel: .verified))
                }
            }
        }

        struct Reset: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Reset the OMEMO sessions with a contact's devices, or with your other devices"
            )

            @OptionGroup var global: GlobalOptions

            @OptionGroup var accountOption: AccountOption

            @Argument(help: "The contact JID, or your own JID for your other devices")
            var jid: String

            @Option(name: .customLong("device"), help: "Reset only the session with this device ID")
            var deviceID: UInt32?

            func run() async throws {
                let formatter = global.formatter

                try await ConnectedOperation.run(formatter: formatter, account: accountOption.account) { env, selectedAccount in
                    let report = try await env.omemoService.resetSessions(peerJID: jid, deviceID: deviceID, accountID: selectedAccount.id)
                    print(formatter.formatOMEMOSessionReset(report))
                }
            }
        }
    }
}
