import DuckoXMPP
import Foundation

extension FileTransferService {
    /// A file on its way to a contact directly, from the moment it has its row.
    struct DirectTransfer {
        /// The id of the file's row in the chat and of its transfer row, which is how the chat finds the live state
        /// of its row.
        let id: UUID
        let file: FileInfo
        let contact: BareJID
        let accountID: UUID

        /// The id of the file's offer, which its session's events carry from the moment the session exists.
        var offerID: String {
            id.uuidString
        }
    }

    /// Gives the file its row in the chat and its transfer row before anything about the transfer itself can fail, so
    /// every outcome has somewhere to show.
    func recordDirectTransfer(
        of file: FileInfo, in conversation: Conversation, accountID: UUID
    ) async throws -> DirectTransfer {
        guard conversation.isDirectChat, let chatService else {
            throw FileTransferError.directTransferUnavailable
        }
        let transferID = UUID()
        let attachment = Attachment.locallySaved(id: UUID(), fileURL: file.url, mimeType: file.mimeType, fileSize: file.size)
        let conversationID = try await chatService.recordSentFile(attachment, id: transferID, to: conversation.jid, accountID: accountID)
        directTransferConversations[transferID] = conversationID
        let transfer = DirectTransfer(id: transferID, file: file, contact: conversation.jid, accountID: accountID)
        activeTransfers.append(ActiveTransfer(
            id: transferID, accountID: accountID, fileName: file.name, fileSize: file.size,
            state: .negotiating, method: .jingle, direction: .outgoing, offerID: transfer.offerID
        ))
        return transfer
    }

    func runDirectTransfer(_ transfer: DirectTransfer, peer: String?) async throws {
        let (transferID, file, accountID, offerID) = (transfer.id, transfer.file, transfer.accountID, transfer.offerID)
        var hasSession = false
        do {
            let peerJID = try await directTransferPeer(named: peer, for: transfer.contact, accountID: accountID)
            let jingleModule = try await jingleModule(for: accountID)
            try await stopIfEnded(transfer, sid: nil, jingleModule: jingleModule)
            let snapshot = try await Self.prepareSnapshot(of: file.url)
            defer { try? FileManager.default.removeItem(at: snapshot.directory) }
            try await stopIfEnded(transfer, sid: nil, jingleModule: jingleModule)
            let source = try FileHandleJingleFileSource(reading: snapshot.snapshotURL)
            // The size is taken from the bytes that were hashed, not from the earlier attribute read. A file still being
            // written changes between the two, and the peer would then stop short of a size it never receives or fail the
            // checksum on bytes that no longer match.
            let fileDesc = JingleFileDescription(
                name: file.name, size: snapshot.size, mediaType: file.mimeType, hash: snapshot.hash
            )
            let sid = try await jingleModule.initiateFileTransfer(to: peerJID, file: fileDesc, offerID: offerID)
            // Checked before the row takes the sid, so an end that landed while the offer was being answered is not missed.
            try await stopIfEnded(transfer, sid: sid, jingleModule: jingleModule)
            if let index = activeTransfers.firstIndex(where: { $0.id == transferID }) {
                activeTransfers[index].sid = sid
            }
            hasSession = true

            try await jingleModule.awaitTransportReady(sid: sid, offerID: offerID)
            try await stopIfEnded(transfer, sid: sid, jingleModule: jingleModule)
            updateTransferState(id: transferID, state: .connectingTransport)
            updateTransferState(id: transferID, state: .transferring(progress: 0))

            try await jingleModule.sendFileData(sid: sid, offerID: offerID, source: source, totalBytes: snapshot.size)
            updateTransferState(id: transferID, state: .completedTransfer)
            // A send can end its session without a completion event, which leaves its sid free for a later session.
            endedSessionRows.insert(transferID)
            await recordSentOutcomeOnce(transferID: transferID, failure: nil)
        } catch {
            // Cancelled with nothing ended here means the app is quitting without a requested disconnect, and nothing is
            // known of how the transfer would have ended. A stopped send, and a row this side ended, recorded their end
            // already.
            if Task.isCancelled || error is CancellationError { throw error }
            if case .transferEnded? = error as? FileTransferError { throw error }
            if isLocallyEnded(transferID) { throw error }
            recordJingleTransferFailure(error, id: transferID)
            // Once the session exists, its failure event reports how it ended and stores that, whether it arrived before
            // this or arrives after. The error here only says the send's wait or write broke off.
            if let jingleError = error as? JingleModule.JingleError, hasSession || jingleError == .sessionEnded { throw error }
            // Nothing else reports this end, so storing it here settles the row's end.
            let reason = failureText(ofTransfer: transferID) ?? Self.failureDetail(of: error)
            endedSessionRows.insert(transferID)
            await recordSentOutcomeOnce(transferID: transferID, failure: reason)
            throw error
        }
    }

    /// Stops a direct send whose row ended or whose task was cancelled while it waited, so the send writes nothing more
    /// to the row. When the session exists and this side ended the row or the task was cancelled, the peer is told why:
    /// `gone` for a requested disconnect, and `cancel` for the user or the cancelled task. A row that its session's own
    /// event ended has no session left to end, and that event stored its outcome. Throws `transferEnded` with the
    /// reason the row reads, or `CancellationError` when the row has not ended.
    private func stopIfEnded(_ transfer: DirectTransfer, sid: String?, jingleModule: JingleModule) async throws {
        let isEnded = endedSessionRows.contains(transfer.id)
        guard isEnded || Task.isCancelled else { return }
        let localEnd = localEnds[transfer.id]
        if let sid, localEnd != nil || !isEnded {
            try? await jingleModule.terminateSession(sid: sid, reason: localEnd?.terminateReason ?? .cancel, offerID: transfer.offerID)
        }
        guard isEnded, let failure = failureText(ofTransfer: transfer.id) else { throw CancellationError() }
        throw FileTransferError.transferEnded(failure)
    }

    /// Stores how a directly sent file ended, unless its outcome is already stored.
    func recordSentOutcomeOnce(transferID: UUID, failure: String?) async {
        guard let conversationID = directTransferConversations.removeValue(forKey: transferID) else { return }
        await chatService?.recordSentFileOutcome(messageID: transferID, in: conversationID, failure: failure)
    }

    /// A private copy of a file being sent directly, with the size and hash its offer declares.
    struct SendSnapshot {
        let snapshotURL: URL
        /// The directory holding the copy, which the sender removes once the send is over.
        let directory: URL
        let size: Int64
        let hash: String
    }

    /// Copies a file into a directory of its own and hashes the copy, off the main actor so neither freezes the UI. The
    /// copy is what gets sent, so the bytes sent are the bytes hashed whatever later happens to the original.
    nonisolated static func prepareSnapshot(of url: URL) async throws -> SendSnapshot {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ducko-send-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Copied from what a link points at, so a relative link cannot dangle and an absolute one does not keep
            // pointing at the original.
            let source = url.resolvingSymlinksInPath()
            let snapshotURL = directory.appending(path: source.lastPathComponent, directoryHint: .notDirectory)
            try FileManager.default.copyItem(at: source, to: snapshotURL)

            let reader = try FileHandleJingleFileSource(reading: snapshotURL)
            let chunkSize = 64 * 1024
            var hasher = JingleFileHasher()
            var size: Int64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try await reader.read(upTo: chunkSize)
                guard !chunk.isEmpty else { break }
                hasher.update(chunk)
                size += Int64(chunk.count)
            }
            return SendSnapshot(snapshotURL: snapshotURL, directory: directory, size: size, hash: hasher.finalize())
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

/// Reads a file on disk to send it, a chunk at a time.
actor FileHandleJingleFileSource: JingleFileSource {
    private let handle: FileHandle

    init(reading fileURL: URL) throws {
        self.handle = try FileHandle(forReadingFrom: fileURL)
    }

    deinit {
        try? handle.close()
    }

    func read(upTo count: Int) throws -> [UInt8] {
        try handle.read(upToCount: count).map(Array.init) ?? []
    }
}
