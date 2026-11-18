import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore

private let testAccountID = UUID()

/// Whether `error` stopped a send whose row read `reason`.
@MainActor
private func isEnded(_ error: (any Error)?, reading reason: String) -> Bool {
    guard case let .transferEnded(text)? = error as? FileTransferService.FileTransferError else { return false }
    return text == reason
}

extension FileTransferService.LocalEnd {
    /// The reason the peer is told, as the session-terminate carries it.
    var wireReason: String {
        "<\(terminateReason.rawValue)/>"
    }

    /// Ends the row the way the user or the disconnect does. The disconnect is only the service's part of it, so the
    /// connection stays up for what the send does next.
    @MainActor
    func end(_ rowID: UUID, in harness: DirectTransferHarness) async {
        switch self {
        case .canceled: await harness.service.cancelTransfer(id: rowID)
        case .wentOffline: harness.service.purgeAccount(harness.accountID)
        }
    }
}

/// How a direct transfer's end is recorded on its row, as a sent file's stored outcome, or as a note for a file that
/// did not arrive. The end comes from the user's stop, a requested disconnect, or the session's own failure.
enum FileTransferServiceEndingTests {
    /// Every end this side brings about.
    static let localEnds: [FileTransferService.LocalEnd] = [.canceled, .wentOffline]

    @MainActor
    struct Sending {
        @Test
        func `Canceling a send that is moving bytes stores that the user canceled it once`() async throws {
            let harness = try await DirectTransferHarness.connect()
            try await withTemporaryDirectory { directory in
                // Two blocks, so the send has another to go once the first is let through.
                let fileURL = directory.appending(path: "notes.bin")
                try Data(repeating: 7, count: 5000).write(to: fileURL)
                let transport = harness.transport
                await transport.blockSends { $0.contains("<data") }
                let (sendTask, sid) = try await harness.send(fileURL)
                try await harness.switchToIBB(sid: sid)
                try #require(try await boundedOutcome { await transport.waitForBlockedSend() } != nil)
                let rowID = try #require(harness.service.activeTransfers.first?.id)

                #expect(await harness.service.cancelTransfer(id: rowID))
                // A transfer that already ended has nothing left to stop.
                #expect(await !harness.service.cancelTransfer(id: rowID))
                await transport.releaseBlockedSends()

                let outcome = try await boundedOutcome { try await sendTask.value }
                guard case .failure? = outcome else {
                    Issue.record("Expected the send to stop, got \(String(describing: outcome))")
                    return
                }
                try await harness.drainTasks()
                #expect(harness.service.failureText(ofTransfer: rowID) == FileTransferService.LocalEnd.canceled.text)
                #expect(await harness.storedOutcomes() == [FileTransferService.LocalEnd.canceled.text])
                #expect(try await sentStanza(on: transport, containing: "session-terminate").contains("<cancel/>"))
            }
            await harness.tearDown()
        }

        @Test(arguments: localEnds)
        func `A send ended while its offer is on the way withdraws it once answered and sends nothing`(end: FileTransferService.LocalEnd) async throws {
            let harness = try await DirectTransferHarness.connect()
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appending(path: "notes.txt")
                try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
                let transport = harness.transport
                await transport.blockSends { $0.contains("session-initiate") }
                let sendTask = harness.startSending(fileURL)
                try #require(try await boundedOutcome { await transport.waitForBlockedSend() } != nil)
                let rowID = try #require(harness.service.activeTransfers.first?.id)

                await end.end(rowID, in: harness)
                await transport.releaseBlockedSends()

                let outcome = try await boundedOutcome { try await sendTask.value }
                guard case let .failure(error)? = outcome else {
                    Issue.record("Expected the send to stop, got \(String(describing: outcome))")
                    return
                }
                #expect(isEnded(error, reading: end.text))
                #expect(try await sentStanza(on: transport, containing: "session-terminate").contains(end.wireReason))
                #expect(await !harness.sentIBBOpen())
                try await harness.drainTasks()
                #expect(await harness.storedOutcomes() == [end.text])
            }
            await harness.tearDown()
        }

        @Test
        func `A send that resumes from its connection wait after a disconnect withdraws it as gone`() async throws {
            let harness = try await DirectTransferHarness.connect()
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appending(path: "notes.txt")
                try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
                let (sendTask, sid) = try await harness.send(fileURL)
                try await harness.awaitAnsweredOffer(sid: sid)

                harness.service.purgeAccount(harness.accountID)
                try await harness.switchToIBB(sid: sid)

                let outcome = try await boundedOutcome { try await sendTask.value }
                guard case let .failure(error)? = outcome else {
                    Issue.record("Expected the send to stop, got \(String(describing: outcome))")
                    return
                }
                #expect(isEnded(error, reading: FileTransferService.LocalEnd.wentOffline.text))
                let terminate = try await sentStanza(on: harness.transport, containing: "session-terminate")
                #expect(terminate.contains("<gone/>"))
                #expect(!terminate.contains("<cancel/>"))
                #expect(await !harness.sentIBBOpen())
            }
            await harness.tearDown()
        }

        /// The disconnect also cancels the event dispatch, so the module's own report of the session's end never reaches
        /// the service, and the send's wait fails without a reason of its own.
        @Test
        func `A requested disconnect during a send stores that it stopped when the user went offline`() async throws {
            let harness = try await DirectTransferHarness.connect()
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appending(path: "notes.txt")
                try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
                let (sendTask, sid) = try await harness.send(fileURL)
                try await harness.awaitAnsweredOffer(sid: sid)
                let rowID = try #require(harness.service.activeTransfers.first?.id)

                await harness.accountService.disconnect(accountID: harness.accountID)

                let outcome = try await boundedOutcome { try await sendTask.value }
                guard case .failure? = outcome else {
                    Issue.record("Expected the send to stop, got \(String(describing: outcome))")
                    return
                }
                try await harness.drainTasks()
                #expect(harness.service.failureText(ofTransfer: rowID) == FileTransferService.LocalEnd.wentOffline.text)
                #expect(await harness.storedOutcomes() == [FileTransferService.LocalEnd.wentOffline.text])
                #expect(try await sentStanza(on: harness.transport, containing: "session-terminate").contains("<gone/>"))
            }
            await harness.tearDown()
        }

        @Test
        func `A send whose offer is refused stores the refusal`() async throws {
            let harness = try await DirectTransferHarness.connect()
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appending(path: "notes.txt")
                try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
                await harness.transport.failNextSend(matching: "session-initiate", error: XMPPClientError.sendFailed("The connection was closed"))

                let outcome = try await boundedOutcome { try await harness.startSending(fileURL).value }
                guard case .failure? = outcome else {
                    Issue.record("Expected the send to fail, got \(String(describing: outcome))")
                    return
                }
                try await harness.drainTasks()
                #expect(await harness.storedOutcomes() == ["The connection was closed"])
            }
            await harness.tearDown()
        }

        /// The write's own error says only that the socket or stream broke off; the peer's terminate says why.
        @Test
        func `A send whose session the contact cancels during a write stores the contact's reason`() async throws {
            let harness = try await DirectTransferHarness.connect()
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appending(path: "notes.bin")
                try Data(repeating: 7, count: 5000).write(to: fileURL)
                let transport = harness.transport
                await transport.blockSends { $0.contains("<data") }
                let (sendTask, sid) = try await harness.send(fileURL)
                try await harness.switchToIBB(sid: sid)
                try #require(try await boundedOutcome { await transport.waitForBlockedSend() } != nil)
                let rowID = try #require(harness.service.activeTransfers.first?.id)

                await harness.peerTerminates(sid: sid, reason: "cancel")
                await transport.failBlockedSends(with: XMPPClientError.sendFailed("The connection was closed"))
                let outcome = try await boundedOutcome { try await sendTask.value }
                guard case .failure? = outcome else {
                    Issue.record("Expected the send to fail, got \(String(describing: outcome))")
                    return
                }
                try await harness.drainTasks()
                #expect(await harness.storedOutcomes().isEmpty)

                // The session's failure event reaches the service after the send's catch, as dispatch orders it.
                try await harness.service.handleJingleEvent(harness.failureEvent(sid: sid), accountID: harness.accountID)
                try await harness.drainTasks()
                #expect(harness.service.failureText(ofTransfer: rowID) == JingleTransferFailureReason.cancel.displayText)
                #expect(await harness.storedOutcomes() == [JingleTransferFailureReason.cancel.displayText])
            }
            await harness.tearDown()
        }

        /// The contact declines the offer before this side has its acknowledgement, so the session ends before the offer's
        /// initiation returns. Its failure event names the offer, so it finds the row whether it lands before the send's
        /// own catch or after it.
        @Test(arguments: [true, false])
        func `A send declined before its offer is answered stores the contact's reason`(eventFirst: Bool) async throws {
            let harness = try await DirectTransferHarness.connect()
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appending(path: "notes.txt")
                try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
                let transport = harness.transport
                await transport.blockSends { $0.contains("session-initiate") }
                let sendTask = harness.startSending(fileURL)
                try #require(try await boundedOutcome { await transport.waitForBlockedSend() } != nil)
                let rowID = try #require(harness.service.activeTransfers.first?.id)
                let offer = try #require(await transport.lastBlockedStanza)
                let sid = try String(#require(offer.firstMatch(of: /\ssid=["']([^"']+)["']/)?.output.1))

                await harness.peerTerminates(sid: sid, reason: "decline")
                let decline = try await harness.failureEvent(sid: sid)
                if eventFirst { harness.service.handleJingleEvent(decline, accountID: harness.accountID) }
                await transport.releaseBlockedSends()
                let outcome = try await boundedOutcome { try await sendTask.value }
                guard case .failure? = outcome else {
                    Issue.record("Expected the send to stop, got \(String(describing: outcome))")
                    return
                }
                if !eventFirst {
                    try await harness.drainTasks()
                    #expect(await harness.storedOutcomes().isEmpty)
                    harness.service.handleJingleEvent(decline, accountID: harness.accountID)
                }
                try await harness.drainTasks()

                let reason = JingleTransferFailureReason.decline.displayText
                #expect(harness.service.failureText(ofTransfer: rowID) == reason)
                #expect(await harness.storedOutcomes() == [reason])
            }
            await harness.tearDown()
        }

        /// A local end claims the sent file's outcome in the turn it ends the row, so a send that finished meanwhile and
        /// stores its success afterwards stores nothing.
        @Test
        func `A local end that lands before a finished send stores its success keeps its own outcome`() async throws {
            let transcripts = MockTranscriptStore()
            let chatService = ChatService(store: MockPersistenceStore(), transcripts: transcripts, filterPipeline: MessageFilterPipeline())
            let service = FileTransferService()
            service.setChatService(chatService)
            let rowID = UUID()
            let file = Attachment.locallySaved(id: UUID(), fileURL: URL(fileURLWithPath: "/tmp/notes.txt"), mimeType: "text/plain", fileSize: 3)
            let peer = try #require(BareJID.parse("bob@example.com"))
            let conversationID = try await chatService.recordSentFile(file, id: rowID, to: peer, accountID: testAccountID)
            service.directTransferConversations[rowID] = conversationID
            service.registerTransferForTesting(FileTransferService.ActiveTransfer(
                id: rowID, accountID: testAccountID, fileName: "notes.txt", fileSize: 3, state: .transferring(progress: 1),
                method: .jingle, direction: .outgoing, sid: "sent-sid", offerID: rowID.uuidString
            ))

            service.purgeAccount(testAccountID)
            await service.recordSentOutcomeOnce(transferID: rowID, failure: nil)
            let drained = try await boundedOutcome {
                while case let tasks = await service.takePendingTasks(), !tasks.isEmpty {
                    for task in tasks {
                        await task.value
                    }
                }
            }
            try #require(drained != nil)

            let row = try #require(await chatService.loadMessages(for: conversationID).first)
            #expect(!row.isDelivered)
            #expect(row.errorText == FileTransferService.LocalEnd.wentOffline.text)
        }

        /// The disconnect also cancels the dispatch of the event the send's catch left its outcome to.
        @Test
        func `A requested disconnect after a send's task failed stores the failure its row reads`() async throws {
            let harness = try await DirectTransferHarness.connect()
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appending(path: "notes.bin")
                try Data(repeating: 7, count: 5000).write(to: fileURL)
                let transport = harness.transport
                await transport.blockSends { $0.contains("<data") }
                let (sendTask, sid) = try await harness.send(fileURL)
                try await harness.switchToIBB(sid: sid)
                try #require(try await boundedOutcome { await transport.waitForBlockedSend() } != nil)
                let rowID = try #require(harness.service.activeTransfers.first?.id)
                await harness.peerTerminates(sid: sid, reason: "cancel")
                await transport.failBlockedSends(with: XMPPClientError.sendFailed("The connection was closed"))
                let outcome = try await boundedOutcome { try await sendTask.value }
                guard case .failure? = outcome else {
                    Issue.record("Expected the send to fail, got \(String(describing: outcome))")
                    return
                }
                try await harness.drainTasks()
                // Armed: the send's catch failed the row with its write's error and left its outcome to the event.
                let failure = "The connection was closed"
                #expect(harness.service.failureText(ofTransfer: rowID) == failure)
                #expect(await harness.storedOutcomes().isEmpty)

                await harness.accountService.disconnect(accountID: harness.accountID)
                try await harness.drainTasks()

                #expect(harness.service.failureText(ofTransfer: rowID) == failure)
                #expect(await harness.storedOutcomes() == [failure])
            }
            await harness.tearDown()
        }

        /// Only the contact can say the file arrived, so a send it never confirms fails once the confirmation wait
        /// elapses. The session's failure event is the one source of the stored outcome, which is stored once and never
        /// as delivered.
        @Test
        func `A send the contact never confirms stores that it was not confirmed once`() async throws {
            let harness = try await DirectTransferHarness.connect()
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appending(path: "notes.txt")
                try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
                let (sendTask, sid) = try await harness.send(fileURL)
                try await harness.switchToIBB(sid: sid)
                let rowID = try #require(harness.service.activeTransfers.first?.id)

                let outcome = try await boundedOutcome { try await sendTask.value }
                guard case .failure? = outcome else {
                    Issue.record("Expected the send to fail, got \(String(describing: outcome))")
                    return
                }
                try await harness.drainTasks()
                // The send's own error stores nothing: its session's failure event does.
                #expect(await harness.storedOutcomes().isEmpty)
                let failures = harness.failureEvents(sid: sid)
                #expect(failures.count == 1)
                for failure in failures {
                    if case .jingleFileTransferFailed(_, _, .unconfirmed) = failure {} else {
                        Issue.record("Expected the send to fail as unconfirmed, got \(failure)")
                    }
                    harness.service.handleJingleEvent(failure, accountID: harness.accountID)
                    harness.service.handleJingleEvent(failure, accountID: harness.accountID)
                }
                try await harness.drainTasks()

                let unconfirmed = JingleTransferFailureReason.unconfirmed.displayText
                #expect(harness.service.failureText(ofTransfer: rowID) == unconfirmed)
                #expect(await harness.storedOutcomes() == [unconfirmed])
                #expect(try await sentStanza(on: harness.transport, containing: "session-terminate").contains("<timeout/>"))
            }
            await harness.tearDown()
        }

        /// Where the contact's cancel lands against the send's own end.
        enum CancelTiming: CaseIterable {
            /// While the send's last write is under way, before its confirmation wait starts.
            case duringWrite
            /// Right after the send, its confirmation wait elapsed, committed its end as unconfirmed.
            case afterTimeoutCommit
        }

        /// A send nothing confirmed fails as unconfirmed once its confirmation wait elapses. A contact's cancel that
        /// removed the session first owns the outcome, and one landing right after that commit finds no session to report.
        /// Either way exactly one outcome is stored, from the end that removed the session.
        @Test(arguments: CancelTiming.allCases)
        func `A cancel racing the end of the confirmation wait stores the end that removed the session`(timing: CancelTiming) async throws {
            let harness = try await DirectTransferHarness.connect()
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appending(path: "notes.txt")
                try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
                let transport = harness.transport
                switch timing {
                case .duringWrite: await transport.blockSends { $0.contains("<close") }
                case .afterTimeoutCommit: await transport.blockSends { $0.contains("session-terminate") && $0.contains("<timeout/>") }
                }
                let (sendTask, sid) = try await harness.send(fileURL)
                try await harness.switchToIBB(sid: sid)
                // Held at the write's last stanza, or at the terminate that follows the committed timeout.
                try #require(try await boundedOutcome { await transport.waitForBlockedSend() } != nil)
                await harness.peerTerminates(sid: sid, reason: "cancel")
                let reply = try await sentStanza(on: transport, containing: "terminate-\(sid)")
                await transport.releaseBlockedSends()
                let outcome = try await boundedOutcome { try await sendTask.value }
                try await harness.drainTasks()
                guard case .failure? = outcome else {
                    Issue.record("Expected the send to fail, got \(String(describing: outcome))")
                    return
                }
                let failures = harness.failureEvents(sid: sid)
                #expect(failures.count == 1)
                for failure in failures {
                    harness.service.handleJingleEvent(failure, accountID: harness.accountID)
                }
                try await harness.drainTasks()

                switch timing {
                case .duringWrite:
                    #expect(reply.contains("type=\"result\""))
                    #expect(await harness.storedOutcomes() == [JingleTransferFailureReason.cancel.displayText])
                case .afterTimeoutCommit:
                    // The cancel found no session to end, and the contact is still told the send ended.
                    #expect(reply.contains("unknown-session"))
                    #expect(await harness.storedOutcomes() == [JingleTransferFailureReason.unconfirmed.displayText])
                    _ = try await sentStanza(on: transport) { $0.contains("session-terminate") && $0.contains("<timeout/>") }
                }
            }
            await harness.tearDown()
        }
    }

    @MainActor
    struct Receiving {
        private static func failureNotes(_ harness: DirectTransferHarness) async -> [TimelineNote] {
            await harness.transcripts.notes.filter { $0.kind == .incomingFileFailed }
        }

        /// How often the receive reached its save hook.
        final class SaveCount {
            var count = 0
        }

        @Test
        func `Canceling a file being received tells the contact and notes that the user canceled it`() async throws {
            let harness = try await DirectTransferHarness.connect()
            let offerID = try await harness.receiveOffer(sid: "cancel-sid")
            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            let rowID = try harness.incomingRowID(sid: "cancel-sid")
            // The offer's id names this session apart from a later one under its sid.
            #expect(harness.service.activeTransfers.first { $0.id == rowID }?.offerID == offerID)

            await harness.service.cancelTransfer(id: rowID)
            try await harness.drainTasks()

            #expect(try await sentStanza(on: harness.transport, containing: "session-terminate").contains("<cancel/>"))
            #expect(harness.service.failureText(ofTransfer: rowID) == FileTransferService.LocalEnd.canceled.text)
            let notes = await Self.failureNotes(harness)
            #expect(notes.map(\.fileName) == ["test.txt"])
            #expect(notes.map(\.detail) == [FileTransferService.LocalEnd.canceled.text])
            await harness.tearDown()
        }

        @Test
        func `A requested disconnect during a receive notes that it stopped when the user went offline`() async throws {
            let harness = try await DirectTransferHarness.connect()
            let offerID = try await harness.receiveOffer(sid: "offline-sid")
            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            let rowID = try harness.incomingRowID(sid: "offline-sid")

            await harness.accountService.disconnect(accountID: harness.accountID)
            try await harness.drainTasks()

            #expect(harness.service.failureText(ofTransfer: rowID) == FileTransferService.LocalEnd.wentOffline.text)
            #expect(await Self.failureNotes(harness).map(\.detail) == [FileTransferService.LocalEnd.wentOffline.text])
            await harness.tearDown()
        }

        @Test
        func `A receive that fails before its session's failure event arrives is noted once with the contact's reason`() async throws {
            let harness = try await DirectTransferHarness.connect()
            let offerID = try await harness.receiveOffer(sid: "peer-sid")
            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)

            await harness.peerTerminates(sid: "peer-sid", reason: "cancel")
            try await harness.drainTasks()
            #expect(await Self.failureNotes(harness).isEmpty)

            try await harness.service.handleJingleEvent(harness.failureEvent(sid: "peer-sid"), accountID: harness.accountID)
            try await harness.drainTasks()

            let notes = await Self.failureNotes(harness)
            #expect(notes.map(\.detail) == [JingleTransferFailureReason.cancel.displayText])
            #expect(notes.first?.text(contactName: "Bob") == "test.txt from Bob did not arrive: The transfer was canceled")
            await harness.tearDown()
        }

        @Test
        func `A save that fails after the completion event fails the row with the save's error and is noted once`() async throws {
            try await withTemporaryDirectory { directory in
                // A file where the downloads folder should be, so the save cannot make the folder.
                let downloadsDirectory = directory.appending(path: "Downloads")
                try Data().write(to: downloadsDirectory)
                let harness = try await DirectTransferHarness.connect(downloadsDirectory: downloadsDirectory)
                let offerID = try await harness.receiveOffer(sid: "save-sid")
                try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
                let rowID = try harness.incomingRowID(sid: "save-sid")
                await harness.peerSwitchesToIBB(sid: "save-sid", ibbSID: "ibb-save")
                await harness.transport.simulateReceive(
                    "<iq type='set' id='data-0' from='\(DirectTransferHarness.peerJID)'><data xmlns='http://jabber.org/protocol/ibb' sid='ibb-save' seq='0'>AQID</data></iq>"
                )

                harness.service.handleJingleEvent(
                    .jingleFileTransferCompleted(sid: "save-sid", offerID: offerID, transport: .ibb), accountID: harness.accountID
                )
                await harness.transport.simulateReceive(
                    "<iq type='set' id='close-0' from='\(DirectTransferHarness.peerJID)'><close xmlns='http://jabber.org/protocol/ibb' sid='ibb-save'/></iq>"
                )
                try await harness.drainTasks()

                let failure = try #require(harness.service.failureText(ofTransfer: rowID))
                #expect(failure.hasPrefix("Could not save the file"))
                #expect(await Self.failureNotes(harness).map(\.detail) == [failure])
                await harness.tearDown()
            }
        }

        /// The disconnect also cancels the dispatch of the event the receive's catch left its note to. The contact closes
        /// the stream one byte short, which fails the receive the same way whether its task claimed it before or after.
        @Test
        func `A requested disconnect after a receive's task failed notes the failure its row reads`() async throws {
            let harness = try await DirectTransferHarness.connect()
            let offerID = try await harness.receiveOffer(sid: "failed-sid")
            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            let rowID = try harness.incomingRowID(sid: "failed-sid")

            await harness.peerSwitchesToIBB(sid: "failed-sid", ibbSID: "ibb-failed")
            await harness.transport.simulateReceive(
                "<iq type='set' id='data-0' from='\(DirectTransferHarness.peerJID)'><data xmlns='http://jabber.org/protocol/ibb' sid='ibb-failed' seq='0'>AQI=</data></iq>"
            )
            await harness.transport.simulateReceive(
                "<iq type='set' id='close-0' from='\(DirectTransferHarness.peerJID)'><close xmlns='http://jabber.org/protocol/ibb' sid='ibb-failed'/></iq>"
            )
            _ = try await harness.failureEvent(sid: "failed-sid")
            try await harness.drainTasks()
            // Armed: the receive's catch failed the row with the short stream's reason and left its note to the event.
            let failure = JingleTransferFailureReason.incomplete.displayText
            #expect(harness.service.failureText(ofTransfer: rowID) == failure)
            #expect(await Self.failureNotes(harness).isEmpty)

            await harness.accountService.disconnect(accountID: harness.accountID)
            try await harness.drainTasks()

            #expect(await Self.failureNotes(harness).map(\.detail) == [failure])
            await harness.tearDown()
        }

        /// How a receive's end was settled before a requested disconnect.
        enum SettledEnd: CaseIterable {
            /// The session's failure event reached the service.
            case forwardedFailure
            /// The user stopped the receive.
            case canceled
        }

        @Test(arguments: SettledEnd.allCases)
        func `A requested disconnect leaves a receive whose end was settled with its one note`(settled: SettledEnd) async throws {
            let harness = try await DirectTransferHarness.connect()
            let offerID = try await harness.receiveOffer(sid: "settled-sid")
            try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
            let rowID = try harness.incomingRowID(sid: "settled-sid")
            let reason: String
            switch settled {
            case .forwardedFailure:
                await harness.peerTerminates(sid: "settled-sid", reason: "cancel")
                try await harness.service.handleJingleEvent(harness.failureEvent(sid: "settled-sid"), accountID: harness.accountID)
                reason = JingleTransferFailureReason.cancel.displayText
            case .canceled:
                #expect(await harness.service.cancelTransfer(id: rowID))
                reason = FileTransferService.LocalEnd.canceled.text
            }
            try await harness.drainTasks()
            #expect(await Self.failureNotes(harness).map(\.detail) == [reason])

            await harness.accountService.disconnect(accountID: harness.accountID)
            try await harness.drainTasks()

            #expect(harness.service.failureText(ofTransfer: rowID) == reason)
            #expect(await Self.failureNotes(harness).map(\.detail) == [reason])
            await harness.tearDown()
        }

        /// The completion event is never forwarded here, so the save's own failure is the only end the row gets.
        @Test
        func `A requested disconnect after a failed save leaves its one note`() async throws {
            try await withTemporaryDirectory { directory in
                // A file where the downloads folder should be, so the save cannot make the folder.
                let downloadsDirectory = directory.appending(path: "Downloads")
                try Data().write(to: downloadsDirectory)
                let harness = try await DirectTransferHarness.connect(downloadsDirectory: downloadsDirectory)
                let offerID = try await harness.receiveOffer(sid: "unsaved-sid")
                try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
                let rowID = try harness.incomingRowID(sid: "unsaved-sid")
                await harness.peerSwitchesToIBB(sid: "unsaved-sid", ibbSID: "ibb-unsaved")
                await harness.transport.simulateReceive(
                    "<iq type='set' id='data-0' from='\(DirectTransferHarness.peerJID)'><data xmlns='http://jabber.org/protocol/ibb' sid='ibb-unsaved' seq='0'>AQID</data></iq>"
                )
                await harness.transport.simulateReceive(
                    "<iq type='set' id='close-0' from='\(DirectTransferHarness.peerJID)'><close xmlns='http://jabber.org/protocol/ibb' sid='ibb-unsaved'/></iq>"
                )
                _ = try await sentStanza(on: harness.transport, containing: "<received")
                try await harness.drainTasks()
                let failure = try #require(harness.service.failureText(ofTransfer: rowID))
                #expect(failure.hasPrefix("Could not save the file"))
                #expect(await Self.failureNotes(harness).map(\.detail) == [failure])

                await harness.accountService.disconnect(accountID: harness.accountID)
                try await harness.drainTasks()

                #expect(await Self.failureNotes(harness).map(\.detail) == [failure])
                await harness.tearDown()
            }
        }

        /// The stop and the requested disconnect land once every byte arrived and was checked, before the file is saved.
        /// The module already committed the receive, so the row's end is settled: neither touches it, and the file is
        /// saved and kept.
        @Test
        func `A stop or a requested disconnect while a received file is saved leaves the file and its row alone`() async throws {
            try await withTemporaryDirectory { directory in
                let downloadsDirectory = directory.appending(path: "Downloads", directoryHint: .isDirectory)
                let harness = try await DirectTransferHarness.connect(downloadsDirectory: downloadsDirectory)
                let offerID = try await harness.receiveOffer(sid: "saving-sid")
                try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
                let rowID = try harness.incomingRowID(sid: "saving-sid")
                let service = harness.service
                let accountID = harness.accountID
                let saves = SaveCount()
                service.receivedFileWillSaveForTesting = {
                    saves.count += 1
                    // A progress event dispatched late does not bring the row back as under way.
                    service.handleJingleEvent(
                        .jingleFileTransferProgress(sid: "saving-sid", offerID: offerID, bytesTransferred: 1, totalBytes: 3, bytesPerSecond: nil),
                        accountID: accountID
                    )
                    #expect(service.activeTransfers.first { $0.id == rowID }?.isUnderwayDirectTransfer == false)
                    #expect(await service.cancelTransfer(id: rowID) == false)
                    service.purgeAccount(accountID)
                }

                await harness.peerSwitchesToIBB(sid: "saving-sid", ibbSID: "ibb-saving")
                await harness.transport.simulateReceive(
                    "<iq type='set' id='data-0' from='\(DirectTransferHarness.peerJID)'><data xmlns='http://jabber.org/protocol/ibb' sid='ibb-saving' seq='0'>AQID</data></iq>"
                )
                await harness.transport.simulateReceive(
                    "<iq type='set' id='close-0' from='\(DirectTransferHarness.peerJID)'><close xmlns='http://jabber.org/protocol/ibb' sid='ibb-saving'/></iq>"
                )
                _ = try await sentStanza(on: harness.transport, containing: "<received")
                try await harness.drainTasks()

                #expect(saves.count == 1)
                #expect(harness.service.failureText(ofTransfer: rowID) == nil)
                #expect(await Self.failureNotes(harness).isEmpty)
                #expect(await harness.transcripts.messages.count == 1)
                let saved = try FileManager.default.contentsOfDirectory(atPath: downloadsDirectory.path)
                #expect(saved.count == 1)
                await harness.tearDown()
            }
        }

        /// A peer can reuse a sid once its session ended. Stopping the earlier row ends only its own session.
        @Test
        func `Canceling a receive whose sid a later offer took leaves that offer alone`() async throws {
            let harness = try await DirectTransferHarness.connect()
            let rowID = UUID()
            harness.service.registerTransferForTesting(FileTransferService.ActiveTransfer(
                id: rowID, accountID: harness.accountID, fileName: "earlier.txt", fileSize: 3, state: .transferring(progress: 0.5),
                method: .jingle, direction: .incoming, sid: "reused-sid", peerJIDString: "bob@example.com", offerID: "ended-offer"
            ))
            let laterOfferID = try await harness.receiveOffer(sid: "reused-sid")
            await harness.transport.clearSentBytes()

            #expect(await harness.service.cancelTransfer(id: rowID))

            let sent = await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(!sent.contains { $0.contains("session-terminate") })
            try await harness.service.acceptIncomingTransfer(laterOfferID, accountID: harness.accountID)
            await harness.tearDown()
        }

        /// The disconnect is only the service's part of it here, so the session still delivers the file and the save that
        /// follows fails on its own.
        @Test
        func `A save that fails after this side ended the receive keeps that end and is noted once`() async throws {
            try await withTemporaryDirectory { directory in
                // A file where the downloads folder should be, so the save cannot make the folder.
                let downloadsDirectory = directory.appending(path: "Downloads")
                try Data().write(to: downloadsDirectory)
                let harness = try await DirectTransferHarness.connect(downloadsDirectory: downloadsDirectory)
                let offerID = try await harness.receiveOffer(sid: "ended-sid")
                try await harness.service.acceptIncomingTransfer(offerID, accountID: harness.accountID)
                let rowID = try harness.incomingRowID(sid: "ended-sid")

                harness.service.purgeAccount(harness.accountID)
                await harness.peerSwitchesToIBB(sid: "ended-sid", ibbSID: "ibb-ended")
                await harness.transport.simulateReceive(
                    "<iq type='set' id='data-0' from='\(DirectTransferHarness.peerJID)'><data xmlns='http://jabber.org/protocol/ibb' sid='ibb-ended' seq='0'>AQID</data></iq>"
                )
                await harness.transport.simulateReceive(
                    "<iq type='set' id='close-0' from='\(DirectTransferHarness.peerJID)'><close xmlns='http://jabber.org/protocol/ibb' sid='ibb-ended'/></iq>"
                )
                // Armed: the session delivered the file, which the save then failed to write.
                _ = try await sentStanza(on: harness.transport, containing: "<received")
                try await harness.drainTasks()

                let ended = FileTransferService.LocalEnd.wentOffline.text
                #expect(harness.service.failureText(ofTransfer: rowID) == ended)
                #expect(await Self.failureNotes(harness).map(\.detail) == [ended])
                await harness.tearDown()
            }
        }
    }

    @MainActor
    struct Progress {
        private static func transferringService() -> FileTransferService {
            let service = FileTransferService()
            service.registerTransferForTesting(FileTransferService.ActiveTransfer(
                id: UUID(), accountID: testAccountID, fileName: "notes.bin", fileSize: 1000,
                state: .transferring(progress: 0), method: .jingle, sid: "progress-sid", offerID: "progress-offer"
            ))
            return service
        }

        private static func progress(_ service: FileTransferService, bytes: Int64, bytesPerSecond: Double? = nil) {
            service.handleJingleEvent(
                .jingleFileTransferProgress(sid: "progress-sid", offerID: "progress-offer", bytesTransferred: bytes, totalBytes: 1000, bytesPerSecond: bytesPerSecond),
                accountID: testAccountID
            )
        }

        @Test
        func `Progress that arrives out of order does not move a row backwards`() {
            let service = Self.transferringService()

            Self.progress(service, bytes: 600)
            Self.progress(service, bytes: 300)

            guard case let .transferring(progress)? = service.activeTransfers.first?.state else {
                Issue.record("Expected transferring, got \(String(describing: service.activeTransfers.first?.state))")
                return
            }
            #expect(progress == 0.6)
        }

        @Test
        func `A progress event gives the row its rate`() {
            let service = Self.transferringService()

            Self.progress(service, bytes: 400, bytesPerSecond: 200)

            #expect(service.activeTransfers.first?.rate == TransferRate(bytesPerSecond: 200, bytesTransferred: 400, totalBytes: 1000))
            #expect(service.activeTransfers.first?.rate?.secondsRemaining == 3)
        }
    }
}
