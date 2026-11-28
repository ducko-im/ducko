import DuckoCore
import DuckoXMPP
import Foundation

func handleSendCommand(_ arguments: String, context: REPLContext) async {
    let parts = arguments.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print(context.formatter.formatUsageError("Usage: send <jid> <message>"))
        return
    }
    let jidString = String(parts[0])
    let messageBody = String(parts[1])
    let environment = context.environment
    let accountID = context.accountID

    guard let recipientJID = BareJID.parse(jidString) else {
        print(context.formatter.formatError(CLIError.invalidJID(jidString)))
        return
    }

    do {
        let (isRoom, looksLikeUnjoinedRoom) = await MainActor.run {
            let joined = !environment.chatService.participants(forRoomJIDString: jidString, accountID: accountID).isEmpty
            let unjoinedRoom = !joined && environment.chatService.knownRoomDomains(accountID: accountID).contains(recipientJID.domainPart)
            return (joined, unjoinedRoom)
        }
        if isRoom {
            try await environment.chatService.sendGroupMessage(to: recipientJID, body: messageBody, accountID: accountID)
        } else {
            if looksLikeUnjoinedRoom {
                printToStandardError("Hint: send <room-jid> requires /join first; delivering as 1:1 message.")
            }
            try await environment.chatService.sendMessage(to: recipientJID, body: messageBody, accountID: accountID)
        }
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleHistoryCommand(_ arguments: String, context: REPLContext) async {
    let usage = "Usage: /history <jid> [limit]"
    let parts = arguments.split(separator: " ", maxSplits: 1)
    guard let jidPart = parts.first else {
        print(context.formatter.formatUsageError(usage))
        return
    }
    let jidString = String(jidPart)
    guard let bareJID = BareJID.parse(jidString) else {
        print(context.formatter.formatError(CLIError.invalidJID(jidString)))
        return
    }

    var limit = 20
    if parts.count > 1 {
        guard let parsed = Int(parts[1]), parsed > 0 else {
            print(context.formatter.formatUsageError(usage))
            return
        }
        limit = parsed
    }

    do {
        let messages = try await fetchHistory(
            jid: bareJID, before: nil, limit: limit,
            environment: context.environment, accountID: context.accountID
        )
        let notes = try await fetchHistoryNotes(
            jid: bareJID, among: messages, before: nil,
            environment: context.environment, accountID: context.accountID
        )
        printHistory(messages, notes: notes, formatter: context.formatter, accountJID: context.accountJID)
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleRetractREPLCommand(_ jidString: String, context: REPLContext) async {
    do {
        let conversation = try await namedConversation(jidString, context: context)
        guard let original = try await lastOutgoingMessage(in: conversation, context: context), let stanzaID = original.stanzaID else {
            print(context.formatter.formatEmptyResult(.recentMessage(.retract)))
            return
        }
        try await context.environment.chatService.retractMessage(original, in: conversation, accountID: context.accountID)
        print(context.formatter.formatCommandResult(.messageRetracted(id: stanzaID)))
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleEditREPLCommand(_ arguments: String, context: REPLContext) async {
    let parts = arguments.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print(context.formatter.formatUsageError("Usage: /edit <jid> <new-body>"))
        return
    }
    let jidString = String(parts[0])
    let newBody = String(parts[1])
    do {
        let conversation = try await namedConversation(jidString, context: context)
        guard let original = try await lastOutgoingMessage(in: conversation, context: context), let stanzaID = original.stanzaID else {
            print(context.formatter.formatEmptyResult(.recentMessage(.edit)))
            return
        }
        try await context.environment.chatService.sendCorrection(of: original, newBody: newBody, in: conversation, accountID: context.accountID)
        print(context.formatter.formatCommandResult(.messageEdited(id: stanzaID)))
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleReplyREPLCommand(_ arguments: String, context: REPLContext) async {
    let parts = arguments.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print(context.formatter.formatUsageError("Usage: /reply <jid> <message>"))
        return
    }
    let jidString = String(parts[0])
    let body = String(parts[1])
    do {
        let conversation = try await namedConversation(jidString, context: context)
        let messages = try await recentMessages(in: conversation, context: context)
        guard let lastIncoming = messages.last(where: { !$0.isOutgoing && $0.replyReference != nil }),
              let replyReference = lastIncoming.replyReference
        else {
            print(context.formatter.formatEmptyResult(.recentMessage(.reply)))
            return
        }
        try await context.environment.chatService.sendMessage(body, in: conversation, replyingTo: lastIncoming, accountID: context.accountID)
        print(context.formatter.formatMessage(ChatMessage.displayPlaceholder(
            fromJID: jidString, body: body, replyToID: replyReference
        ), accountJID: context.accountJID))
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleSearchREPLCommand(_ arguments: String, context: REPLContext) async {
    let parts = arguments.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print(context.formatter.formatUsageError("Usage: /search <jid> <query>"))
        return
    }
    let jidString = String(parts[0])
    let query = String(parts[1])
    guard let bareJID = BareJID.parse(jidString) else {
        print(context.formatter.formatError(CLIError.invalidJID(jidString)))
        return
    }
    do {
        let days = try await searchHistory(
            jid: bareJID, query: query, limit: 20,
            environment: context.environment, accountID: context.accountID
        )
        printSearchResults(days, ofAllConversations: false, formatter: context.formatter, accountJID: context.accountJID)
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleSearchAllREPLCommand(_ query: String, context: REPLContext) async {
    do {
        let days = try await searchHistory(
            jid: nil, query: query, limit: 20,
            environment: context.environment, accountID: context.accountID
        )
        printSearchResults(days, ofAllConversations: true, formatter: context.formatter, accountJID: context.accountJID)
    } catch {
        print(context.formatter.formatError(error))
    }
}

@MainActor
func handlePrefREPLCommand(_ arguments: String, context: REPLContext) async {
    let parts = arguments.split(separator: " ", maxSplits: 1)
    let key = String(parts[0])
    let valueArg = parts.count == 2 ? String(parts[1]) : nil

    let result: CLICommandResult?
    switch key {
    case "chatstates":
        result = togglePref(name: "Chat states", key: "chatstates", value: valueArg, get: { ChatPreferences.shared.enableChatStates }, set: { ChatPreferences.shared.enableChatStates = $0 })
    case "markers":
        result = togglePref(name: "Displayed markers", key: "markers", value: valueArg, get: { ChatPreferences.shared.enableDisplayedMarkers }, set: { ChatPreferences.shared.enableDisplayedMarkers = $0 })
    default:
        print(context.formatter.formatUsageError("Unknown preference: \(key). Available: chatstates, markers"))
        return
    }
    if let result {
        print(context.formatter.formatCommandResult(result))
    } else {
        print(context.formatter.formatUsageError("Usage: /pref \(key) on|off"))
    }
}

/// The preference as `value` left it, or nil when `value` is neither on nor off.
@MainActor
private func togglePref(name: String, key: String, value: String?, get: () -> Bool, set: (Bool) -> Void) -> CLICommandResult? {
    guard let value else {
        return .preference(name: name, key: key, enabled: get(), changed: false)
    }
    switch value.lowercased() {
    case "on":
        set(true)
        return .preference(name: name, key: key, enabled: true, changed: true)
    case "off":
        set(false)
        return .preference(name: name, key: key, enabled: false, changed: true)
    default:
        return nil
    }
}

func handleEncryptREPLCommand(_ arguments: String, context: REPLContext) async {
    let parts = arguments.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print(context.formatter.formatUsageError("Usage: /encrypt <jid> on|off"))
        return
    }
    let jidString = String(parts[0])
    let toggle = String(parts[1]).lowercased()
    guard toggle == "on" || toggle == "off" else {
        print(context.formatter.formatUsageError("Usage: /encrypt <jid> on|off"))
        return
    }
    let enabled = toggle == "on"
    do {
        let conversation = try await context.environment.chatService.openConversation(
            jidString: jidString, accountID: context.accountID
        )
        try await context.environment.chatService.setEncryptionEnabled(
            enabled, for: conversation.id, accountID: context.accountID
        )
        print(context.formatter.formatCommandResult(.encryption(jid: jidString, enabled: enabled)))
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleOMEMODevicesREPLCommand(_ arguments: String, context: REPLContext) async {
    for line in await omemoDevicesREPLLines(arguments, context: context) {
        print(line)
    }
}

/// What `/omemo-devices` prints: the lines `omemo devices` prints for the one address it names.
func omemoDevicesREPLLines(_ arguments: String, context: REPLContext) async -> [String] {
    let parts = arguments.split(separator: " ")
    guard parts.count == 1 else { return [context.formatter.formatUsageError("Usage: /omemo-devices <jid>")] }
    return await omemoDeviceLines(jid: String(parts[0]), accountID: context.accountID, environment: context.environment, formatter: context.formatter)
}

func handleOMEMOVerifyREPLCommand(_ arguments: String, context: REPLContext) async {
    let parts = arguments.split(separator: " ", maxSplits: 2)
    guard parts.count == 3, let deviceID = UInt32(parts[1]) else {
        print(context.formatter.formatUsageError("Usage: /omemo-verify <jid> <device-id> <fingerprint>"))
        return
    }
    let jid = String(parts[0])
    do {
        try await verifyOMEMODevice(
            jid: jid, deviceID: deviceID, fingerprint: String(parts[2]), accountID: context.accountID, environment: context.environment
        )
        print(context.formatter.formatOMEMOTrustChange(jid: jid, deviceID: deviceID, trustLevel: .verified))
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleOMEMOResetREPLCommand(_ arguments: String, context: REPLContext) async {
    let parts = arguments.split(separator: " ")
    guard (1 ... 2).contains(parts.count) else {
        print(context.formatter.formatUsageError("Usage: /omemo-reset <jid> [device-id]"))
        return
    }
    let deviceID: UInt32?
    if parts.count == 2 {
        guard let parsed = UInt32(parts[1]) else {
            print(context.formatter.formatUsageError("Usage: /omemo-reset <jid> [device-id]"))
            return
        }
        deviceID = parsed
    } else {
        deviceID = nil
    }
    do {
        let report = try await context.environment.omemoService.resetSessions(
            peerJID: String(parts[0]), deviceID: deviceID, accountID: context.accountID
        )
        print(context.formatter.formatOMEMOSessionReset(report))
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleOMEMOSetupREPLCommand(context: REPLContext) async {
    let outcome = await context.environment.omemoService.retrySetup(accountID: context.accountID)
    print(omemoSetupRetryLine(outcome, accountID: context.accountID, formatter: context.formatter))
}

/// What `/omemo-setup` prints for `outcome`. The started attempt's own outcome arrives as an event.
func omemoSetupRetryLine(_ outcome: OMEMOSetupRetryOutcome, accountID: UUID, formatter: any CLIFormatter) -> String {
    switch outcome {
    case .started: formatter.formatCommandResult(.omemoSetupRetried(accountID: accountID))
    case .notConnected: formatter.formatError(CLIError.accountNotConnected)
    case .notNeeded: formatter.formatError(CLIError.omemoSetupNotIncomplete)
    }
}

/// The conversation `address` names: the private chat with the occupant `room@service/nick`, or the chat or room
/// with a bare address.
func namedConversation(_ address: String, context: REPLContext) async throws -> Conversation {
    guard let jid = JID.parse(address) else { throw CLIError.invalidJID(address) }
    guard let conversation = try await resolveConversation(jid: jid, environment: context.environment, accountID: context.accountID) else {
        throw CLIError.noConversation(address)
    }
    return conversation
}

func recentMessages(in conversation: Conversation, context: REPLContext) async throws -> [ChatMessage] {
    try await context.environment.chatService.fetchMessageHistory(for: conversation.id, before: nil, limit: 10)
}

private func lastOutgoingMessage(in conversation: Conversation, context: REPLContext) async throws -> ChatMessage? {
    try await recentMessages(in: conversation, context: context)
        .last { $0.isOutgoing && $0.stanzaID != nil && !$0.isRetracted }
}
