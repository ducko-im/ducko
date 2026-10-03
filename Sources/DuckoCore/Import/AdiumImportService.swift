import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.import")

/// Orchestrates importing Adium chat logs into Ducko's transcript store.
public actor AdiumImportService {
    private let store: any PersistenceStore
    private let transcripts: any TranscriptStore

    public init(store: any PersistenceStore, transcripts: any TranscriptStore) {
        self.store = store
        self.transcripts = transcripts
    }

    // MARK: - Progress

    public struct ImportProgress: Sendable {
        public var totalFiles: Int
        public var completedFiles: Int
        public var importedMessages: Int
        public var skippedDuplicates: Int
        public var errors: [ImportError]

        public init(totalFiles: Int, completedFiles: Int, importedMessages: Int, skippedDuplicates: Int, errors: [ImportError]) {
            self.totalFiles = totalFiles
            self.completedFiles = completedFiles
            self.importedMessages = importedMessages
            self.skippedDuplicates = skippedDuplicates
            self.errors = errors
        }

        public static func failure(error: any Error) -> ImportProgress {
            ImportProgress(
                totalFiles: 0,
                completedFiles: 0,
                importedMessages: 0,
                skippedDuplicates: 0,
                errors: [ImportError(file: "", message: error.localizedDescription)]
            )
        }
    }

    public struct ImportError: Sendable {
        public let file: String
        public let message: String

        /// The log file or contact folder name rather than the full Adium path, followed by the message.
        public var displayText: String {
            file.isEmpty ? message : "\(URL(fileURLWithPath: file).lastPathComponent): \(message)"
        }

        public init(file: String, message: String) {
            self.file = file
            self.message = message
        }
    }

    // MARK: - Import

    private struct ContactContext {
        let contactDir: URL
        let contactUID: String
        let source: AdiumServiceAccount
        let logFiles: [URL]
        let existingAccounts: [Account]
        let contactJID: String
        let accountJID: String
    }

    private struct ContactImportState {
        var conversation: Conversation?
        var knownStanzaIDs: Set<String> = []
        var latestMessage: ChatMessage?
    }

    private enum FileImportOutcome {
        case processed
        /// The contact's JID is invalid — skip its remaining files.
        case skipContact
    }

    public func importLogs(
        from sources: [AdiumServiceAccount],
        progress: @Sendable (ImportProgress) -> Void
    ) async throws -> ImportProgress {
        let totalFiles = sources.reduce(0) { $0 + $1.fileCount }
        var result = ImportProgress(
            totalFiles: totalFiles,
            completedFiles: 0,
            importedMessages: 0,
            skippedDuplicates: 0,
            errors: []
        )

        let existingAccounts = try await store.fetchAccounts()

        for source in sources {
            for contactDir in source.contactDirectories {
                try await importContact(contactDir: contactDir, source: source, existingAccounts: existingAccounts, result: &result, progress: progress)
            }
        }

        progress(result)
        log.info("Import complete: \(result.importedMessages) messages imported, \(result.skippedDuplicates) duplicates skipped, \(result.errors.count) errors")
        return result
    }

    private func importContact(
        contactDir: URL,
        source: AdiumServiceAccount,
        existingAccounts: [Account],
        result: inout ImportProgress,
        progress: @Sendable (ImportProgress) -> Void
    ) async throws {
        let logFiles: [URL]
        do {
            logFiles = try AdiumLogDiscovery.logFileURLs(in: contactDir)
        } catch {
            log.warning("Failed to enumerate logs in \(contactDir.path): \(error)")
            return
        }

        let contactUID = contactDir.lastPathComponent
        let context = ContactContext(
            contactDir: contactDir,
            contactUID: contactUID,
            source: source,
            logFiles: logFiles,
            existingAccounts: existingAccounts,
            contactJID: syntheticJID(identifier: contactUID, service: source.service),
            accountJID: syntheticJID(identifier: source.accountUID, service: source.service)
        )
        var state = ContactImportState()

        for fileURL in logFiles {
            try Task.checkCancellation()
            do {
                if try await importLogFile(fileURL, context: context, state: &state, result: &result) == .skipContact {
                    break
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.errors.append(ImportError(file: fileURL.path, message: error.localizedDescription))
                log.warning("Failed to import \(fileURL.lastPathComponent): \(error)")
            }

            result.completedFiles += 1
            if result.completedFiles % 50 == 0 {
                progress(result)
            }
        }

        try await updateConversationMetadata(state: state)
    }

    private func importLogFile(
        _ fileURL: URL,
        context: ContactContext,
        state: inout ContactImportState,
        result: inout ImportProgress
    ) async throws -> FileImportOutcome {
        let parsed = try parseLogFile(at: fileURL, accountUID: context.source.accountUID)
        guard !parsed.entries.isEmpty else { return .processed }

        // The conversation is resolved lazily from the first non-empty file.
        if state.conversation == nil {
            guard let resolved = try await resolveConversation(context: context, entries: parsed.entries) else {
                log.warning("Skipped \(context.logFiles.count) log files of a \(context.source.service) contact whose identifier is not a valid JID")
                log.debug("Invalid synthetic JID: \(context.contactJID)")
                result.errors.append(ImportError(file: context.contactDir.path, message: "\(context.source.service) identifier is not a valid JID"))
                result.completedFiles += context.logFiles.count
                return .skipContact
            }
            state.conversation = resolved.conversation
            state.knownStanzaIDs = resolved.knownStanzaIDs
        }

        guard let conv = state.conversation else { return .processed }

        // Also write metadata on re-import: a resolved conversation with no stored messages has none yet.
        if result.completedFiles == 0 || state.knownStanzaIDs.isEmpty {
            try await writeContactMetadata(conversation: conv, context: context)
        }

        let messages = buildMessages(from: parsed, conversation: conv, source: context.source)
        try await appendNewMessages(messages, state: &state, result: &result)
        return .processed
    }

    /// Returns `nil` when the contact's synthetic JID is invalid.
    private func resolveConversation(
        context: ContactContext,
        entries: [AdiumLogEntry]
    ) async throws -> (conversation: Conversation, knownStanzaIDs: Set<String>)? {
        let isGroupchat = detectGroupchat(entries: entries, accountUID: context.source.accountUID)
        let chatType: Conversation.ConversationType = isGroupchat ? .groupchat : .chat
        let matchingAccount = context.existingAccounts.first { $0.jid.description == context.accountJID }

        let lookupAccountID = matchingAccount?.id
        let lookupImportSourceJID: String? = matchingAccount == nil ? context.accountJID : nil

        if let existing = try await store.fetchConversation(jid: context.contactJID, type: chatType, accountID: lookupAccountID, importSourceJID: lookupImportSourceJID) {
            // Seed stanzaID cache so a re-import dedups against already-stored messages.
            let existingMessages = try await transcripts.fetchMessages(for: existing.id, before: nil, limit: Int.max)
            return (existing, Set(existingMessages.compactMap(\.stanzaID)))
        }

        guard let bareJID = BareJID.parse(context.contactJID) else { return nil }
        let conv = Conversation(
            id: UUID(),
            accountID: lookupAccountID,
            importSourceJID: lookupImportSourceJID,
            jid: bareJID,
            type: chatType,
            displayName: context.contactUID,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        )
        try await store.upsertConversation(conv)
        return (conv, [])
    }

    private func writeContactMetadata(conversation conv: Conversation, context: ContactContext) async throws {
        try await transcripts.writeMetadata(
            TranscriptMetadata(
                conversationID: conv.id,
                accountJID: context.accountJID,
                contactJID: context.contactJID,
                type: conv.type.rawValue,
                displayName: context.contactUID
            ),
            for: conv.id
        )
    }

    private func buildMessages(
        from parsed: AdiumLogFile,
        conversation conv: Conversation,
        source: AdiumServiceAccount
    ) -> [ChatMessage] {
        parsed.entries.enumerated().map { index, entry in
            let stanzaID = AdiumXMLLogParser.stanzaID(sourcePath: parsed.sourcePath, messageIndex: index)
            let isOutgoing = isOutgoingMessage(entry: entry, accountUID: source.accountUID)
            let fromJID: String = if conv.type == .groupchat, let slashIndex = entry.sender.firstIndex(of: "/") {
                String(entry.sender[entry.sender.index(after: slashIndex)...])
            } else {
                entry.sender
            }

            return ChatMessage(
                id: UUID(),
                conversationID: conv.id,
                stanzaID: stanzaID,
                fromJID: fromJID,
                body: entry.body,
                htmlBody: entry.htmlBody,
                timestamp: entry.timestamp,
                isOutgoing: isOutgoing,
                isDelivered: true,
                isEdited: false,
                type: conv.type.rawValue
            )
        }
    }

    private func appendNewMessages(
        _ messages: [ChatMessage],
        state: inout ContactImportState,
        result: inout ImportProgress
    ) async throws {
        let newMessages = messages.filter { msg in
            guard let sid = msg.stanzaID else { return true }
            return !state.knownStanzaIDs.contains(sid)
        }
        result.skippedDuplicates += messages.count - newMessages.count
        guard !newMessages.isEmpty else { return }

        try await transcripts.appendMessages(newMessages)
        result.importedMessages += newMessages.count

        for msg in newMessages {
            if let sid = msg.stanzaID {
                state.knownStanzaIDs.insert(sid)
            }
        }
        if let fileLatest = newMessages.max(by: { $0.timestamp < $1.timestamp }),
           fileLatest.timestamp > (state.latestMessage?.timestamp ?? .distantPast) {
            state.latestMessage = fileLatest
        }
    }

    private func updateConversationMetadata(state: ContactImportState) async throws {
        guard let conv = state.conversation, let latestMessage = state.latestMessage,
              latestMessage.timestamp > (conv.lastMessageDate ?? .distantPast) else { return }
        let (date, preview) = (latestMessage.timestamp, String(latestMessage.previewText.prefix(100)))
        try await store.updateConversation(conv.id) {
            $0.lastMessageDate = date
            $0.lastMessagePreview = preview
        }
    }

    private func parseLogFile(at url: URL, accountUID: String) throws -> AdiumLogFile {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()

        let entries: [AdiumLogEntry]
        switch ext {
        case "xml":
            entries = AdiumXMLLogParser.parse(data: data)
        case "html", "adiumhtmllog":
            let fileDate = AdiumHTMLLogParser.dateFromFilename(url.lastPathComponent) ?? Date()
            entries = AdiumHTMLLogParser.parse(data: data, fileDate: fileDate, accountUID: accountUID)
        default:
            entries = []
        }

        return AdiumLogFile(entries: entries, sourcePath: url.path)
    }

    private func detectGroupchat(entries: [AdiumLogEntry], accountUID _: String) -> Bool {
        // MUC messages have sender format "room@conference/nickname"
        entries.contains { entry in
            guard entry.sender.contains("/") else { return false }
            let parts = entry.sender.split(separator: "/", maxSplits: 1)
            return parts.count == 2 && parts[0].contains("@")
        }
    }

    private func isOutgoingMessage(entry: AdiumLogEntry, accountUID: String) -> Bool {
        // For XMPP: sender matches account JID
        // For MUC: sender resource matches account nickname (approximation)
        if entry.sender == accountUID { return true }
        if entry.sender.hasPrefix(accountUID) { return true }
        // For MUC, check if alias matches account (Adium often uses account UID as alias)
        if let alias = entry.alias, alias == accountUID { return true }
        return false
    }

    func syntheticJID(identifier: String, service: String) -> String {
        let normalizedService = service.lowercased()
        // Jabber and GTalk accounts already have valid JIDs
        switch normalizedService {
        case "jabber", "gtalk":
            return identifier
        default:
            // Identifiers like MSN addresses or Facebook's `-123@chat.facebook.com` contain `@` and spaces.
            return "\(BareJID.escapeLocalpart(identifier))@\(normalizedService).adium-import"
        }
    }
}
