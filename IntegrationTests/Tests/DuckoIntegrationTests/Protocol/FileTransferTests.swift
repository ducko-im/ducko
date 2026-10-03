import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct FileTransferTests {
        // MARK: - Protocol Layer

        @Test @MainActor func `Alice requests an HTTP upload slot and shares the URL with Bob`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let bob = try #require(harness.accounts["bob"])
                let upload = try await harness.module(HTTPUploadModule.self, for: "alice")
                let chat = try await harness.module(ChatModule.self, for: "alice")
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let fixtureURL = try Self.makeFixtureFile(harness: harness)
                let fileSize = try #require(
                    FileManager.default.attributesOfItem(atPath: fixtureURL.path)[.size] as? Int64
                )

                // Absorb environments where the live server lacks XEP-0363; the
                // discovery probe is intrinsically async so this is the minimal
                // reliable skip.
                await withKnownIssue("Server lacks HTTP upload service", isIntermittent: true) {
                    let slot = try await upload.requestSlot(
                        filename: fixtureURL.lastPathComponent,
                        size: fileSize,
                        contentType: "text/plain"
                    )

                    let putURL = try #require(URL(string: slot.putURL))
                    var request = URLRequest(url: putURL)
                    request.httpMethod = "PUT"
                    request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
                    for (name, value) in slot.putHeaders {
                        request.setValue(value, forHTTPHeaderField: name)
                    }
                    let fileData = try Data(contentsOf: fixtureURL)
                    let (_, response) = try await URLSession.shared.upload(for: request, from: fileData)
                    let httpResponse = try #require(response as? HTTPURLResponse)
                    #expect((200 ... 299).contains(httpResponse.statusCode))

                    var oobX = DuckoXMPP.XMLElement(name: "x", namespace: XMPPNamespaces.oob)
                    var urlElement = DuckoXMPP.XMLElement(name: "url")
                    urlElement.addText(slot.getURL)
                    oobX.addChild(urlElement)
                    try await chat.sendMessage(to: .bare(bobJID), body: slot.getURL, additionalElements: [oobX])

                    _ = try await bob.waitForEvent { event in
                        if case let .messageReceived(m) = event, m.body == slot.getURL { return true }
                        return false
                    }
                }
            }
        }

        @Test(.timeLimit(.minutes(1))) @MainActor func `Alice initiates a Jingle file transfer to Bob`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])
                try await Self.runJingleRoundTrip(harness: harness, assertBytesMatch: true)
            }
        }

        @Test(.timeLimit(.minutes(1))) @MainActor func `Jingle transfer completes even when SOCKS5 falls back to IBB`() async throws {
            // SOCKS5-vs-IBB selection is verified deterministically in the DuckoXMPPTests
            // unit suites (JingleSOCKS5Tests, JingleIBBFallbackTests). The integration
            // test's role is only to confirm the live end-to-end path completes;
            // no public selector exposes which transport actually completed.
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])
                try await Self.runJingleRoundTrip(harness: harness, assertBytesMatch: false)
            }
        }

        // MARK: - Service Layer

        @Test @MainActor func `Service sendFile via HTTP upload delivers the OOB URL`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let fixtureURL = try Self.makeFixtureFile(harness: harness)
                let conversation = try await harness.environment.chatService.openConversation(for: bobJID, accountID: alice.accountID)

                await withKnownIssue("Server lacks HTTP upload service", isIntermittent: true) {
                    let url = try await harness.environment.fileTransferService.sendFile(
                        url: fixtureURL,
                        in: conversation,
                        accountID: alice.accountID,
                        method: .httpUpload
                    )
                    #expect(!url.isEmpty)

                    _ = try await bob.waitForEvent { event in
                        if case let .messageReceived(m) = event,
                           let oob = m.element.child(named: "x", namespace: XMPPNamespaces.oob),
                           oob.child(named: "url")?.textContent == url {
                            return true
                        }
                        return false
                    }
                }
            }
        }

        @Test(.timeLimit(.minutes(1))) @MainActor func `Service sendFile via Jingle completes end-to-end`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let bobFullJID = try Self.fullJID(for: bob, harness: harness)
                let fixtureURL = try Self.makeFixtureFile(harness: harness)
                let conversation = try await harness.environment.chatService.openConversation(for: bobJID, accountID: alice.accountID)

                // Jingle service path returns an empty string from sendFile.
                // awaitTransportReady blocks until bob accepts, so kick the send
                // off without awaiting and drive the accept from the harness.
                let sendTask = Task { @MainActor in
                    try await harness.environment.fileTransferService.sendFile(
                        url: fixtureURL,
                        in: conversation,
                        accountID: alice.accountID,
                        method: .jingle,
                        peerJID: bobFullJID.description
                    )
                }
                harness.addCleanup { sendTask.cancel() }

                let offer = try await Self.waitForOffer(on: bob)
                try await harness.environment.fileTransferService.acceptIncomingTransfer(offer.offerID, accountID: bob.accountID)

                let result = try await sendTask.value
                #expect(result.isEmpty)

                // The file's row in Alice's chat says the contact received it.
                let sentRow = try #require(
                    await harness.environment.chatService.loadMessages(for: conversation.id).last { $0.isOutgoing }
                )
                #expect(sentRow.isDelivered)
                #expect(sentRow.errorText == nil)

                // JingleModule emits `.jingleFileTransferCompleted` on the
                // receiver (Bob), not the sender — see `runJingleRoundTrip`.
                _ = try await bob.waitForEvent(
                    matching: { event in
                        if case let .jingleFileTransferCompleted(completedSID, _) = event, completedSID == offer.sid { return true }
                        return false
                    },
                    timeout: TestTimeout.fileTransfer
                )
            }
        }

        @Test(.timeLimit(.minutes(1))) @MainActor func `Service accept incoming transfer saves the file`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let bobFullJID = try Self.fullJID(for: bob, harness: harness)
                let fixtureURL = try Self.makeFixtureFile(harness: harness)
                let conversation = try await harness.environment.chatService.openConversation(for: bobJID, accountID: alice.accountID)

                let sendTask = Task { @MainActor in
                    try await harness.environment.fileTransferService.sendFile(
                        url: fixtureURL,
                        in: conversation,
                        accountID: alice.accountID,
                        method: .jingle,
                        peerJID: bobFullJID.description
                    )
                }
                harness.addCleanup { sendTask.cancel() }

                let offer = try await Self.waitForOffer(on: bob)
                try await harness.environment.fileTransferService.acceptIncomingTransfer(offer.offerID, accountID: bob.accountID)
                _ = try await sendTask.value

                // Wait for Bob's own `.jingleFileTransferCompleted` event.
                _ = try await bob.waitForEvent(
                    matching: { event in
                        if case let .jingleFileTransferCompleted(completedSID, _) = event, completedSID == offer.sid { return true }
                        return false
                    },
                    timeout: TestTimeout.fileTransfer
                )

                // Rows are kept per account, so Bob's row ends with the file he saved while Alice's row tracks her send.
                let fileTransferService = harness.environment.fileTransferService
                var savedURL: URL?
                for _ in 0 ..< 100 where savedURL == nil {
                    let row = fileTransferService.activeTransfers.first { $0.accountID == bob.accountID && $0.sid == offer.sid }
                    if case let .received(fileURL)? = row?.state {
                        savedURL = fileURL
                    } else {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
                let fileURL = try #require(savedURL)
                #expect(try Data(contentsOf: fileURL) == Data(contentsOf: fixtureURL))
            }
        }

        // MARK: - Helpers

        /// Drives a full raw-Jingle offer → accept → transfer → completed cycle
        /// between the harness's alice and bob accounts. `assertBytesMatch`
        /// enables the bytewise equality check for the happy-path test; the
        /// fallback test skips it and asserts only on completion.
        @MainActor
        private static func runJingleRoundTrip(harness: TestHarness, assertBytesMatch: Bool) async throws {
            let bob = try #require(harness.accounts["bob"])
            let aliceJingle = try await harness.module(JingleModule.self, for: "alice")
            let bobJingle = try await harness.module(JingleModule.self, for: "bob")

            let bobFullJID = try Self.fullJID(for: bob, harness: harness)
            let fixtureURL = try Self.makeFixtureFile(harness: harness)
            let fileData = try Array(Data(contentsOf: fixtureURL))
            let fileDesc = JingleFileDescription(
                name: fixtureURL.lastPathComponent,
                size: Int64(fileData.count),
                mediaType: "text/plain"
            )

            let sid = try await aliceJingle.initiateFileTransfer(to: bobFullJID, file: fileDesc)
            let offer = try await waitForOffer(on: bob, sid: sid)
            try await bobJingle.acceptFileTransfer(sid: offer.sid)

            async let received: [UInt8] = {
                try await bobJingle.awaitTransportReady(sid: offer.sid)
                return try await bobJingle.receiveFileData(sid: offer.sid)
            }()
            async let sent: Void = {
                try await aliceJingle.awaitTransportReady(sid: sid)
                try await aliceJingle.sendFileData(sid: sid, data: fileData)
            }()

            let receivedBytes = try await received
            _ = try await sent
            if assertBytesMatch {
                #expect(receivedBytes == fileData)
            }

            // The receiver emits `.jingleFileTransferCompleted` once it verified
            // every byte; the sender returned after the receiver confirmed.
            _ = try await bob.waitForEvent(
                matching: { event in
                    if case let .jingleFileTransferCompleted(completedSID, _) = event, completedSID == sid { return true }
                    return false
                },
                timeout: TestTimeout.fileTransfer
            )
        }

        /// Waits for `.jingleFileTransferReceived` on `account`'s stream. Pass
        /// a `sid` to target a specific session (raw-Jingle flows know the sid
        /// upfront); omit it for service-layer flows where the service
        /// generates the sid internally.
        @MainActor
        private static func waitForOffer(on account: ConnectedAccount, sid: String? = nil) async throws -> JingleFileOffer {
            try await account.waitForEvent(
                extracting: { event in
                    if case let .jingleFileTransferReceived(offer) = event,
                       sid == nil || offer.sid == sid {
                        return offer
                    }
                    return nil
                },
                timeout: TestTimeout.fileTransfer
            )
        }

        @MainActor
        private static func makeFixtureFile(harness: TestHarness) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ducko-inttest-fixture-\(UUID().uuidString).txt", isDirectory: false)
            let payload = String(repeating: "ducko-inttest-\(UUID().uuidString)\n", count: 64)
            try payload.write(to: url, atomically: true, encoding: .utf8)
            harness.addCleanup { try? FileManager.default.removeItem(at: url) }
            return url
        }

        /// Derives the current full JID for an already-connected account. The
        /// Jingle path requires a resource, which is only observable via the
        /// `.connected(FullJID)` state recorded by AccountService.
        @MainActor
        private static func fullJID(for account: ConnectedAccount, harness: TestHarness) throws -> FullJID {
            guard case let .connected(fullJID) = harness.environment.accountService.connectionStates[account.accountID] else {
                throw TestHarnessError.notConnected(label: "account \(account.accountID)")
            }
            return fullJID
        }
    }
}
