import DuckoCore
import DuckoXMPP
import Foundation

func handleUnregisterAccountREPLCommand(context: REPLContext) async {
    printToStandardError("WARNING: This will permanently unregister your account from the server.")
    printToStandardError("Type 'yes' to confirm:")
    guard readLine()?.trimmingCharacters(in: .whitespaces) == "yes" else {
        print(context.formatter.formatCommandResult(.unregisterCancelled))
        return
    }
    printToStandardError("Also delete chat history? (yes/no):")
    let includeHistory = readLine()?.trimmingCharacters(in: .whitespaces) == "yes"
    do {
        try await context.environment.cancelAccount(context.accountID, includeHistory: includeHistory)
        print(context.formatter.formatCommandResult(.accountUnregistered(historyDeleted: includeHistory)))
        Foundation.exit(0)
    } catch {
        print(context.formatter.formatError(error))
    }
}

/// Shows the registration form of the server or component `arguments` names, else of the account's server, or with
/// `submitting` prompts for its fields and submits it.
func handleRegistrationREPLCommand(_ arguments: String, context: REPLContext, submitting: Bool) async {
    let jid = arguments.isEmpty ? nil : arguments
    do {
        let accountService = await MainActor.run { context.environment.accountService }
        let form = try await accountService.retrieveRegistrationForm(accountID: context.accountID, from: jid)
        guard submitting else {
            print(context.formatter.formatRegistrationForm(form))
            return
        }
        let registration = SignedInRegistration(form: form, accountService: accountService, accountID: context.accountID, jid: jid)
        try await promptAndSubmitRegistration(
            registration, submissionsMade: 0, intro: "\nEnter registration details (press Enter to keep a value):", formatter: context.formatter
        )
        print(context.formatter.formatCommandResult(.registrationSubmitted))
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleChangePasswordREPLCommand(context: REPLContext) async {
    do {
        let newPassword = try CredentialHelper.readNewPassword()
        try await context.environment.accountService.changePassword(accountID: context.accountID, newPassword: newPassword)
        print(context.formatter.formatCommandResult(.passwordChanged))
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleAvatarREPLCommand(_ arguments: String, context: REPLContext) async {
    if arguments.isEmpty {
        let hash = await MainActor.run { context.environment.avatarService.ownAvatarHash(for: context.accountID) }
        if let hash {
            print(context.formatter.formatCommandResult(.ownAvatar(hash: hash)))
        } else {
            print(context.formatter.formatEmptyResult(.ownAvatar))
        }
        return
    }

    guard let jid = BareJID.parse(arguments) else {
        print(context.formatter.formatError(CLIError.invalidJID(arguments)))
        return
    }

    guard let avatar = await context.environment.avatarService.fetchAvatar(for: jid, accountID: context.accountID) else {
        print(context.formatter.formatEmptyResult(.avatar(jid: jid.description)))
        return
    }

    print(context.formatter.formatCommandResult(.avatar(jid: jid.description, hash: avatar.hash, mimeType: avatar.mimeType, size: avatar.data.count)))
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
        print(context.formatter.formatEmptyResult(.connectionInfo))
    }
}
