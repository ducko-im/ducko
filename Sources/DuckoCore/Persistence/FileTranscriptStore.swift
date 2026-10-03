import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.transcripts")

/// File-based transcript storage using append-only JSONL files, one per UTC date per conversation.
public actor FileTranscriptStore: TranscriptStore {
    private let baseDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileHandle: @Sendable (URL) throws -> FileHandle

    /// In-memory index mapping stanzaID → (conversationID, date string) for single-file lookups in findMessage/messageExists.
    private var stanzaIndex: [String: (UUID, String)] = [:]

    /// In-memory index mapping serverID → (conversationID, date string) for single-file lookups in findMessage/messageExists.
    private var serverIndex: [String: (UUID, String)] = [:]

    /// In-memory index of message UUID → (conversationID, date string). Authoritative
    /// for amendment routing; disambiguates per-session `ducko-N` counter collisions
    /// within a single per-day file.
    private var uuidIndex: [UUID: (UUID, String)] = [:]

    private static let newline = Data("\n".utf8)

    /// Creates a store using the default transcripts directory under `BuildEnvironment.appSupportDirectory`.
    public static func makeDefault() -> FileTranscriptStore {
        let dir = BuildEnvironment.appSupportDirectory.appendingPathComponent("Transcripts", isDirectory: true)
        return FileTranscriptStore(baseDirectory: dir)
    }

    public init(baseDirectory: URL) {
        self.init(baseDirectory: baseDirectory, openFileHandle: Self.openAppendFile)
    }

    init(baseDirectory: URL, openFileHandle: @escaping @Sendable (URL) throws -> FileHandle) {
        self.baseDirectory = baseDirectory
        self.fileHandle = openFileHandle
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - Write

    public func appendMessage(_ message: ChatMessage) async throws {
        let dateString = Self.dateString(for: message.timestamp)
        let fileURL = transcriptFileURL(conversationID: message.conversationID, dateString: dateString)
        let record = TranscriptRecord.from(message)
        try appendRecord(record, to: fileURL, conversationID: message.conversationID)
        indexEntry(id: message.id, stanzaID: message.stanzaID, serverID: message.serverID, conversationID: message.conversationID, dateString: dateString)
    }

    public func appendMessages(_ messages: [ChatMessage]) async throws {
        guard !messages.isEmpty else { return }

        // Group by (conversationID, date) to minimize file opens
        var grouped: [(key: (UUID, String), messages: [ChatMessage])] = []
        var groupMap: [String: Int] = [:]
        for message in messages {
            let dateString = Self.dateString(for: message.timestamp)
            let key = "\(message.conversationID)|\(dateString)"
            if let index = groupMap[key] {
                grouped[index].messages.append(message)
            } else {
                groupMap[key] = grouped.count
                grouped.append((key: (message.conversationID, dateString), messages: [message]))
            }
        }

        for group in grouped {
            let fileURL = transcriptFileURL(conversationID: group.key.0, dateString: group.key.1)
            try ensureDirectoryExists(for: group.key.0)
            let handle = try fileHandle(fileURL)
            defer { try? handle.close() }

            for message in group.messages {
                let record = TranscriptRecord.from(message)
                try writeRecord(record, to: handle)
                indexEntry(id: message.id, stanzaID: message.stanzaID, serverID: message.serverID, conversationID: group.key.0, dateString: group.key.1)
            }
        }
    }

    public func appendAmendment(_ amendment: TranscriptAmendment, conversationID: UUID) async throws {
        // Amendments must land in the SAME daily file as the target message because
        // applyAmendments runs per-file. If the amendment's date differs from the
        // message's date, the per-file stanzaToID map won't resolve the target and
        // the amendment is silently dropped. Resolve via the in-memory index first
        // (verifying the conversationID matches to reject cross-conversation
        // stanzaID collisions), then scan this conversation's files. Fail closed
        // if the target cannot be located — writing to an arbitrary date file
        // would leave a dangling amendment record that may later attach to an
        // unrelated message with a colliding stanzaID.
        guard let dateString = resolveAmendmentDate(amendment: amendment, conversationID: conversationID) else {
            // Privacy policy: identifiers only at debug. Warning carries
            // action so missing-target rates stay observable.
            log.warning("Amendment target not found (action=\(amendment.action.rawValue))")
            log.debug("Amendment target not found in conversation \(conversationID): messageID=\(amendment.targetMessageID?.uuidString ?? "nil") stanzaID=\(amendment.targetStanzaID ?? "nil") serverID=\(amendment.targetServerID ?? "nil")")
            return
        }
        let fileURL = transcriptFileURL(conversationID: conversationID, dateString: dateString)
        let record = TranscriptRecord.from(amendment)
        try appendRecord(record, to: fileURL, conversationID: conversationID)
    }

    public func appendNote(_ note: TimelineNote) async throws {
        let fileURL = transcriptFileURL(conversationID: note.conversationID, dateString: Self.dateString(for: note.timestamp))
        try appendRecord(TranscriptRecord.from(note), to: fileURL, conversationID: note.conversationID)
    }

    /// Locates the date file containing the amendment's target message within `conversationID`.
    /// Returns nil if the target cannot be found in the indexes or by scanning the conversation's files.
    private func resolveAmendmentDate(amendment: TranscriptAmendment, conversationID: UUID) -> String? {
        // UUID is authoritative — never fall through to stanzaID/serverID,
        // which can collide on `ducko-N` and leave a dangling record in
        // the wrong file.
        if amendment.targetMessageID != nil {
            if let date = scopedDate(uuidIndex, key: amendment.targetMessageID, conversationID: conversationID) { return date }
            return scanConversationForTarget(amendment: amendment, conversationID: conversationID)
        }
        if let date = scopedDate(stanzaIndex, key: amendment.targetStanzaID, conversationID: conversationID) { return date }
        if let date = scopedDate(serverIndex, key: amendment.targetServerID, conversationID: conversationID) { return date }
        return scanConversationForTarget(amendment: amendment, conversationID: conversationID)
    }

    /// Returns the indexed date only when the entry is scoped to `conversationID`.
    /// Filters cross-conversation collisions so the caller falls through to a
    /// per-conversation scan.
    private func scopedDate<K: Hashable>(_ index: [K: (UUID, String)], key: K?, conversationID: UUID) -> String? {
        guard let key, let (indexedConv, date) = index[key], indexedConv == conversationID else { return nil }
        return date
    }

    /// Scans the given conversation's transcript files for the amendment's target message.
    /// Populates the in-memory indexes for any matching message found. Newest files first.
    private func scanConversationForTarget(amendment: TranscriptAmendment, conversationID: UUID) -> String? {
        guard let dateFiles = try? listDateFiles(for: conversationID) else { return nil }
        for (dateString, fileURL) in dateFiles {
            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { continue }
            let lines = data.split(separator: UInt8(ascii: "\n"))
            for line in lines {
                guard !line.isEmpty,
                      let record = try? decoder.decode(TranscriptRecord.self, from: Data(line)),
                      case let .message(entry) = record
                else { continue }
                if amendmentMatches(amendment, entry: entry) {
                    indexEntry(id: entry.id, stanzaID: entry.stanzaID, serverID: entry.serverID, conversationID: conversationID, dateString: dateString)
                    return dateString
                }
            }
        }
        return nil
    }

    /// Returns true when `entry` matches the amendment's target.
    /// UUID is authoritative when present; no fallback to stanzaID/serverID.
    private func amendmentMatches(_ amendment: TranscriptAmendment, entry: TranscriptRecord.MessageEntry) -> Bool {
        if let uuid = amendment.targetMessageID { return entry.id == uuid }
        if let sid = amendment.targetStanzaID { return entry.stanzaID == sid }
        if let srvid = amendment.targetServerID { return entry.serverID == srvid }
        return false
    }

    /// Populates the uuid/stanza/server indexes for a single message;
    /// shared by write, scan, and read paths.
    private func indexEntry(id: UUID, stanzaID: String?, serverID: String?, conversationID: UUID, dateString: String) {
        uuidIndex[id] = (conversationID, dateString)
        if let stanzaID {
            stanzaIndex[stanzaID] = (conversationID, dateString)
        }
        if let serverID {
            serverIndex[serverID] = (conversationID, dateString)
        }
    }

    // MARK: - Read

    public func fetchMessages(for conversationID: UUID, before: Date?, limit: Int) async throws -> [ChatMessage] {
        let dateFiles = try listDateFiles(for: conversationID)
        var result: [ChatMessage] = []

        for (dateString, fileURL) in dateFiles {
            // Skip files that are entirely after the `before` cutoff
            if let before, let fileDate = Self.parseDate(dateString), fileDate > before {
                continue
            }

            let messages = try readAndMaterialize(fileURL: fileURL, conversationID: conversationID)
            let filtered: [ChatMessage] = if let before {
                messages.filter { $0.timestamp < before }
            } else {
                messages
            }

            result.append(contentsOf: filtered)
            if result.count >= limit { break }
        }

        // Newest first. Timestamps are stored to the second, so messages written within one second tie, and among
        // those the one written later is the newer.
        let newestFirst = result.enumerated().sorted { lhs, rhs in
            lhs.element.timestamp == rhs.element.timestamp ? lhs.offset > rhs.offset : lhs.element.timestamp > rhs.element.timestamp
        }
        return newestFirst.prefix(limit).map(\.element)
    }

    public func fetchMessages(for conversationID: UUID, on date: Date) async throws -> [ChatMessage] {
        let dateStr = Self.dateString(for: date)
        let fileURL = transcriptFileURL(conversationID: conversationID, dateString: dateStr)
        return try readAndMaterialize(fileURL: fileURL, conversationID: conversationID)
    }

    public func fetchNotes(for conversationID: UUID, since: Date?, before: Date?) async throws -> [TimelineNote] {
        // A note lives in the file of its own day, so a file is skipped when its whole day lies outside the bounds.
        let sinceDay = since.map(Self.dateString(for:))
        let beforeDay = before.map(Self.dateString(for:))
        var result: [TimelineNote] = []
        for (dateString, fileURL) in try listDateFiles(for: conversationID) {
            if let sinceDay, dateString < sinceDay { continue }
            if let beforeDay, dateString > beforeDay { continue }
            result.append(contentsOf: readNotes(fileURL: fileURL, conversationID: conversationID).filter { note in
                if let since, note.timestamp < since { return false }
                if let before, note.timestamp >= before { return false }
                return true
            })
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Lookup

    public func findMessage(id: UUID, conversationID: UUID) async throws -> ChatMessage? {
        // Fast path: uuid index points at the file containing this message.
        if let (indexedConv, dateString) = uuidIndex[id], indexedConv == conversationID {
            let fileURL = transcriptFileURL(conversationID: conversationID, dateString: dateString)
            let messages = try readAndMaterialize(fileURL: fileURL, conversationID: conversationID)
            if let match = messages.first(where: { $0.id == id }) {
                return match
            }
        }
        // Slow path: scan all date files for the matching UUID.
        return try findMessage(in: conversationID) { $0.id == id }
    }

    public func findMessage(stanzaID: String, conversationID: UUID) async throws -> ChatMessage? {
        // Fast path: check stanza index to read only one file. Verify the indexed
        // conversationID matches — stanzaIDs can collide across conversations and
        // last-write-wins would otherwise probe the wrong conversation's file.
        if let (indexedConv, dateString) = stanzaIndex[stanzaID], indexedConv == conversationID {
            let fileURL = transcriptFileURL(conversationID: conversationID, dateString: dateString)
            let messages = try readAndMaterialize(fileURL: fileURL, conversationID: conversationID)
            if let match = messages.first(where: { $0.stanzaID == stanzaID }) {
                return match
            }
        }
        // Slow path: scan all date files
        return try findMessage(in: conversationID) { $0.stanzaID == stanzaID }
    }

    public func findMessages(stanzaID: String, conversationID: UUID) async throws -> [ChatMessage] {
        // Full multi-file scan, not the `stanzaIndex` fast path: that index is single-valued
        // (last-write-wins per stanzaID), so a colliding `ducko-N` would surface only the most
        // recently written file and miss cross-file duplicates — the exact case callers need.
        let dateFiles = try listDateFiles(for: conversationID)
        var matches: [ChatMessage] = []
        for (_, fileURL) in dateFiles {
            let messages = try readAndMaterialize(fileURL: fileURL, conversationID: conversationID)
            matches.append(contentsOf: messages.filter { $0.stanzaID == stanzaID })
        }
        return matches
    }

    public func findMessage(serverID: String, conversationID: UUID) async throws -> ChatMessage? {
        // Fast path: check server index to read only one file. Verify the indexed
        // conversationID matches for consistency with findMessage(stanzaID:).
        if let (indexedConv, dateString) = serverIndex[serverID], indexedConv == conversationID {
            let fileURL = transcriptFileURL(conversationID: conversationID, dateString: dateString)
            let messages = try readAndMaterialize(fileURL: fileURL, conversationID: conversationID)
            if let match = messages.first(where: { $0.serverID == serverID }) {
                return match
            }
        }
        // Slow path: scan all date files
        return try findMessage(in: conversationID) { $0.serverID == serverID }
    }

    public func messageExists(stanzaID: String, conversationID: UUID) async throws -> Bool {
        try await findMessage(stanzaID: stanzaID, conversationID: conversationID) != nil
    }

    public func messageExists(serverID: String, conversationID: UUID) async throws -> Bool {
        try await findMessage(serverID: serverID, conversationID: conversationID) != nil
    }

    public func messageExists(stanzaID: String, fromJID: String, conversationID: UUID) async throws -> Bool {
        // Inbound-only dedup: outgoing 1:1 rows persist `fromJID` as the RECIPIENT (so carbons can find them), so
        // omitting `!isOutgoing` would let an inbound from bob alias an outgoing alice→bob row and be dropped.
        // Stanza index is 1:1 (last-write-wins) so falls through to per-file scan when it points at the wrong sender.
        let predicate: (ChatMessage) -> Bool = { msg in
            !msg.isOutgoing && msg.stanzaID == stanzaID && msg.fromJID == fromJID
        }
        if let (indexedConv, dateString) = stanzaIndex[stanzaID], indexedConv == conversationID {
            let fileURL = transcriptFileURL(conversationID: conversationID, dateString: dateString)
            let messages = try readAndMaterialize(fileURL: fileURL, conversationID: conversationID)
            if messages.contains(where: predicate) {
                return true
            }
        }
        return try findMessage(in: conversationID, where: predicate) != nil
    }

    // MARK: - Search

    public func searchMessages(
        query: String, conversationID: UUID?,
        before: Date?, after: Date?, limit: Int
    ) async throws -> [ChatMessage] {
        let conversationIDs: [UUID] = if let conversationID {
            [conversationID]
        } else {
            try listConversationIDs()
        }

        var results: [ChatMessage] = []
        for convID in conversationIDs {
            let dateFiles = try listDateFiles(for: convID)
            for (dateString, fileURL) in dateFiles {
                // Skip files outside the date bounds
                if let before, let fileDate = Self.parseDate(dateString), fileDate > before { continue }
                if let after, let fileDate = Self.parseDate(dateString) {
                    // File date is the start of the day; skip if the entire next day is before `after`
                    if let nextDay = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: fileDate),
                       nextDay <= after { continue }
                }
                let messages = try readAndMaterialize(fileURL: fileURL, conversationID: convID)
                let filtered = messages.filter { msg in
                    if let before, msg.timestamp >= before { return false }
                    if let after, msg.timestamp <= after { return false }
                    return msg.body.localizedStandardContains(query)
                }
                results.append(contentsOf: filtered)
                if results.count >= limit { break }
            }
            if results.count >= limit { break }
        }

        results.sort { $0.timestamp > $1.timestamp }
        return Array(results.prefix(limit))
    }

    // MARK: - Stats

    public func messageDateCounts(for conversationID: UUID) async throws -> [(date: Date, count: Int)] {
        let dateFiles = try listDateFiles(for: conversationID)
        return try dateFiles.compactMap { dateString, fileURL in
            guard let date = Self.parseDate(dateString) else { return nil }
            let messages = try readAndMaterialize(fileURL: fileURL, conversationID: conversationID)
            return (date, messages.count)
        }
    }

    // MARK: - Lifecycle

    public func deleteTranscripts(for conversationID: UUID) async throws {
        let dir = conversationDirectory(for: conversationID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        stanzaIndex = stanzaIndex.filter { $0.value.0 != conversationID }
        serverIndex = serverIndex.filter { $0.value.0 != conversationID }
        uuidIndex = uuidIndex.filter { $0.value.0 != conversationID }
    }

    public func writeMetadata(_ metadata: TranscriptMetadata, for conversationID: UUID) async throws {
        try ensureDirectoryExists(for: conversationID)
        let metaURL = conversationDirectory(for: conversationID).appendingPathComponent("meta.json")
        let metaEncoder = JSONEncoder()
        metaEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try metaEncoder.encode(metadata)
        try data.write(to: metaURL, options: .atomic)
    }

    private func conversationDirectory(for conversationID: UUID) -> URL {
        baseDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }

    private func transcriptFileURL(conversationID: UUID, dateString: String) -> URL {
        conversationDirectory(for: conversationID).appendingPathComponent("\(dateString).jsonl")
    }

    static func dateString(for date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: .gmt, from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    private static func parseDate(_ dateString: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = dateString.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private func ensureDirectoryExists(for conversationID: UUID) throws {
        let dir = conversationDirectory(for: conversationID)
        try FileManager.default.createOwnerOnlyDirectory(at: dir)
    }

    private static func openAppendFile(_ fileURL: URL) throws -> FileHandle {
        let path = fileURL.path
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else {
            let posixError = POSIXError(.init(rawValue: errno) ?? .ENOENT)
            throw CocoaError(.fileWriteUnknown, userInfo: [
                NSFilePathErrorKey: path,
                NSUnderlyingErrorKey: posixError
            ])
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func appendRecord(_ record: TranscriptRecord, to fileURL: URL, conversationID: UUID) throws {
        try ensureDirectoryExists(for: conversationID)
        let handle = try fileHandle(fileURL)
        defer { try? handle.close() }
        try writeRecord(record, to: handle)
    }

    private func writeRecord(_ record: TranscriptRecord, to handle: FileHandle) throws {
        var data = try encoder.encode(record)
        data.append(Self.newline)
        try handle.write(contentsOf: data)
    }

    /// Walks date files newest-first and returns the first message matching the predicate.
    private func findMessage(
        in conversationID: UUID, where predicate: (ChatMessage) -> Bool
    ) throws -> ChatMessage? {
        let dateFiles = try listDateFiles(for: conversationID)
        for (_, fileURL) in dateFiles {
            let messages = try readAndMaterialize(fileURL: fileURL, conversationID: conversationID)
            if let match = messages.first(where: predicate) {
                return match
            }
        }
        return nil
    }

    /// Lists date files for a conversation, sorted newest first.
    private func listDateFiles(for conversationID: UUID) throws -> [(dateString: String, url: URL)] {
        let dir = conversationDirectory(for: conversationID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return contents
            .filter { $0.pathExtension == "jsonl" }
            .map { (dateString: $0.deletingPathExtension().lastPathComponent, url: $0) }
            .sorted { $0.dateString > $1.dateString } // newest first
    }

    private func listConversationIDs() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: baseDirectory.path) else { return [] }
        let contents = try FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)
        return contents.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    private func readAndMaterialize(fileURL: URL, conversationID: UUID) throws -> [ChatMessage] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }

        var accumulator = MaterializationAccumulator()
        var amendments: [TranscriptAmendment] = []
        let dateString = fileURL.deletingPathExtension().lastPathComponent

        let lines = data.split(separator: UInt8(ascii: "\n"))
        for line in lines {
            guard !line.isEmpty else { continue }
            do {
                let record = try decoder.decode(TranscriptRecord.self, from: Data(line))
                switch record {
                case .message:
                    ingestMessageRecord(record, conversationID: conversationID, dateString: dateString, into: &accumulator)
                case .amendment:
                    if let amendment = record.toAmendment() {
                        amendments.append(amendment)
                    }
                case .note:
                    break
                }
            } catch {
                log.debug("Skipping malformed transcript line: \(error)")
            }
        }

        applyAmendments(amendments, to: &accumulator.messages, stanzaToID: accumulator.stanzaToID, serverToID: accumulator.serverToID)
        return accumulator.order.compactMap { accumulator.messages[$0] }
    }

    private func readNotes(fileURL: URL, conversationID: UUID) -> [TimelineNote] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        // The substring check skips the JSON decode for the message and amendment lines that make up nearly every file.
        let marker = Data(#""type":"note""#.utf8)
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard line.firstRange(of: marker) != nil else { return nil }
            return try? decoder.decode(TranscriptRecord.self, from: Data(line)).toNote(conversationID: conversationID)
        }
    }

    /// Per-file materialization state. `order` preserves insertion order (the dict
    /// does not); the stanza/server-ID maps route amendments back to their messages.
    private struct MaterializationAccumulator {
        var messages: [UUID: ChatMessage] = [:]
        var order: [UUID] = []
        var stanzaToID: [String: UUID] = [:]
        var serverToID: [String: UUID] = [:]
    }

    private func ingestMessageRecord(
        _ record: TranscriptRecord,
        conversationID: UUID,
        dateString: String,
        into accumulator: inout MaterializationAccumulator
    ) {
        guard var msg = record.toChatMessage(conversationID: conversationID) else { return }
        msg.isDelivered = !msg.isOutgoing
        accumulator.messages[msg.id] = msg
        accumulator.order.append(msg.id)
        indexEntry(id: msg.id, stanzaID: msg.stanzaID, serverID: msg.serverID, conversationID: conversationID, dateString: dateString)
        if let sid = msg.stanzaID { accumulator.stanzaToID[sid] = msg.id }
        if let srvid = msg.serverID { accumulator.serverToID[srvid] = msg.id }
    }

    /// Applies amendment records to a mutable message dictionary.
    private func applyAmendments(
        _ amendments: [TranscriptAmendment],
        to messages: inout [UUID: ChatMessage],
        stanzaToID: [String: UUID],
        serverToID: [String: UUID]
    ) {
        for amendment in amendments {
            // UUID-bearing amendments fail closed: stanzaID/serverID fallback
            // would re-introduce the `ducko-N` collision risk this field
            // exists to prevent. Amendments without a UUID still resolve via
            // stanzaID/serverID: chat markers in a room or a private chat with one
            // of its occupants, moderation, and the receipts, markers and errors
            // stored before those named the message.
            let targetID: UUID? = if let uuid = amendment.targetMessageID {
                messages[uuid] != nil ? uuid : nil
            } else if let sid = amendment.targetStanzaID {
                stanzaToID[sid]
            } else if let srvid = amendment.targetServerID {
                serverToID[srvid]
            } else {
                nil
            }
            guard let targetID, var msg = messages[targetID] else { continue }

            switch amendment.action {
            case .edit:
                if let body = amendment.body {
                    msg.body = body
                    msg.htmlBody = amendment.htmlBody
                    msg.isEdited = true
                    msg.editedAt = amendment.timestamp
                }
            case .retract:
                msg.isRetracted = true
                msg.retractedAt = amendment.timestamp
                msg.body = ""
                msg.htmlBody = nil
            case .delivery:
                msg.isDelivered = true
            case .displayed:
                msg.isDelivered = true
                msg.isDisplayed = true
            case .error:
                msg.errorText = amendment.errorText
            }

            messages[targetID] = msg
        }
    }
}
