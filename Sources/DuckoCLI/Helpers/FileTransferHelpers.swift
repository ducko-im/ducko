import DuckoCore
import DuckoXMPP
import Foundation

struct FileTransferCLIContext {
    let accountID: UUID
    let environment: AppEnvironment
    let formatter: any CLIFormatter
}

/// `auto`, the default, uploads: a direct transfer is only ever the sender's explicit choice.
func parseTransferMethod(_ string: String?) throws -> FileTransferService.TransferMethod {
    guard let string else { return .httpUpload }
    switch string.lowercased() {
    case "auto", "http":
        return .httpUpload
    case "jingle":
        return .jingle
    default:
        throw CLIError.invalidTransferMethod(string)
    }
}

func sendFileFromCLI(
    filePath: String, recipientJID: BareJID,
    body: String?, method: FileTransferService.TransferMethod = .httpUpload,
    peerJID: String? = nil, context: FileTransferCLIContext
) async throws {
    let fileURL = URL(fileURLWithPath: filePath)
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else {
        throw CLIError.fileNotFound(filePath)
    }
    let fileSize = (attributes[.size] as? Int64) ?? 0
    let fileName = fileURL.lastPathComponent

    let env = context.environment
    let conversation = try await env.chatService.openConversation(for: recipientJID, accountID: context.accountID)
    let downloadURL = try await env.fileTransferService.sendFile(
        url: fileURL, in: conversation, accountID: context.accountID,
        method: method, peerJID: peerJID
    ) { progress in
        printTransferProgress(fileName: fileName, fileSize: fileSize, progress: progress, formatter: context.formatter)
    }

    finishTransferProgress(formatter: context.formatter)
    print(context.formatter.formatFileMessage(fileName: fileName, url: downloadURL, fileSize: fileSize))

    if let body, !body.isEmpty {
        if conversation.type == .groupchat {
            try await env.chatService.sendGroupMessage(to: recipientJID, body: body, accountID: context.accountID)
        } else {
            try await env.chatService.sendMessage(to: recipientJID, body: body, accountID: context.accountID)
        }
    }
}

func printTransferProgress(fileName: String, fileSize: Int64, progress: Double, formatter: any CLIFormatter) {
    let output = formatter.formatTransferProgress(fileName: fileName, fileSize: fileSize, progress: progress)
    if formatter is ANSIFormatter {
        print(output, terminator: "")
        fflush(stdout)
    } else {
        print(output)
    }
}

func finishTransferProgress(formatter: any CLIFormatter) {
    if formatter is ANSIFormatter {
        print() // newline after carriage-return progress bar
    }
}

enum SendFileTarget: Equatable {
    case send(jidString: String, filePath: String)
    case missingPath
    case noTarget
}

/// Resolves a non-empty `/sendfile` argument into a send target. A leading
/// `localpart@domain` token (a bare JID addressing a user or room) selects that
/// recipient explicitly; a lone such JID means the path is missing; anything else —
/// including a bare word or a filename like "photo.jpg" — is a path for `currentRoom`.
func parseSendFileArgs(_ args: String, currentRoom: String?) -> SendFileTarget {
    let parts = args.split(separator: " ", maxSplits: 1)
    if parts.count == 2, JIDValidation.isValidUserOrRoomJID(String(parts[0])) {
        return .send(jidString: String(parts[0]), filePath: String(parts[1]))
    }
    if parts.count == 1, JIDValidation.isValidUserOrRoomJID(args) {
        return .missingPath
    }
    guard let currentRoom else { return .noTarget }
    return .send(jidString: currentRoom, filePath: args)
}

func formatTransferState(_ state: FileTransferService.TransferState) -> String {
    switch state {
    case .requestingSlot: "requesting slot"
    case let .uploading(progress): "uploading \(Int(progress * 100))%"
    case let .completed(url): "completed (\(url))"
    case let .failed(reason): "error: \(reason)"
    case .negotiating: "negotiating"
    case .connectingTransport: "connecting"
    case let .transferring(progress): "transferring \(Int(progress * 100))%"
    case .awaitingAcceptance: "awaiting acceptance"
    case .completedTransfer: "completed"
    case let .received(fileURL): "saved to \(fileURL.path)"
    }
}
