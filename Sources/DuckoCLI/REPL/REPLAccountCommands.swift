import DuckoCore
import DuckoXMPP
import Foundation

func handleUnregisterAccountREPLCommand(context: REPLContext) async {
    print("WARNING: This will permanently unregister your account from the server.")
    print("Type 'yes' to confirm:")
    guard readLine()?.trimmingCharacters(in: .whitespaces) == "yes" else {
        print("Cancelled.")
        return
    }
    print("Also delete chat history? (yes/no):")
    let includeHistory = readLine()?.trimmingCharacters(in: .whitespaces) == "yes"
    do {
        try await context.environment.cancelAccount(context.accountID, includeHistory: includeHistory)
        print("Account unregistered.")
        if includeHistory {
            print("Chat history deleted.")
        }
        Foundation.exit(0)
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleCheckRegistrationREPLCommand(_ arguments: String, context: REPLContext) async {
    let jid = arguments.isEmpty ? nil : arguments
    do {
        let form = try await context.environment.accountService.retrieveRegistrationForm(
            accountID: context.accountID, from: jid
        )
        print(context.formatter.formatRegistrationForm(form))
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleSubmitRegistrationREPLCommand(_ arguments: String, context: REPLContext) async {
    let jid = arguments.isEmpty ? nil : arguments
    do {
        var form = try await context.environment.accountService.retrieveRegistrationForm(
            accountID: context.accountID, from: jid
        )
        print(context.formatter.formatRegistrationForm(form))
        guard form.hasFields else { throw CLIError.registrationRedirected }

        print("\nEnter registration details (press Enter to keep a value):")
        try promptForRegistrationValues(&form, formatter: context.formatter)
        try await context.environment.accountService.submitRegistration(
            accountID: context.accountID, form: form, to: jid
        )
        print("Registration submitted successfully.")
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleAvatarREPLCommand(_ arguments: String, context: REPLContext) async {
    if arguments.isEmpty {
        let hash = await MainActor.run { context.environment.avatarService.ownAvatarHash(for: context.accountID) }
        if let hash {
            print("Own avatar hash: \(hash)")
        } else {
            print("No avatar set.")
        }
        return
    }

    guard let jid = BareJID.parse(arguments) else {
        print(context.formatter.formatError(CLIError.invalidJID(arguments)))
        return
    }

    guard let avatar = await context.environment.avatarService.fetchAvatar(for: jid, accountID: context.accountID) else {
        print("No avatar found for \(jid).")
        return
    }

    print("Avatar for \(jid):")
    print("  Hash: \(avatar.hash)")
    print("  Type: \(avatar.mimeType)")
    print("  Size: \(avatar.data.count) bytes")
}

func handleProfileREPLCommand(context: REPLContext) async {
    let output = await fetchAndFormatProfile(
        environment: context.environment, accountID: context.accountID, formatter: context.formatter
    )
    print(output)
}

func handleConnectionInfoREPLCommand(context: REPLContext) async {
    let info = await MainActor.run { context.environment.accountService.tlsInfo(for: context.accountID) }
    if let info {
        print(context.formatter.formatTLSInfo(info))
    } else {
        print("No TLS connection info available.")
    }
}
