import DuckoCore
import DuckoXMPP
import Foundation

/// `directly` sends the file straight to one of the contact's devices instead of uploading it. That needs a contact,
/// so the current room is never taken as the target, and every way of leaving the contact out gets the same usage line.
func handleSendFileREPLCommand(_ arguments: String, context: REPLContext, currentRoom: String?, directly: Bool = false) async {
    let directUsage = directly ? "Usage: /senddirect <jid> <path>" : nil
    guard !arguments.isEmpty else {
        print(context.formatter.formatUsageError(directUsage ?? "Usage: /sendfile [jid] <path>"))
        return
    }

    let jidString: String
    let filePath: String
    switch parseSendFileArgs(arguments, currentRoom: directly ? nil : currentRoom) {
    case let .send(target, path):
        jidString = target
        filePath = path
    case .missingPath:
        print(context.formatter.formatUsageError(directUsage ?? "Usage: /sendfile <jid> <path>"))
        return
    case .noTarget:
        print(directUsage.map(context.formatter.formatUsageError) ?? context.formatter.formatError(CLIError.noConversationTarget))
        return
    }

    guard let recipientJID = BareJID.parse(jidString) else {
        print(context.formatter.formatError(CLIError.invalidJID(jidString)))
        return
    }

    do {
        if directly {
            try await startDirectTransferFromREPL(filePath: filePath, recipientJID: recipientJID, context: context)
        } else {
            let ftContext = FileTransferCLIContext(
                accountID: context.accountID, environment: context.environment, formatter: context.formatter
            )
            try await sendFileFromCLI(filePath: filePath, recipientJID: recipientJID, body: nil, context: ftContext)
        }
    } catch {
        print(context.formatter.formatError(error))
    }
}

/// Returns once the file is on record as being sent. The transfer itself lasts until the contact has accepted and
/// received the file, and the prompt should not hang on someone else's answer.
private func startDirectTransferFromREPL(filePath: String, recipientJID: BareJID, context: REPLContext) async throws {
    let fileURL = URL(fileURLWithPath: filePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        throw CLIError.fileNotFound(filePath)
    }
    let (env, accountID, jidString) = (context.environment, context.accountID, recipientJID.description)
    // The contact's devices are asked first. Once the file is on record, a transfer that finds no device to go to
    // only shows in `/transfers` and the history.
    await env.fileTransferService.refreshDirectTransferSupport(forJIDString: jidString, accountID: accountID)
    guard await env.fileTransferService.canSendDirectly(toJIDString: jidString, accountID: accountID) else {
        throw FileTransferService.FileTransferError.directTransferUnavailable
    }
    let conversation = try await env.chatService.openConversation(for: recipientJID, accountID: accountID)
    try await env.fileTransferService.startDirectTransfer(url: fileURL, in: conversation, accountID: accountID)
    print(context.formatter.formatCommandResult(.directTransferStarted(fileName: fileURL.lastPathComponent, jid: jidString)))
}

/// Accepts the incoming file offer into Downloads, or declines it.
func handleOfferREPLCommand(_ arguments: String, context: REPLContext, declining: Bool) async {
    guard !declining else {
        await handleFileTransferREPLCommand(
            arguments, context: context,
            confirmation: { .transferDeclined(offerID: $0) },
            action: { offerID, accountID in
                try await context.environment.fileTransferService.declineIncomingTransfer(offerID, accountID: accountID)
            }
        )
        return
    }
    // `downloadsDirectory` is nonisolated, but reaching the service through `environment` is not.
    let downloadsPath = await MainActor.run { context.environment.fileTransferService.downloadsDirectory.path }
    await handleFileTransferREPLCommand(
        arguments, context: context,
        confirmation: { .transferAccepted(offerID: $0, directory: downloadsPath) },
        action: { offerID, accountID in
            try await context.environment.fileTransferService.acceptIncomingTransfer(offerID, accountID: accountID)
        }
    )
}

private func handleFileTransferREPLCommand(
    _ arguments: String, context: REPLContext,
    confirmation: (String) -> CLICommandResult,
    action: (String, UUID) async throws -> Void
) async {
    let offerID: String
    if arguments.isEmpty {
        // The same projection the GUI banner shows, so a link offer can be taken here too. The action runs on this
        // session's account, so the newest offer is taken from that account's.
        let latest = await MainActor.run {
            context.environment.fileTransferService.viewIncomingOffers.last { $0.accountID == context.accountID }?.offerID
        }
        guard let latest else {
            print(context.formatter.formatError(CLIError.noIncomingOffers))
            return
        }
        offerID = latest
    } else {
        offerID = arguments
    }
    do {
        try await action(offerID, context.accountID)
        print(context.formatter.formatCommandResult(confirmation(offerID)))
    } catch {
        print(context.formatter.formatError(error))
    }
}

/// Cancels the direct transfer whose session is `arguments`, or without one this account's newest direct transfer still
/// under way.
func handleCancelREPLCommand(_ arguments: String, context: REPLContext) async {
    let underway = await MainActor.run {
        context.environment.fileTransferService.activeTransfers.filter { $0.accountID == context.accountID && $0.isUnderwayDirectTransfer }
    }
    let transfer = arguments.isEmpty ? underway.last : underway.last { $0.sid == arguments }
    let notFound = arguments.isEmpty ? CLIError.noDirectTransfers : CLIError.transferNotFound(arguments)
    // The transfer can end between the lookup and the stop, which then stops nothing.
    guard let transfer, await context.environment.fileTransferService.cancelTransfer(id: transfer.id) else {
        print(context.formatter.formatError(notFound))
        return
    }
    print(context.formatter.formatCommandResult(.transferCanceled(fileName: transfer.fileName)))
}

func handleTransfersREPLCommand(context: REPLContext) async {
    let transfers = await MainActor.run { context.environment.fileTransferService.activeTransfers }
    if transfers.isEmpty {
        print(context.formatter.formatEmptyResult(.transfers))
        return
    }
    for transfer in transfers {
        print(context.formatter.formatTransfer(transfer))
    }
}

func handleSaveFileREPLCommand(_ address: String, context: REPLContext) async {
    await print(saveFileREPLLine(address, context: context))
}

/// What `/savefile` prints once it has decrypted the file a contact last shared in an encrypted message in the chat with
/// `address` and saved it to Downloads. As in the chat window, a link that arrived in a plaintext message is not opened,
/// and neither is one in a retracted message.
func saveFileREPLLine(_ address: String, context: REPLContext) async -> String {
    do {
        let conversation = try await namedConversation(address, context: context)
        guard let shared = try await lastSharedEncryptedFile(in: conversation, context: context) else {
            return context.formatter.formatError(CLIError.noEncryptedFile(address))
        }
        let service = await context.environment.fileTransferService
        let savedURL = try await service.saveEncryptedFile(shared.file, named: shared.name)
        return context.formatter.formatCommandResult(.encryptedFileSaved(path: savedURL.path))
    } catch {
        return context.formatter.formatError(error)
    }
}

/// How many of the chat's newest messages are searched at most for a shared file.
private let maxSavedFileSearchCount = 10240

/// The file a contact last shared in an encrypted message in `conversation`, with the name it is saved under. The newest
/// messages are read first, twice as many each round, until one shares a file or the chat has no more. Each round
/// reads from the newest message, so messages that share a second are never skipped at a page's edge.
private func lastSharedEncryptedFile(
    in conversation: Conversation, context: REPLContext
) async throws -> (file: EncryptedFileLink, name: String)? {
    var limit = 10
    while true {
        let messages = try await context.environment.chatService.fetchMessageHistory(for: conversation.id, before: nil, limit: limit)
        let shared = messages.lazy.filter { !$0.isOutgoing && $0.isEncrypted && !$0.isRetracted }.reversed().compactMap { message in
            message.attachments.lazy.reversed().compactMap { attachment in
                EncryptedFileLink(link: attachment.url).map { (file: $0, name: attachment.displayFileName) }
            }.first
        }.first
        if let shared { return shared }
        guard messages.count == limit, limit < maxSavedFileSearchCount else { return nil }
        limit = min(2 * limit, maxSavedFileSearchCount)
    }
}
