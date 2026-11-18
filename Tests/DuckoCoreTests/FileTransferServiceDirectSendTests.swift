import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore

enum FileTransferServiceDirectSendTests {
    /// The snapshot directories that still hold a copy named `name`.
    private static func leftoverSnapshots(named name: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("ducko-send-") }
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: name).path) }
    }

    /// Every byte a send of `snapshotURL` would carry, read the way the send reads it.
    private static func sentBytes(of snapshotURL: URL) async throws -> [UInt8] {
        let source = try FileHandleJingleFileSource(reading: snapshotURL)
        var bytes: [UInt8] = []
        while true {
            let chunk = try await source.read(upTo: 4)
            guard !chunk.isEmpty else { return bytes }
            bytes += chunk
        }
    }

    private static func overwriteInPlace(_ url: URL, with text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(text.utf8))
    }

    struct SnapshotPreparation {
        @Test
        func `A snapshot is sent unchanged after the original is overwritten in place`() async throws {
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appending(path: "notes.txt")
                try "before".write(to: fileURL, atomically: true, encoding: .utf8)

                let snapshot = try await FileTransferService.prepareSnapshot(of: fileURL)
                defer { try? FileManager.default.removeItem(at: snapshot.directory) }
                try overwriteInPlace(fileURL, with: "after!")

                #expect(try await sentBytes(of: snapshot.snapshotURL) == Array("before".utf8))
                #expect(snapshot.size == 6)
                #expect(snapshot.hash == JingleFileDescription.sha256Hash(of: Array("before".utf8)))
            }
        }

        @Test(arguments: [true, false])
        func `A symlinked file is sent as its target's bytes at the time of sending`(relativeLink: Bool) async throws {
            try await withTemporaryDirectory { directory in
                let targetURL = directory.appending(path: "target.txt")
                try "before".write(to: targetURL, atomically: true, encoding: .utf8)
                let linkURL = directory.appending(path: "link.txt")
                try FileManager.default.createSymbolicLink(
                    atPath: linkURL.path, withDestinationPath: relativeLink ? "target.txt" : targetURL.path
                )

                let snapshot = try await FileTransferService.prepareSnapshot(of: linkURL)
                defer { try? FileManager.default.removeItem(at: snapshot.directory) }
                try overwriteInPlace(targetURL, with: "after!")

                #expect(try await sentBytes(of: snapshot.snapshotURL) == Array("before".utf8))
                #expect(snapshot.hash == JingleFileDescription.sha256Hash(of: Array("before".utf8)))
            }
        }

        /// The source is a folder. With an unreadable file inside, copying it fails. Without one, the copy succeeds and
        /// hashing it fails.
        @Test(arguments: [true, false])
        func `A snapshot that cannot be copied or hashed leaves no directory behind`(copyFails: Bool) async throws {
            try await withTemporaryDirectory { directory in
                let name = "source-\(UUID().uuidString)"
                let sourceURL = directory.appending(path: name, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
                if copyFails {
                    let unreadable = sourceURL.appending(path: "unreadable.txt")
                    try "secret".write(to: unreadable, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
                }

                await #expect(throws: (any Error).self) {
                    _ = try await FileTransferService.prepareSnapshot(of: sourceURL)
                }

                #expect(try leftoverSnapshots(named: name).isEmpty)
            }
        }

        @Test
        func `A snapshot cancelled while it is prepared leaves no directory behind`() async throws {
            try await withTemporaryDirectory { directory in
                let name = "notes-\(UUID().uuidString).txt"
                let fileURL = directory.appending(path: name)
                try "abc".write(to: fileURL, atomically: true, encoding: .utf8)

                let preparation = Task { try await FileTransferService.prepareSnapshot(of: fileURL) }
                preparation.cancel()

                await #expect(throws: CancellationError.self) {
                    _ = try await preparation.value
                }
                #expect(try leftoverSnapshots(named: name).isEmpty)
            }
        }
    }

    @MainActor
    struct SnapshotLifetime {
        /// Whether the contact confirms the file, which ends the send as delivered, or never does, which fails it once its
        /// wait elapses. Either way the send's snapshot goes.
        @Test(arguments: [true, false])
        func `A finished direct send leaves no snapshot behind`(confirmed: Bool) async throws {
            let sender = try await DirectTransferHarness.connect(senderConfirmationWait: confirmed ? .seconds(10) : .milliseconds(100))
            try await withTemporaryDirectory { directory in
                let name = "notes-\(UUID().uuidString).txt"
                let fileURL = directory.appending(path: name)
                try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
                let (sendTask, sid) = try await sender.send(fileURL)

                // Armed: the offer is out, so the send is running from its snapshot.
                #expect(try leftoverSnapshots(named: name).count == 1)
                try await sender.switchToIBB(sid: sid)
                if confirmed {
                    _ = try await sentStanza(on: sender.transport, containing: "<close")
                    await sender.peerTerminates(sid: sid, reason: "success")
                }

                let sent = try await boundedOutcome(timeout: .seconds(5)) { try await sendTask.value }
                switch (confirmed, sent) {
                case (true, .success?), (false, .failure?): break
                default: Issue.record("Unexpected send outcome \(String(describing: sent)), confirmed: \(confirmed)")
                }
                #expect(try leftoverSnapshots(named: name).isEmpty)
            }
            await sender.tearDown()
        }

        /// The contact's confirmation is the one source of a delivered outcome, stored once even when the session's
        /// completion event reaches the service afterwards.
        @Test
        func `A send the contact confirms is stored as delivered once`() async throws {
            let sender = try await DirectTransferHarness.connect(senderConfirmationWait: .seconds(10))
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appending(path: "notes.txt")
                try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
                let (sendTask, sid) = try await sender.send(fileURL)
                let row = try #require(sender.service.activeTransfers.first)
                try await sender.switchToIBB(sid: sid)
                _ = try await sentStanza(on: sender.transport, containing: "<close")
                await sender.peerTerminates(sid: sid, reason: "success")

                let sent = try await boundedOutcome(timeout: .seconds(5)) { try await sendTask.value }
                guard case .success? = sent else {
                    Issue.record("Expected the send to succeed, got \(String(describing: sent))")
                    return
                }
                try await sender.drainTasks()
                if case .completedTransfer? = sender.service.activeTransfers.first(where: { $0.id == row.id })?.state {} else {
                    Issue.record("Expected the row to read completed")
                }
                #expect(await sender.storedOutcomes() == [nil])

                try sender.service.handleJingleEvent(
                    .jingleFileTransferCompleted(sid: sid, offerID: #require(row.offerID), transport: .ibb), accountID: sender.accountID
                )
                try await sender.drainTasks()
                if case .completedTransfer? = sender.service.activeTransfers.first(where: { $0.id == row.id })?.state {} else {
                    Issue.record("Expected the row to read completed")
                }
                #expect(await sender.storedOutcomes() == [nil])
                #expect(sender.failureEvents(sid: sid).isEmpty)
            }
            await sender.tearDown()
        }
    }

    /// A send that ended while it waited for its connection goes no further once the connection is ready.
    @MainActor
    struct EndedWhileWaiting {
        @Test
        func `A send cancelled while it waits for its connection withdraws the offer and sends no data`() async throws {
            let sender = try await DirectTransferHarness.connect()
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appending(path: "notes.txt")
                try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
                let (sendTask, sid) = try await sender.send(fileURL)
                try await sender.awaitAnsweredOffer(sid: sid)

                sendTask.cancel()
                try await sender.switchToIBB(sid: sid)

                let outcome = try await boundedOutcome { try await sendTask.value }
                guard case let .failure(error)? = outcome else {
                    Issue.record("Expected the send to stop, got \(String(describing: outcome))")
                    return
                }
                #expect(error is CancellationError)
                let terminate = try await sentStanza(on: sender.transport, containing: "session-terminate")
                #expect(terminate.contains("<cancel/>"))
                #expect(await !sender.sentIBBOpen())
            }
            await sender.tearDown()
        }

        @Test
        func `A send whose session's failure event ended its row stores that reason once`() async throws {
            let sender = try await DirectTransferHarness.connect()
            try await withTemporaryDirectory { directory in
                let fileURL = directory.appending(path: "notes.txt")
                try "abc".write(to: fileURL, atomically: true, encoding: .utf8)
                let (sendTask, sid) = try await sender.send(fileURL)
                try await sender.awaitAnsweredOffer(sid: sid)

                try sender.service.handleJingleEvent(
                    .jingleFileTransferFailed(sid: sid, offerID: sender.outgoingOfferID(), reason: .cancel), accountID: sender.accountID
                )
                try await sender.switchToIBB(sid: sid)

                let outcome = try await boundedOutcome { try await sendTask.value }
                guard case .failure? = outcome else {
                    Issue.record("Expected the send to stop, got \(String(describing: outcome))")
                    return
                }
                let amendments = await sender.transcripts.amendments.map(\.amendment)
                #expect(amendments.map(\.action) == [.error])
                #expect(amendments.map(\.errorText) == [JingleTransferFailureReason.cancel.displayText])
                #expect(await !sender.sentIBBOpen())
            }
            await sender.tearDown()
        }
    }
}
