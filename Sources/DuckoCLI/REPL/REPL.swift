import DuckoCore
import DuckoXMPP
import Foundation

func runREPL(formatter: any CLIFormatter, environment: AppEnvironment, accountID: UUID, accountJID: BareJID) async {
    let context = REPLContext(formatter: formatter, environment: environment, accountID: accountID, accountJID: accountJID)
    var currentRoom: String?

    while let line = readLine() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }

        let command = REPLCommand(trimmed)
        if let change = await dispatchREPLCommand(command, context: context, currentRoom: currentRoom) {
            currentRoom = change.applying(to: currentRoom)
        } else {
            print("Unknown command: \(trimmed). Type 'help' for commands.")
        }
    }

    await quitREPL(context: context, currentRoom: currentRoom)
}

private func quitREPL(context: REPLContext, currentRoom: String?) async -> Never {
    if let currentRoom {
        try? await context.environment.chatService.leaveRoom(jidString: currentRoom, accountID: context.accountID)
    }
    await context.environment.accountService.disconnect(accountID: context.accountID)
    Foundation.exit(0)
}

struct REPLContext {
    let formatter: any CLIFormatter
    let environment: AppEnvironment
    let accountID: UUID
    let accountJID: BareJID
}

/// Returns `nil` for an unrecognized command; handlers that can change the current room report the change.
private func dispatchREPLCommand(
    _ command: REPLCommand, context: REPLContext, currentRoom: String?
) async -> RoomSelectionChange? {
    let arguments = command.arguments.trimmingCharacters(in: .whitespaces)
    switch command.kind {
    case .send: await handleSendCommand(arguments, context: context)
    case .roster: await handleRosterCommand(context: context)
    case .status: await handleStatusCommand(arguments, context: context)
    case .who: await handleWhoCommand(context: context)
    case .add: await handleAddCommand(arguments, context: context)
    case .remove: await handleRemoveCommand(arguments, context: context)
    case .history: await handleHistoryCommand(arguments, context: context)
    case .profile: await handleProfileREPLCommand(context: context)
    case .reply: await handleReplyREPLCommand(arguments, context: context)
    case .retract: await handleRetractREPLCommand(arguments, context: context)
    case .edit: await handleEditREPLCommand(arguments, context: context)
    case .search: await handleSearchREPLCommand(arguments, context: context)
    case .approve: await handleApproveREPLCommand(arguments, context: context)
    case .deny: await handleDenyREPLCommand(arguments, context: context)
    case .directedPresence: await handleDirectedPresenceREPLCommand(arguments, context: context)
    case .unregisterAccount: await handleUnregisterAccountREPLCommand(context: context)
    case .checkRegistration: await handleCheckRegistrationREPLCommand(arguments, context: context)
    case .submitRegistration: await handleSubmitRegistrationREPLCommand(arguments, context: context)
    case .join: return await handleJoinREPLCommand(arguments, context: context)
    case .leave: return await handleLeaveREPLCommand(arguments, context: context, currentRoom: currentRoom)
    case .members: await handleMembersREPLCommand(arguments, context: context, currentRoom: currentRoom)
    case .topic: await handleTopicREPLCommand(arguments, context: context, currentRoom: currentRoom)
    case .nick: await handleNickREPLCommand(arguments, context: context, currentRoom: currentRoom)
    case .destroy: return await handleDestroyREPLCommand(arguments, context: context, currentRoom: currentRoom)
    case .voice: await handleVoiceREPLCommand(arguments, context: context, currentRoom: currentRoom)
    case .kick: await handleKickREPLCommand(arguments, context: context, currentRoom: currentRoom)
    case .pm: await handlePMREPLCommand(arguments, context: context, currentRoom: currentRoom)
    case .affiliations: await handleAffiliationsREPLCommand(arguments, context: context, currentRoom: currentRoom)
    case .config: await handleConfigREPLCommand(arguments, context: context, currentRoom: currentRoom)
    case .moderate: await handleModerateREPLCommand(arguments, context: context, currentRoom: currentRoom)
    case .sendfile: await handleSendFileREPLCommand(arguments, context: context, currentRoom: currentRoom)
    case .senddirect: await handleSendFileREPLCommand(arguments, context: context, currentRoom: nil, directly: true)
    case .accept: await handleAcceptREPLCommand(arguments, context: context)
    case .decline: await handleDeclineREPLCommand(arguments, context: context)
    case .transfers: await handleTransfersREPLCommand(context: context)
    case .rooms: await handleRoomsREPLCommand(arguments, context: context)
    case .avatar: await handleAvatarREPLCommand(arguments, context: context)
    case .connectionInfo: await handleConnectionInfoREPLCommand(context: context)
    case .encrypt: await handleEncryptREPLCommand(arguments, context: context)
    case .pref: await handlePrefREPLCommand(arguments)
    case .help: print(REPLCommand.help)
    case .quit: await quitREPL(context: context, currentRoom: currentRoom)
    case nil: return nil
    }
    return .unchanged
}
