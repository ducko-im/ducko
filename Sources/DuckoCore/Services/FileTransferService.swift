import DuckoXMPP
import Foundation
import Logging
import UniformTypeIdentifiers

private let log = Logger(label: "im.ducko.core.filetransfer")

@MainActor @Observable
public final class FileTransferService {
    // MARK: - Types

    public enum TransferMethod: Sendable {
        case httpUpload
        case jingle
    }

    public enum TransferDirection: Sendable {
        case outgoing
        case incoming
    }

    /// View-friendly representation of an offer waiting on the user, Jingle or OOB.
    /// Uses strings instead of DuckoXMPP types so DuckoUI can access it without importing DuckoXMPP.
    public struct IncomingFileOffer: Sendable, Identifiable {
        public var id: String {
            offerID
        }

        /// The id this side gave the offer, which Accept and Decline take. The ids on the wire are the peers' to choose, so
        /// two offers can share one; this one names a single offer.
        public let offerID: String
        public let fileName: String
        public let fileSize: Int64
        public let fromJIDString: String
        public let accountID: UUID

        public init(offerID: String, fileName: String, fileSize: Int64, fromJIDString: String, accountID: UUID) {
            self.offerID = offerID
            self.fileName = fileName
            self.fileSize = fileSize
            self.accountID = accountID
            self.fromJIDString = fromJIDString
        }
    }

    public struct ActiveTransfer: Sendable, Identifiable {
        public let id: UUID
        public let accountID: UUID
        public let fileName: String
        public let fileSize: Int64
        public var state: TransferState
        public let method: TransferMethod
        public let direction: TransferDirection
        /// Set once the session exists. An outgoing direct transfer has its row before it has a session.
        public var sid: String?
        /// Who an incoming transfer comes from, as a bare JID, so the chat with them can show it.
        public let peerJIDString: String?

        public init(
            id: UUID, accountID: UUID, fileName: String, fileSize: Int64,
            state: TransferState, method: TransferMethod = .httpUpload,
            direction: TransferDirection = .outgoing, sid: String? = nil, peerJIDString: String? = nil
        ) {
            self.id = id
            self.accountID = accountID
            self.fileName = fileName
            self.fileSize = fileSize
            self.state = state
            self.method = method
            self.direction = direction
            self.sid = sid
            self.peerJIDString = peerJIDString
        }

        /// Whether this is a file a contact is sending that was accepted and is not saved yet.
        public var isReceiving: Bool {
            guard direction == .incoming else { return false }
            switch state {
            case .negotiating, .connectingTransport, .transferring: return true
            case .requestingSlot, .uploading, .completed, .failed, .awaitingAcceptance, .completedTransfer, .received: return false
            }
        }
    }

    public enum TransferState: Sendable {
        // HTTP Upload
        case requestingSlot
        case uploading(progress: Double)
        case completed(downloadURL: String)
        case failed(String)
        // Jingle
        case negotiating
        case connectingTransport
        case transferring(progress: Double)
        case awaitingAcceptance
        case completedTransfer
        case received(fileURL: URL)
    }

    public enum FileTransferError: Error, LocalizedError {
        case fileReadFailed(String)
        case fileSaveFailed(String)
        case downloadFailed(String)
        case offerNotFound
        case noClient
        case noUploadModule
        case noJingleModule
        case uploadFailed(String)
        case directTransferUnavailable

        public var errorDescription: String? {
            switch self {
            case let .fileReadFailed(reason): "Could not read the file: \(reason)"
            case let .fileSaveFailed(reason): "Could not save the file: \(reason)"
            case let .downloadFailed(reason): "Could not download the file: \(reason)"
            case .offerNotFound: "The file offer is no longer waiting"
            case .noClient: notConnectedDescription
            case .noUploadModule: "File upload is not available"
            case .noJingleModule: "Direct file transfer is not available"
            case let .uploadFailed(reason): "Upload failed: \(reason)"
            case .directTransferUnavailable: "The contact has no device online that can receive files directly"
            }
        }
    }

    /// A Jingle offer waiting on the user, with the account it arrived on. Sids are per session, so the same one can be
    /// live on two accounts at once.
    public struct PendingJingleOffer: Sendable {
        public let offer: JingleFileOffer
        public let accountID: UUID
        /// Orders the offer among waiting offers of both kinds.
        public let receivedAt: Date
    }

    /// An OOB offer waiting on the user. Held so the banner can show it with Accept and Decline, as it does a Jingle
    /// offer — the id alone identifies it, but says nothing a person could act on.
    public struct PendingOOBOffer: Sendable {
        public let offer: OOBIQOffer
        public let accountID: UUID
        /// Orders the offer among waiting offers of both kinds.
        public let receivedAt: Date
        /// The transfer row this offer drives. The row's sid is the peer's stanza id, which another offer can share, so
        /// the row is found by this instead.
        public let rowID: UUID

        public var displayFileName: String {
            Attachment.fileName(forLink: offer.url)
        }
    }

    /// The most a download of a peer's link may write, matching the largest size a Jingle offer may declare.
    nonisolated static let maxDownloadSize = JingleFileDescription.maxSize

    /// Bundles file metadata extracted from the file system.
    private struct FileInfo {
        let url: URL
        let name: String
        let size: Int64
        let mimeType: String

        init(readingAttributesAt url: URL) throws(FileTransferError) {
            let attributes: [FileAttributeKey: Any]
            do {
                // Read through a symbolic link, whose own attributes say nothing of what it points at.
                attributes = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            } catch {
                throw .fileReadFailed(error.localizedDescription)
            }
            guard attributes[.type] as? FileAttributeType != .typeDirectory else {
                throw .fileReadFailed("\(url.lastPathComponent) is a folder")
            }
            self.url = url
            self.name = url.lastPathComponent
            self.size = (attributes[.size] as? Int64) ?? 0
            self.mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    // MARK: - State

    public private(set) var activeTransfers: [ActiveTransfer] = []
    public private(set) var incomingOffers: [PendingJingleOffer] = []
    public private(set) var incomingOOBOffers: [PendingOOBOffer] = []
    /// Jingle rows whose session ended, reported by its completion or failure event or by a finished send, so a later
    /// session under the same sid is not mistaken for theirs.
    private var endedSessionRows: Set<UUID> = []
    /// Offer-generation counter, bumped each time an account's waiting offers are dropped. A path that puts an offer back
    /// after an await captures it first and re-checks it via `offerGenerationUnchanged`, so an offer dropped meanwhile stays
    /// dropped.
    private var offerGeneration: [UUID: UInt64] = [:]
    private func pendingOOBOffer(offerID: String, accountID: UUID) -> PendingOOBOffer? {
        incomingOOBOffers.first { $0.offer.offerID == offerID && $0.accountID == accountID }
    }

    private func pendingJingleOffer(offerID: String, accountID: UUID) -> PendingJingleOffer? {
        incomingOffers.first { $0.offer.offerID == offerID && $0.accountID == accountID }
    }

    /// Where every file this app receives or saves from a chat is written.
    public nonisolated let downloadsDirectory: URL

    /// View-friendly projection of every offer waiting on the user, for modules that cannot import DuckoXMPP. Both
    /// kinds reach the same Accept and Decline, which route by offer id. An OOB offer declares no size, so it reports zero.
    /// Ordered by arrival across both kinds, so the last one is the newest whichever kind it is.
    public var viewIncomingOffers: [IncomingFileOffer] {
        let jingle = incomingOffers.map { ($0.receivedAt, Self.viewOffer($0)) }
        let oob = incomingOOBOffers.map { ($0.receivedAt, Self.viewOffer($0)) }
        return (jingle + oob).sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func viewOffer(_ pending: PendingJingleOffer) -> IncomingFileOffer {
        IncomingFileOffer(
            offerID: pending.offer.offerID, fileName: pending.offer.fileName, fileSize: pending.offer.fileSize,
            fromJIDString: pending.offer.from.bareJID.description, accountID: pending.accountID
        )
    }

    private static func viewOffer(_ pending: PendingOOBOffer) -> IncomingFileOffer {
        IncomingFileOffer(
            offerID: pending.offer.offerID, fileName: pending.displayFileName,
            fileSize: 0, fromJIDString: pending.offer.from.bareJID.description, accountID: pending.accountID
        )
    }

    /// Called when an offer starts waiting on the user.
    public var onIncomingOffer: ((IncomingFileOffer) -> Void)?

    private weak var accountService: AccountService?
    private weak var chatService: ChatService?
    private let directTransfers = DirectTransferResolver()
    /// Fire-and-forget Jingle receive tasks that outlive the accept call that spawned them.
    /// Drained by `AppEnvironment.shutdown(within:)` so they can't race teardown; each task removes its
    /// own handle on completion via `defer`.
    private var pendingTasks: [UUID: Task<Void, Never>] = [:]

    public init(downloadsDirectory: URL = .downloadsDirectory) {
        self.downloadsDirectory = downloadsDirectory
    }

    // MARK: - Wiring

    func setAccountService(_ service: AccountService) {
        accountService = service
        directTransfers.accountService = service
    }

    func setChatService(_ service: ChatService) {
        chatService = service
        directTransfers.chatService = service
    }

    func setPresenceService(_ service: PresenceService) {
        directTransfers.presenceService = service
    }

    // MARK: - Lifecycle

    /// Runs on the lifecycle teardowns that bypass `.disconnected`. Those also end what is known of the contacts'
    /// sessions, and with it which of them take direct transfers.
    func purgeAccount(_ accountID: UUID) {
        dropWaitingOffers(for: accountID)
        directTransfers.forgetAccount(accountID)
    }

    /// Drops an account's waiting offers, which died with the connection that carried them, and fails each row still
    /// waiting on the user. Rows of transfers already under way keep their own outcome.
    private func dropWaitingOffers(for accountID: UUID) {
        offerGeneration[accountID, default: 0] &+= 1
        incomingOffers.removeAll { $0.accountID == accountID }
        incomingOOBOffers.removeAll { $0.accountID == accountID }
        for index in activeTransfers.indices where activeTransfers[index].accountID == accountID {
            guard case .awaitingAcceptance = activeTransfers[index].state else { continue }
            setTransferState(.failed(JingleTransferFailureReason.disconnected.displayText), at: index)
        }
    }

    private func offerGenerationUnchanged(_ captured: UInt64, for accountID: UUID) -> Bool {
        offerGeneration[accountID, default: 0] == captured
    }

    // MARK: - Shutdown

    /// Returns the in-flight Jingle transfer task handles and clears the store, so
    /// `AppEnvironment.shutdown(within:)` can cancel and bounded-await a captured snapshot.
    func takePendingTasks() -> [Task<Void, Never>] {
        let tasks = Array(pendingTasks.values)
        pendingTasks.removeAll()
        return tasks
    }

    #if DEBUG
        /// Test seam: lets `shutdown` draining run against a task of controlled duration.
        func registerPendingTaskForTesting(_ task: Task<Void, Never>) {
            pendingTasks[UUID()] = task
        }

        /// Test seam: puts a row in place without driving a session to it, so the rules for applying events to rows can be
        /// exercised on rows in any state.
        func registerTransferForTesting(_ transfer: ActiveTransfer) {
            activeTransfers.append(transfer)
        }
    #endif

    // MARK: - Public API

    @discardableResult
    public func sendFile(
        url: URL, in conversation: Conversation, accountID: UUID,
        method: TransferMethod = .httpUpload,
        peerJID: String? = nil,
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        let file = try FileInfo(readingAttributesAt: url)
        switch method {
        case .httpUpload:
            return try await sendFileViaHTTP(file, in: conversation, accountID: accountID, onProgress: onProgress)
        case .jingle:
            let transfer = try await recordDirectTransfer(of: file, in: conversation, accountID: accountID)
            try await runDirectTransfer(transfer, peer: peerJID)
            return ""
        }
    }

    /// Starts sending a file directly and returns once the file has its row in the chat. What goes wrong before that
    /// is thrown, since no row exists yet to show it. The transfer itself runs on until the contact has accepted and
    /// received the file, and the row reports how it ends.
    public func startDirectTransfer(url: URL, in conversation: Conversation, accountID: UUID) async throws {
        let transfer = try await recordDirectTransfer(of: FileInfo(readingAttributesAt: url), in: conversation, accountID: accountID)
        let taskID = UUID()
        pendingTasks[taskID] = Task { [weak self] in
            defer { self?.pendingTasks[taskID] = nil }
            try? await self?.runDirectTransfer(transfer, peer: nil)
        }
    }

    // MARK: - Direct Transfer Targets

    /// Whether a direct transfer to the contact has a session to go to, from the answers received so far.
    public func canSendDirectly(toJIDString jidString: String, accountID: UUID) -> Bool {
        guard let jid = BareJID.parse(jidString) else { return false }
        return directTransfers.target(for: jid, accountID: accountID) != nil
    }

    /// Asks the contact's online sessions that have not answered yet whether they take direct transfers.
    public func refreshDirectTransferSupport(forJIDString jidString: String, accountID: UUID) async {
        guard let jid = BareJID.parse(jidString) else { return }
        await directTransfers.refresh(for: jid, accountID: accountID)
    }

    // MARK: - Jingle Event Handling

    public func handleJingleEvent(_ event: XMPPEvent, accountID: UUID) {
        switch event {
        case let .jingleFileTransferReceived(offer):
            trackIncomingOffer(offer, accountID: accountID)
        case let .jingleFileTransferProgress(sid, bytesTransferred, totalBytes):
            let progress = Double(bytesTransferred) / Double(totalBytes)
            updateTransferState(forSID: sid, accountID: accountID, state: .transferring(progress: progress))
        case let .jingleFileTransferCompleted(sid, _):
            finishSession(sid: sid, accountID: accountID, state: .completedTransfer)
        case let .jingleFileTransferFailed(sid, reason):
            finishSession(sid: sid, accountID: accountID, state: .failed(reason.displayText))
        case let .oobIQOfferReceived(offer):
            trackIncomingOOBOffer(offer, accountID: accountID)
        case let .disconnected(reason):
            dropWaitingOffers(for: accountID)
            // What the contacts' sessions answered is kept for as long as the sessions themselves are: through a
            // dropped connection, whose stream may resume without presence being sent again, and no further.
            if case .requested = reason {
                directTransfers.forgetAccount(accountID)
            }
        case .connected:
            directTransfers.forgetAccount(accountID)
        case let .presenceUpdated(from, presence):
            guard presence.presenceType == .unavailable else { break }
            switch from {
            case let .full(session): directTransfers.forget(session, accountID: accountID)
            // Unavailable from the bare JID speaks for every session the contact had.
            case let .bare(contact): directTransfers.forgetContact(contact, accountID: accountID)
            }
        case .jingleChecksumReceived:
            break
        case .streamResumed, .authenticationFailed,
             .messageReceived, .presenceReceived, .iqReceived,
             .rosterUpdated,
             .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged,
             .roomSubjectChanged, .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived,
             .roomDestroyed, .mucSelfPingFailed,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced, .omemoRecipientsPartial,
             .serviceOutageReceived:
            break
        }
    }

    private func trackIncomingOOBOffer(_ offer: OOBIQOffer, accountID: UUID) {
        let pending = PendingOOBOffer(offer: offer, accountID: accountID, receivedAt: Date(), rowID: UUID())
        incomingOOBOffers.append(pending)
        onIncomingOffer?(Self.viewOffer(pending))
        let transfer = ActiveTransfer(
            id: pending.rowID,
            accountID: accountID,
            fileName: pending.displayFileName,
            fileSize: 0,
            state: .awaitingAcceptance,
            method: .httpUpload,
            direction: .incoming,
            sid: offer.id,
            peerJIDString: offer.from.bareJID.description
        )
        activeTransfers.append(transfer)
    }

    /// Records an offer waiting on the user. Its transfer row is created when the user accepts, so the banner is the
    /// only thing on screen until then and a declined offer leaves nothing behind.
    private func trackIncomingOffer(_ offer: JingleFileOffer, accountID: UUID) {
        let pending = PendingJingleOffer(offer: offer, accountID: accountID, receivedAt: Date())
        incomingOffers.append(pending)
        onIncomingOffer?(Self.viewOffer(pending))
    }

    /// Moves a session's transfer row to its final state and drops its pending offer. The module holds one session per
    /// sid at a time and reports a session's end before a later one can take its sid, so the sid names that session here.
    private func finishSession(sid: String, accountID: UUID, state: TransferState) {
        if let index = sessionRowIndex(sid: sid, accountID: accountID) {
            setTransferState(state, at: index)
            endedSessionRows.insert(activeTransfers[index].id)
        }
        incomingOffers.removeAll { $0.offer.sid == sid && $0.accountID == accountID }
    }

    private func removeOffer(offerID: String) {
        incomingOffers.removeAll { $0.offer.offerID == offerID }
    }

    private func removeOOBOffer(offerID: String) {
        incomingOOBOffers.removeAll { $0.offer.offerID == offerID }
    }

    // MARK: - Incoming Transfer Management

    public func acceptIncomingTransfer(_ offerID: String, accountID: UUID) async throws {
        if let pending = pendingOOBOffer(offerID: offerID, accountID: accountID) {
            try await acceptOOBOffer(pending)
            return
        }

        guard pendingJingleOffer(offerID: offerID, accountID: accountID) != nil else {
            throw FileTransferError.offerNotFound
        }
        let jingleModule = try await jingleModule(for: accountID)
        // Looked up again once the module is resolved: a second accept or a decline can have taken the offer meanwhile.
        guard let pending = pendingJingleOffer(offerID: offerID, accountID: accountID) else {
            throw FileTransferError.offerNotFound
        }
        let offer = pending.offer

        // The banner gives way to the transfer's own row before the session-accept goes out, so a decline or failure
        // arriving while that stanza is in flight has a row to record it on.
        removeOffer(offerID: offerID)
        let rowID = UUID()
        activeTransfers.append(ActiveTransfer(
            id: rowID,
            accountID: accountID,
            fileName: offer.fileName,
            fileSize: offer.fileSize,
            state: .connectingTransport,
            method: .jingle,
            direction: .incoming,
            sid: offer.sid,
            peerJIDString: offer.from.bareJID.description
        ))

        let generation = offerGeneration[accountID, default: 0]
        do {
            try await jingleModule.acceptFileTransfer(sid: offer.sid, offerID: offerID)
        } catch {
            // A session-accept that did not go out leaves the session acceptable again, so the offer returns to the banner
            // for another try. It stays out when the session ended meanwhile and its row already records why, or when the
            // account's offers were dropped meanwhile.
            if !endedSessionRows.contains(rowID) {
                if offerGenerationUnchanged(generation, for: accountID) {
                    activeTransfers.removeAll { $0.id == rowID }
                    incomingOffers.append(pending)
                } else {
                    // The disconnect meanwhile took the session with it, and a requested one reports no failure. The row
                    // is closed off here, so a later session reusing the sid gets its own.
                    updateTransferState(id: rowID, state: .failed(JingleTransferFailureReason.disconnected.displayText))
                    endedSessionRows.insert(rowID)
                }
            }
            throw error
        }
        startJingleReceiveTask(offer: offer, rowID: rowID, accountID: accountID, jingleModule: jingleModule)
    }

    /// Accepts a link a peer offered: the file is downloaded and saved as an accepted Jingle transfer is, and the offer
    /// is answered only once it is on disk (XEP-0066 §2). The offer leaves the banner for the length of the download, so
    /// a second accept or a decline cannot act on it meanwhile. A download that fails puts it back for another try,
    /// unless the account's offers were dropped meanwhile.
    private func acceptOOBOffer(_ pending: PendingOOBOffer) async throws {
        let offerID = pending.offer.offerID
        let accountID = pending.accountID
        guard let url = URL(string: pending.offer.url) else {
            throw FileTransferError.downloadFailed("The link could not be read")
        }
        let oobModule = try await oobModule(for: accountID)
        // Claimed only if still waiting once the module is resolved: a second accept or a decline can have taken it.
        guard pendingOOBOffer(offerID: offerID, accountID: accountID) != nil else {
            throw FileTransferError.offerNotFound
        }
        removeOOBOffer(offerID: offerID)
        updateTransferState(id: pending.rowID, state: .transferring(progress: 0))

        let generation = offerGeneration[accountID, default: 0]
        let download: (fileURL: URL, byteCount: Int64)
        do {
            download = try await Self.downloadRemoteFile(from: url, named: pending.displayFileName, into: downloadsDirectory)
        } catch {
            if offerGenerationUnchanged(generation, for: accountID) {
                updateTransferState(id: pending.rowID, state: .awaitingAcceptance)
                incomingOOBOffers.append(pending)
            } else {
                // The disconnect meanwhile left nothing to retry against, so the download's own failure is final.
                updateTransferState(id: pending.rowID, state: .failed(error.localizedDescription))
            }
            throw error
        }
        await recordReceivedFile(
            at: download.fileURL, byteCount: download.byteCount, mediaType: nil,
            from: pending.offer.from.bareJID, accountID: accountID
        )
        updateTransferState(id: pending.rowID, state: .received(fileURL: download.fileURL))
        do {
            try await oobModule.acceptOffer(offerID: offerID)
        } catch {
            // The file is saved and recorded regardless; an answer that cannot be sent leaves the peer's request to time out.
            log.warning("Could not acknowledge an accepted link: \(error)")
        }
    }

    /// Starts the task that receives an accepted offer's bytes once its connection is ready and saves them. The module's
    /// completion or failure event records the transfer's outcome, and the saved file then replaces a completion.
    private func startJingleReceiveTask(offer: JingleFileOffer, rowID: UUID, accountID: UUID, jingleModule: JingleModule) {
        let sid = offer.sid
        let taskID = UUID()
        pendingTasks[taskID] = Task { [weak self] in
            defer { self?.pendingTasks[taskID] = nil }
            guard let self else { return }
            do {
                try await jingleModule.awaitTransportReady(sid: sid, offerID: offer.offerID)
                updateTransferState(id: rowID, state: .transferring(progress: 0))
                let data = try await jingleModule.receiveFileData(sid: sid, offerID: offer.offerID)
                let fileURL = try await Self.saveReceivedFile(data, named: offer.fileName, in: downloadsDirectory)
                log.debug("Saved \(data.count) bytes received via Jingle for sid: \(sid)")
                await recordReceivedFile(
                    at: fileURL, byteCount: Int64(data.count), mediaType: offer.mediaType,
                    from: offer.from.bareJID, accountID: accountID
                )
                updateTransferState(id: rowID, state: .received(fileURL: fileURL))
            } catch {
                log.warning("Jingle receive failed for sid \(sid): \(error)")
                recordJingleTransferFailure(error, id: rowID)
            }
        }
    }

    /// Reads and hashes a file off the main actor, so a large send doesn't freeze the UI before its row appears.
    private nonisolated static func readAndHash(at url: URL) async throws -> (bytes: [UInt8], hash: String) {
        let bytes = try Array(Data(contentsOf: url))
        return (bytes, JingleFileDescription.sha256Hash(of: bytes))
    }

    /// Adds a saved file to the conversation with its sender, where it shows like any other attachment.
    private func recordReceivedFile(
        at fileURL: URL, byteCount: Int64, mediaType: String?, from jid: BareJID, accountID: UUID
    ) async {
        guard let chatService else {
            log.warning("No chat service to record a received file with")
            return
        }
        // XEP-0234 does not require `<media-type>`, and without one the saved file would render as a card while the
        // same file shared as a link renders inline. The file is on disk, so its own extension answers for it.
        let resolvedType = mediaType ?? UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
        // Marked as this app's own file, which is what lets it be previewed and revealed. A peer's `file:` URL reaches
        // `Attachment.init` instead and stays remote.
        let attachment = Attachment.locallySaved(
            id: UUID(), fileURL: fileURL, mimeType: resolvedType, fileSize: byteCount
        )
        do {
            try await chatService.recordReceivedFile(attachment, from: jid, accountID: accountID)
        } catch {
            log.warning("Could not add a received file to its conversation: \(error)")
        }
    }

    /// Declines an offer still waiting on the user. A transfer already under way is not an offer, so this does not end it.
    public func declineIncomingTransfer(_ offerID: String, accountID: UUID) async throws {
        if pendingOOBOffer(offerID: offerID, accountID: accountID) != nil {
            let oobModule = try await oobModule(for: accountID)
            // Taken off the banner before the rejection goes out, so an accept cannot start a download meanwhile, and only
            // if still waiting once the module is resolved.
            guard let pending = pendingOOBOffer(offerID: offerID, accountID: accountID) else {
                throw FileTransferError.offerNotFound
            }
            removeOOBOffer(offerID: offerID)
            let generation = offerGeneration[accountID, default: 0]
            do {
                try await oobModule.rejectOffer(offerID: offerID)
            } catch {
                // An offer dropped meanwhile already had its row failed with the disconnect.
                if offerGenerationUnchanged(generation, for: accountID) {
                    incomingOOBOffers.append(pending)
                }
                throw error
            }
            updateTransferState(id: pending.rowID, state: .failed("You declined the transfer"))
            return
        }

        guard pendingJingleOffer(offerID: offerID, accountID: accountID) != nil else {
            throw FileTransferError.offerNotFound
        }
        let jingleModule = try await jingleModule(for: accountID)
        guard let pending = pendingJingleOffer(offerID: offerID, accountID: accountID) else {
            throw FileTransferError.offerNotFound
        }
        // Taken before the terminate goes out: the module ends the session whether or not the terminate reaches the peer.
        removeOffer(offerID: offerID)
        try await jingleModule.declineFileTransfer(sid: pending.offer.sid, offerID: offerID)
    }

    // MARK: - Received Files

    /// Fetches a remote image and saves it the way an accepted transfer is saved: same folder, a free name rather than
    /// an overwrite, and quarantined.
    public func saveRemoteImage(from url: URL, named name: String) async throws -> URL {
        try await Self.downloadRemoteFile(from: url, named: name, into: downloadsDirectory).fileURL
    }

    // MARK: - Private: HTTP Upload

    private func sendFileViaHTTP(
        _ file: FileInfo, in conversation: Conversation, accountID: UUID,
        onProgress: (@MainActor @Sendable (Double) -> Void)?
    ) async throws -> String {
        let transferID = UUID()
        let transfer = ActiveTransfer(
            id: transferID,
            accountID: accountID,
            fileName: file.name,
            fileSize: file.size,
            state: .requestingSlot,
            method: .httpUpload,
            direction: .outgoing
        )
        activeTransfers.append(transfer)

        do {
            let slot = try await requestUploadSlot(fileName: file.name, fileSize: file.size, mimeType: file.mimeType, accountID: accountID)
            let downloadURL = try await performUpload(fileURL: file.url, slot: slot, mimeType: file.mimeType, transferID: transferID, onProgress: onProgress)
            // Yield to drain any pending progress callbacks before setting terminal state
            await Task.yield()
            try await sendDownloadURL(downloadURL, of: file, in: conversation, accountID: accountID)
            updateTransferState(id: transferID, state: .completed(downloadURL: downloadURL))
            return downloadURL
        } catch {
            await Task.yield()
            updateTransferState(id: transferID, state: .failed(error.localizedDescription))
            throw error
        }
    }

    // MARK: - Private: Jingle Transfer

    /// A file on its way to a contact directly, from the moment it has its row.
    private struct DirectTransfer {
        /// The id of the file's row in the chat and of its transfer row, which is how the chat finds the live state
        /// of its row.
        let id: UUID
        let file: FileInfo
        let contact: BareJID
        let conversationID: UUID
        let accountID: UUID
    }

    /// Gives the file its row in the chat and its transfer row before anything about the transfer itself can fail, so
    /// every outcome has somewhere to show.
    private func recordDirectTransfer(
        of file: FileInfo, in conversation: Conversation, accountID: UUID
    ) async throws -> DirectTransfer {
        guard conversation.isDirectChat, let chatService else {
            throw FileTransferError.directTransferUnavailable
        }
        let transferID = UUID()
        let attachment = Attachment.locallySaved(id: UUID(), fileURL: file.url, mimeType: file.mimeType, fileSize: file.size)
        let conversationID = try await chatService.recordSentFile(attachment, id: transferID, to: conversation.jid, accountID: accountID)
        activeTransfers.append(ActiveTransfer(
            id: transferID, accountID: accountID, fileName: file.name, fileSize: file.size,
            state: .negotiating, method: .jingle, direction: .outgoing
        ))
        return DirectTransfer(
            id: transferID, file: file, contact: conversation.jid, conversationID: conversationID, accountID: accountID
        )
    }

    private func runDirectTransfer(_ transfer: DirectTransfer, peer: String?) async throws {
        let (transferID, file, accountID) = (transfer.id, transfer.file, transfer.accountID)
        do {
            let peerJID = try await directTransferPeer(named: peer, for: transfer.contact, accountID: accountID)
            let jingleModule = try await jingleModule(for: accountID)
            let (fileData, hash) = try await Self.readAndHash(at: file.url)
            // The size is taken from the bytes that were hashed, not from the earlier attribute read. A file still being
            // written changes between the two, and the peer would then stop short of a size it never receives or fail the
            // checksum on bytes that no longer match.
            let fileDesc = JingleFileDescription(
                name: file.name, size: Int64(fileData.count), mediaType: file.mimeType, hash: hash
            )
            let sid = try await jingleModule.initiateFileTransfer(to: peerJID, file: fileDesc)
            if let index = activeTransfers.firstIndex(where: { $0.id == transferID }) {
                activeTransfers[index].sid = sid
            }

            try await jingleModule.awaitTransportReady(sid: sid)
            updateTransferState(id: transferID, state: .connectingTransport)
            updateTransferState(id: transferID, state: .transferring(progress: 0))

            try await jingleModule.sendFileData(sid: sid, data: fileData)
            updateTransferState(id: transferID, state: .completedTransfer)
            // A send can end its session without a completion event, which leaves its sid free for a later session.
            endedSessionRows.insert(transferID)
            await chatService?.recordSentFileOutcome(messageID: transferID, in: transfer.conversationID, failure: nil)
        } catch {
            // Cancelled means the app is quitting. Nothing is known of how the transfer would have ended, so nothing
            // is recorded.
            if Task.isCancelled { throw error }
            // The chat row keeps the reason the transfer row ended up with, which is the session's own failure event
            // when that came first.
            recordJingleTransferFailure(error, id: transferID)
            let reason = failureText(ofTransfer: transferID) ?? Self.failureDetail(of: error)
            await chatService?.recordSentFileOutcome(messageID: transferID, in: transfer.conversationID, failure: reason)
            throw error
        }
    }

    /// What went wrong, without the summary label an error's description leads with: a transfer's row already reads
    /// as a file that failed.
    private static func failureDetail(of error: any Error) -> String {
        switch error as? JingleModule.JingleError {
        case let .transportFailed(reason)?, let .transportNegotiationFailed(reason)?: reason
        case .notConnected?, .sessionNotFound?, .noConnectedJID?, .alreadyAccepted?, nil: error.localizedDescription
        }
    }

    /// The session a direct transfer goes to: the one `peer` names, else one chosen among the contact's online
    /// sessions, asking those that have not answered only when none known takes direct transfers.
    private func directTransferPeer(named peer: String?, for jid: BareJID, accountID: UUID) async throws -> FullJID {
        if let peer, let named = FullJID.parse(peer) { return named }
        // A session already known to take the file is used at once: asking the rest first would hold the offer back
        // for as long as a session that has gone silent takes to time out.
        if let known = directTransfers.target(for: jid, accountID: accountID) { return known }
        await directTransfers.refresh(for: jid, accountID: accountID)
        guard let target = directTransfers.target(for: jid, accountID: accountID) else {
            throw FileTransferError.directTransferUnavailable
        }
        return target
    }

    private func failureText(ofTransfer id: UUID) -> String? {
        guard case let .failed(text) = activeTransfers.first(where: { $0.id == id })?.state else { return nil }
        return text
    }

    // MARK: - Private: HTTP Upload Helpers

    private func requestUploadSlot(
        fileName: String,
        fileSize: Int64,
        mimeType: String,
        accountID: UUID
    ) async throws -> HTTPUploadModule.UploadSlot {
        guard let client = accountService?.connectedClient(for: accountID) else {
            throw FileTransferError.noClient
        }
        guard let uploadModule = await client.module(ofType: HTTPUploadModule.self) else {
            throw FileTransferError.noUploadModule
        }
        return try await uploadModule.requestSlot(filename: fileName, size: fileSize, contentType: mimeType)
    }

    private func performUpload(
        fileURL: URL,
        slot: HTTPUploadModule.UploadSlot,
        mimeType: String,
        transferID: UUID,
        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        updateTransferState(id: transferID, state: .uploading(progress: 0))

        guard let putURL = URL(string: slot.putURL) else {
            throw FileTransferError.uploadFailed("The server provided an invalid upload address")
        }

        var request = URLRequest(url: putURL)
        request.httpMethod = "PUT"
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        for (name, value) in slot.putHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let delegate = UploadProgressDelegate { progress in
            Task { @MainActor in
                self.updateTransferState(id: transferID, state: .uploading(progress: progress))
                onProgress?(progress)
            }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FileTransferError.uploadFailed("The server sent an invalid response")
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw FileTransferError.uploadFailed(Self.uploadStatusText(httpResponse.statusCode))
        }

        updateTransferState(id: transferID, state: .uploading(progress: 1.0))
        return slot.getURL
    }

    /// The readable phrase for a failed upload's HTTP status, capitalized like the other upload failure details.
    nonisolated static func uploadStatusText(_ statusCode: Int) -> String {
        let phrase = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        return phrase.prefix(1).uppercased() + phrase.dropFirst()
    }

    private func sendDownloadURL(_ downloadURL: String, of file: FileInfo, in conversation: Conversation, accountID: UUID) async throws {
        guard let chatService else {
            throw FileTransferError.uploadFailed("The chat service is not available")
        }
        let attachment = Attachment(id: UUID(), url: downloadURL, mimeType: file.mimeType, fileName: file.name, fileSize: file.size)
        let jid = conversation.jid
        switch conversation.type {
        case .chat:
            try await chatService.sendMessage(to: jid, body: downloadURL, accountID: accountID, attachments: [attachment])
        case .groupchat:
            try await chatService.sendGroupMessage(to: jid, body: downloadURL, accountID: accountID, attachments: [attachment])
        }
    }

    // MARK: - Private: Module Lookup

    private func jingleModule(for accountID: UUID) async throws -> JingleModule {
        guard let client = accountService?.connectedClient(for: accountID) else {
            throw FileTransferError.noClient
        }
        guard let module = await client.module(ofType: JingleModule.self) else {
            throw FileTransferError.noJingleModule
        }
        return module
    }

    private func oobModule(for accountID: UUID) async throws -> OOBModule {
        guard let client = accountService?.connectedClient(for: accountID) else {
            throw FileTransferError.noClient
        }
        guard let module = await client.module(ofType: OOBModule.self) else {
            throw FileTransferError.noClient
        }
        return module
    }

    // MARK: - Private: State Updates

    private func updateTransferState(id: UUID, state: TransferState) {
        if let index = activeTransfers.firstIndex(where: { $0.id == id }) {
            setTransferState(state, at: index)
        }
    }

    private func updateTransferState(forSID sid: String, accountID: UUID, state: TransferState) {
        if let index = sessionRowIndex(sid: sid, accountID: accountID) {
            setTransferState(state, at: index)
        }
    }

    /// The row of the session a Jingle event names by sid. A peer can reuse a sid once its session ended and can choose a
    /// link offer's stanza id as one, so the row is a Jingle row whose session has not yet reported its end: one that has
    /// belongs to an earlier session.
    private func sessionRowIndex(sid: String, accountID: UUID) -> Int? {
        activeTransfers.firstIndex { row in
            row.method == .jingle && row.sid == sid && row.accountID == accountID && !endedSessionRows.contains(row.id)
        }
    }

    /// A failed row stays failed: only another failure replaces its state. A received row likewise keeps the file it
    /// saved — the transport's completion event is dispatched independently of the save, so one landing after it would
    /// otherwise replace the saved URL with a bare completion and leave Quick Look and Reveal with nothing to open.
    private func setTransferState(_ state: TransferState, at index: Int) {
        if case .failed = activeTransfers[index].state {
            guard case .failed = state else { return }
        }
        if case .received = activeTransfers[index].state {
            guard case .received = state else { return }
        }
        activeTransfers[index].state = state
    }

    /// Records a Jingle transfer task's failure. A `JingleError` that arrives after the transfer already failed is a side
    /// effect of the session ending, like a cancelled wait or a closed socket, so the failure event's reason is kept. Any
    /// other error, like a file that could not be read, is recorded.
    func recordJingleTransferFailure(_ error: any Error, id: UUID) {
        guard let index = activeTransfers.firstIndex(where: { $0.id == id }) else { return }
        if error is JingleModule.JingleError, case .failed = activeTransfers[index].state { return }
        setTransferState(.failed(Self.failureDetail(of: error)), at: index)
    }
}

// MARK: - Upload Progress Delegate

/// URLSession delegate that reports upload progress. Must be a class conforming to NSObject
/// for URLSession delegate requirements — `@unchecked Sendable` is required because
/// URLSessionTaskDelegate is not Sendable but the callback is safe to call from any thread.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        onProgress(progress)
    }
}
