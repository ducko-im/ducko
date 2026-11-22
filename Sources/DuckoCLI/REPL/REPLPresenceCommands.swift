import DuckoCore
import DuckoXMPP
import Foundation

func handleStatusCommand(_ arguments: String, context: REPLContext) async {
    let environment = context.environment
    if arguments.isEmpty {
        let (myPresence, myMessage) = await MainActor.run {
            (environment.presenceService.myPresence, environment.presenceService.myStatusMessage)
        }
        print(context.formatter.formatPresence(jid: context.accountJID, status: myPresence.rawValue, message: myMessage))
        return
    }

    let parts = arguments.split(separator: " ", maxSplits: 1)
    let statusString = String(parts[0])
    let message: String? = parts.count > 1 ? String(parts[1]) : nil

    guard let presenceStatus = PresenceService.PresenceStatus(rawValue: statusString) else {
        print(context.formatter.formatError(CLIError.invalidPresenceStatus(statusString)))
        return
    }

    await applyPresence(presenceStatus, message: message, environment: environment, accountID: context.accountID)

    print(context.formatter.formatPresence(jid: context.accountJID, status: presenceStatus.rawValue, message: message))
}

func handleWhoCommand(context: REPLContext) async {
    let environment = context.environment
    let (groups, presences) = await MainActor.run {
        (environment.rosterService.groups, environment.presenceService.contactPresences)
    }

    var seen = Set<String>()
    var onlineContacts: [(Contact, PresenceService.PresenceStatus)] = []
    for contact in groups.flatMap(\.contacts) where seen.insert(contact.jid.description).inserted {
        if let presence = presences[contact.jid], presence != .offline {
            onlineContacts.append((contact, presence))
        }
    }
    onlineContacts.sort { $0.0.jid.description < $1.0.jid.description }

    guard !onlineContacts.isEmpty else {
        print(context.formatter.formatEmptyResult(.onlineContacts))
        return
    }

    for (contact, presence) in onlineContacts {
        print(context.formatter.formatContactWithPresence(contact, presence: presence))
    }
}

func handleDirectedPresenceREPLCommand(_ jidString: String, context: REPLContext) async {
    guard JID.parse(jidString) != nil else {
        print(context.formatter.formatError(CLIError.invalidJID(jidString)))
        return
    }
    do {
        try await context.environment.presenceService.sendDirectedPresence(to: jidString, accountID: context.accountID)
        print(context.formatter.formatCommandResult(.directedPresenceSent(jid: jidString)))
    } catch {
        print(context.formatter.formatError(error))
    }
}
