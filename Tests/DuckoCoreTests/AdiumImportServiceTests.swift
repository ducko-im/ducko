import DuckoTestSupport
import DuckoXMPP
import Foundation
import os
import Testing
@testable import DuckoCore

enum AdiumImportServiceTests {
    struct SyntheticJIDs {
        @Test
        func `Jabber accounts use identifier directly`() async {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = AdiumImportService(store: store, transcripts: transcripts)
            let jid = await service.syntheticJID(identifier: "saibot@exnet.me", service: "Jabber")
            #expect(jid == "saibot@exnet.me")
        }

        @Test
        func `GTalk accounts use identifier directly`() async {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = AdiumImportService(store: store, transcripts: transcripts)
            let jid = await service.syntheticJID(identifier: "user@gmail.com", service: "GTalk")
            #expect(jid == "user@gmail.com")
        }

        @Test
        func `Non-XMPP services get synthetic JIDs`() async {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = AdiumImportService(store: store, transcripts: transcripts)

            let aim = await service.syntheticJID(identifier: "musclerumble", service: "AIM")
            #expect(aim == "musclerumble@aim.adium-import")

            let icq = await service.syntheticJID(identifier: "101494097", service: "ICQ")
            #expect(icq == "101494097@icq.adium-import")

            let msn = await service.syntheticJID(identifier: "user@example.org", service: "MSN")
            #expect(msn == "user\\40example.org@msn.adium-import")
        }

        @Test(arguments: [
            ("-100001234@chat.facebook.com", "Facebook", "-100001234\\40chat.facebook.com@facebook.adium-import"),
            ("john doe", "AIM", "john\\20doe@aim.adium-import")
        ])
        func `Identifiers with reserved characters are escaped into a valid JID`(
            identifier: String, service: String, expected: String
        ) async {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let importService = AdiumImportService(store: store, transcripts: transcripts)

            let jid = await importService.syntheticJID(identifier: identifier, service: service)
            #expect(jid == expected)
            #expect(BareJID.parse(jid) != nil)
        }
    }

    struct Idempotency {
        @Test
        func `Importing same file twice produces no duplicates`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = AdiumImportService(store: store, transcripts: transcripts)

            let xml = """
            <?xml version="1.0" encoding="UTF-8" ?>
            <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="saibot@exnet.me" service="Jabber">
            <message sender="saibot@exnet.me" time="2016-01-12T00:31:17+0100" alias="saibot"><div>hello</div></message>
            <message sender="buddy@exnet.me" time="2016-01-12T00:31:34+0100" alias="buddy"><div>hi</div></message>
            </chat>
            """

            // Create a temporary file to import
            try await withTemporaryDirectory { tmpDir in
                let serviceDir = tmpDir.appendingPathComponent("Jabber.saibot@exnet.me")
                let contactDir = serviceDir.appendingPathComponent("buddy@exnet.me")
                let chatlogDir = contactDir.appendingPathComponent("buddy@exnet.me (2016-01-12T00.31.17+0100).chatlog")
                try FileManager.default.createDirectory(at: chatlogDir, withIntermediateDirectories: true)
                let xmlFile = chatlogDir.appendingPathComponent("buddy@exnet.me (2016-01-12T00.31.17+0100).xml")
                try xml.write(to: xmlFile, atomically: true, encoding: .utf8)

                let sources = try AdiumLogDiscovery.discoverSources(at: tmpDir)
                #expect(sources.count == 1)

                // First import
                let result1 = try await service.importLogs(from: sources) { _ in }
                #expect(result1.importedMessages == 2)
                #expect(result1.skippedDuplicates == 0)

                // Second import (idempotent)
                let result2 = try await service.importLogs(from: sources) { _ in }
                #expect(result2.importedMessages == 0)
                #expect(result2.skippedDuplicates == 2)

                // Verify total messages in transcript store
                let allMessages = await transcripts.messages
                #expect(allMessages.count == 2)
            }
        }
    }

    struct ConversationPreview {
        /// With `liveWrite`, a newer message is stored while the import holds its conversation write, and keeps the
        /// preview.
        @Test(arguments: [false, true])
        func `The import shows its newest line unless a newer message came in meanwhile`(liveWrite: Bool) async throws {
            let store = MockPersistenceStore()
            let service = AdiumImportService(store: store, transcripts: MockTranscriptStore())
            let xml = """
            <?xml version="1.0" encoding="UTF-8" ?>
            <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="saibot@exnet.me" service="Jabber">
            <message sender="saibot@exnet.me" time="2016-01-12T00:31:17+0100"><div>hello</div></message>
            <message sender="buddy@exnet.me" time="2016-01-12T00:31:34+0100"><div>hi</div></message>
            </chat>
            """
            // Already there, so the metadata update is the import's only conversation write.
            let conversation = try Conversation(
                id: UUID(), importSourceJID: "saibot@exnet.me", jid: #require(BareJID.parse("buddy@exnet.me")), type: .chat,
                isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
            )
            await store.addConversation(conversation)
            let live = Date(timeIntervalSince1970: 2_000_000_000)

            try await withTemporaryDirectory { tmpDir in
                let chatlogDir = tmpDir.appendingPathComponent("Jabber.saibot@exnet.me/buddy@exnet.me/test.chatlog")
                try FileManager.default.createDirectory(at: chatlogDir, withIntermediateDirectories: true)
                try xml.write(to: chatlogDir.appendingPathComponent("test.xml"), atomically: true, encoding: .utf8)
                let sources = try AdiumLogDiscovery.discoverSources(at: tmpDir)

                let entered = AsyncSemaphore()
                let release = AsyncSemaphore()
                if liveWrite {
                    await store.installConversationWriteGate(entered: entered, release: release)
                }
                let importing = Task { try await service.importLogs(from: sources) { _ in } }
                if liveWrite {
                    await entered.wait()
                    try await store.updateConversation(conversation.id) {
                        $0.lastMessageDate = live
                        $0.lastMessagePreview = "live"
                    }
                    await release.signal()
                }
                _ = try await importing.value
            }

            let stored = try #require(await store.conversations.first)
            #expect(stored.lastMessagePreview == (liveWrite ? "live" : "hi"))
            #expect(stored.lastMessageDate == (liveWrite ? live : Date(timeIntervalSince1970: 1_452_555_094)))
        }
    }

    struct ImportSourceJID {
        @Test
        func `Sets importSourceJID on imported conversations`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = AdiumImportService(store: store, transcripts: transcripts)

            let xml = """
            <?xml version="1.0" encoding="UTF-8" ?>
            <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="saibot@exnet.me" service="Jabber">
            <message sender="saibot@exnet.me" time="2016-01-12T00:31:17+0100"><div>hello</div></message>
            </chat>
            """

            try await withTemporaryDirectory { tmpDir in
                let serviceDir = tmpDir.appendingPathComponent("Jabber.saibot@exnet.me")
                let contactDir = serviceDir.appendingPathComponent("buddy@exnet.me")
                let chatlogDir = contactDir.appendingPathComponent("test.chatlog")
                try FileManager.default.createDirectory(at: chatlogDir, withIntermediateDirectories: true)
                try xml.write(to: chatlogDir.appendingPathComponent("test.xml"), atomically: true, encoding: .utf8)

                let sources = try AdiumLogDiscovery.discoverSources(at: tmpDir)
                _ = try await service.importLogs(from: sources) { _ in }

                let accounts = await store.accounts
                #expect(accounts.isEmpty)

                let conversations = await store.conversations
                #expect(conversations.count == 1)

                let conversation = try #require(conversations.first)
                #expect(conversation.accountID == nil)
                #expect(conversation.importSourceJID == "saibot@exnet.me")
                #expect(conversation.jid.description == "buddy@exnet.me")
            }
        }

        @Test
        func `Different source accounts with same contact create separate conversations`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = AdiumImportService(store: store, transcripts: transcripts)

            let xml1 = """
            <?xml version="1.0" encoding="UTF-8" ?>
            <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="alice@jabber.org" service="Jabber">
            <message sender="alice@jabber.org" time="2016-01-12T00:31:17+0100"><div>hello from alice</div></message>
            </chat>
            """
            let xml2 = """
            <?xml version="1.0" encoding="UTF-8" ?>
            <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="bob@jabber.org" service="Jabber">
            <message sender="bob@jabber.org" time="2016-01-12T00:31:17+0100"><div>hello from bob</div></message>
            </chat>
            """

            try await withTemporaryDirectory { tmpDir in
                // Two different source accounts chatting with the same contact
                let serviceDir1 = tmpDir.appendingPathComponent("Jabber.alice@jabber.org")
                let contactDir1 = serviceDir1.appendingPathComponent("buddy@jabber.org")
                let chatlogDir1 = contactDir1.appendingPathComponent("test.chatlog")
                try FileManager.default.createDirectory(at: chatlogDir1, withIntermediateDirectories: true)
                try xml1.write(to: chatlogDir1.appendingPathComponent("test.xml"), atomically: true, encoding: .utf8)

                let serviceDir2 = tmpDir.appendingPathComponent("Jabber.bob@jabber.org")
                let contactDir2 = serviceDir2.appendingPathComponent("buddy@jabber.org")
                let chatlogDir2 = contactDir2.appendingPathComponent("test.chatlog")
                try FileManager.default.createDirectory(at: chatlogDir2, withIntermediateDirectories: true)
                try xml2.write(to: chatlogDir2.appendingPathComponent("test.xml"), atomically: true, encoding: .utf8)

                let sources = try AdiumLogDiscovery.discoverSources(at: tmpDir)
                _ = try await service.importLogs(from: sources) { _ in }

                let conversations = await store.conversations
                #expect(conversations.count == 2)

                let sourceJIDs = Set(conversations.compactMap(\.importSourceJID))
                #expect(sourceJIDs == ["alice@jabber.org", "bob@jabber.org"])

                // Both conversations share the same contact JID but are distinct
                let contactJIDs = Set(conversations.map(\.jid.description))
                #expect(contactJIDs == ["buddy@jabber.org"])
            }
        }

        @Test
        func `Links to existing account instead of setting importSourceJID`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = AdiumImportService(store: store, transcripts: transcripts)

            // Pre-create an account matching the import source
            let account = try Account(
                id: UUID(),
                jid: #require(DuckoXMPP.BareJID.parse("saibot@exnet.me")),
                isEnabled: true,
                connectOnLaunch: false,
                createdAt: Date()
            )
            await store.addAccount(account)

            let xml = """
            <?xml version="1.0" encoding="UTF-8" ?>
            <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="saibot@exnet.me" service="Jabber">
            <message sender="saibot@exnet.me" time="2016-01-12T00:31:17+0100"><div>hello</div></message>
            </chat>
            """

            try await withTemporaryDirectory { tmpDir in
                let serviceDir = tmpDir.appendingPathComponent("Jabber.saibot@exnet.me")
                let contactDir = serviceDir.appendingPathComponent("buddy@exnet.me")
                let chatlogDir = contactDir.appendingPathComponent("test.chatlog")
                try FileManager.default.createDirectory(at: chatlogDir, withIntermediateDirectories: true)
                try xml.write(to: chatlogDir.appendingPathComponent("test.xml"), atomically: true, encoding: .utf8)

                let sources = try AdiumLogDiscovery.discoverSources(at: tmpDir)
                _ = try await service.importLogs(from: sources) { _ in }

                let conversations = await store.conversations
                #expect(conversations.count == 1)

                let conversation = try #require(conversations.first)
                #expect(conversation.accountID == account.id)
                #expect(conversation.importSourceJID == nil)
            }
        }
    }

    struct ProgressReporting {
        @Test
        func `Reports progress during import`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = AdiumImportService(store: store, transcripts: transcripts)

            let xml = """
            <?xml version="1.0" encoding="UTF-8" ?>
            <chat xmlns="http://purl.org/net/ulf/ns/0.4-02" account="user@example.com" service="Jabber">
            <message sender="user@example.com" time="2016-01-12T00:31:17+0100"><div>hello</div></message>
            </chat>
            """

            try await withTemporaryDirectory { tmpDir in
                let serviceDir = tmpDir.appendingPathComponent("Jabber.user@example.com")
                let contactDir = serviceDir.appendingPathComponent("buddy@example.com")
                let chatlogDir = contactDir.appendingPathComponent("test.chatlog")
                try FileManager.default.createDirectory(at: chatlogDir, withIntermediateDirectories: true)
                try xml.write(to: chatlogDir.appendingPathComponent("test.xml"), atomically: true, encoding: .utf8)

                let sources = try AdiumLogDiscovery.discoverSources(at: tmpDir)
                let progressCount = OSAllocatedUnfairLock(initialState: 0)
                let result = try await service.importLogs(from: sources) { _ in
                    progressCount.withLock { $0 += 1 }
                }

                // Final progress callback always fires
                let count = progressCount.withLock { $0 }
                #expect(count > 0)
                #expect(result.totalFiles == 1)
                #expect(result.completedFiles == 1)
            }
        }
    }
}
