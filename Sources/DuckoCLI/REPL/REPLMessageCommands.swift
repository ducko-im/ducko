import DuckoCore
import DuckoXMPP
import Foundation

func handleSendCommand(_ arguments: String, context: REPLContext) async {
    let parts = arguments.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print("Usage: send <jid> <message>")
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
                print("Hint: send <room-jid> requires /join first; delivering as 1:1 message.")
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
        print(usage)
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
            print(usage)
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
        guard let original = try await lastOutgoingMessage(to: jidString, context: context), let stanzaID = original.stanzaID else {
            print("No recent outgoing message to retract.")
            return
        }
        if original.type == "groupchat" {
            try await context.environment.chatService.retractGroupMessage(
                original: original, inRoomJIDString: jidString,
                accountID: context.accountID
            )
        } else {
            try await context.environment.chatService.retractMessage(
                original: original, toJIDString: jidString,
                accountID: context.accountID
            )
        }
        print("Retracted message: \(stanzaID)")
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleEditREPLCommand(_ arguments: String, context: REPLContext) async {
    let parts = arguments.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print("Usage: /edit <jid> <new-body>")
        return
    }
    let jidString = String(parts[0])
    let newBody = String(parts[1])
    do {
        guard let original = try await lastOutgoingMessage(to: jidString, context: context), let stanzaID = original.stanzaID else {
            print("No recent outgoing message to edit.")
            return
        }
        if original.type == "groupchat" {
            try await context.environment.chatService.sendGroupCorrection(
                original: original, inRoomJIDString: jidString,
                newBody: newBody, accountID: context.accountID
            )
        } else {
            try await context.environment.chatService.sendCorrection(
                original: original, toJIDString: jidString,
                newBody: newBody, accountID: context.accountID
            )
        }
        print("Edited message: \(stanzaID)")
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleReplyREPLCommand(_ arguments: String, context: REPLContext) async {
    let parts = arguments.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print("Usage: /reply <jid> <message>")
        return
    }
    let jidString = String(parts[0])
    let body = String(parts[1])
    do {
        let messages = try await recentMessages(with: jidString, context: context)
        guard let lastIncoming = messages.last(where: { !$0.isOutgoing && $0.stanzaID != nil }),
              let replyStanzaID = lastIncoming.stanzaID
        else {
            print("No recent incoming message to reply to.")
            return
        }
        try await context.environment.chatService.sendReply(
            toJIDString: jidString, body: body,
            replyToStanzaID: replyStanzaID,
            accountID: context.accountID
        )
        print(context.formatter.formatMessage(ChatMessage.displayPlaceholder(
            fromJID: jidString, body: body, replyToID: replyStanzaID
        ), accountJID: context.accountJID))
    } catch {
        print(context.formatter.formatError(error))
    }
}

func handleSearchREPLCommand(_ arguments: String, context: REPLContext) async {
    let parts = arguments.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print("Usage: /search <jid> <query>")
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
func handlePrefREPLCommand(_ arguments: String) async {
    let parts = arguments.split(separator: " ", maxSplits: 1)
    let key = String(parts[0])
    let valueArg = parts.count == 2 ? String(parts[1]) : nil

    switch key {
    case "chatstates":
        togglePref(name: "Chat states", key: "chatstates", value: valueArg, get: { ChatPreferences.shared.enableChatStates }, set: { ChatPreferences.shared.enableChatStates = $0 })
    case "markers":
        togglePref(name: "Displayed markers", key: "markers", value: valueArg, get: { ChatPreferences.shared.enableDisplayedMarkers }, set: { ChatPreferences.shared.enableDisplayedMarkers = $0 })
    default:
        print("Unknown preference: \(key). Available: chatstates, markers")
    }
}

@MainActor
private func togglePref(name: String, key: String, value: String?, get: () -> Bool, set: (Bool) -> Void) {
    guard let value else {
        let current = get() ? "on" : "off"
        print("\(name): \(current)")
        return
    }
    switch value.lowercased() {
    case "on":
        set(true)
        print("\(name) enabled.")
    case "off":
        set(false)
        print("\(name) disabled.")
    default:
        print("Usage: /pref \(key) on|off")
    }
}

func handleEncryptREPLCommand(_ arguments: String, context: REPLContext) async {
    let parts = arguments.split(separator: " ", maxSplits: 1)
    guard parts.count == 2 else {
        print("Usage: /encrypt <jid> on|off")
        return
    }
    let jidString = String(parts[0])
    let toggle = String(parts[1]).lowercased()
    guard toggle == "on" || toggle == "off" else {
        print("Usage: /encrypt <jid> on|off")
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
        let state = enabled ? "enabled" : "disabled"
        print("Encryption \(state) for \(jidString).")
    } catch {
        print(context.formatter.formatError(error))
    }
}

private func recentMessages(with jidString: String, context: REPLContext) async throws -> [ChatMessage] {
    guard let bareJID = BareJID.parse(jidString) else { throw CLIError.invalidJID(jidString) }
    return try await fetchHistory(
        jid: bareJID, before: nil, limit: 10,
        environment: context.environment, accountID: context.accountID
    )
}

private func lastOutgoingMessage(to jidString: String, context: REPLContext) async throws -> ChatMessage? {
    try await recentMessages(with: jidString, context: context)
        .last { $0.isOutgoing && $0.stanzaID != nil && !$0.isRetracted }
}
