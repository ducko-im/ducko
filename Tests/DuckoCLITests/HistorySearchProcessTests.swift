import DuckoCore
import DuckoData
import DuckoXMPP
import Foundation
import Testing

/// Runs the built CLI against a throwaway profile whose history is stored on disk, so the search goes through the
/// file store and its day files.
///
/// | Day        | bob                              | room | carol, in private | eve (other account) | imported |
/// |------------|----------------------------------|------|-------------------|---------------------|----------|
/// | 2026-03-03 |                                  |      |                   | needle eve          | needle imported |
/// | 2026-03-02 | ten, nine, eleven (stored so)    |      |                   |                     |          |
/// | 2026-03-01 |                                  | needle room |            |                     |          |
/// | 2026-02-28 |                                  |      | needle private    |                     |          |
/// | 2026-02-27 | needle old                       |      |                   |                     |          |
@MainActor
struct HistorySearchProcessTests {
    private static let bodies = [
        "needle old", "needle nine", "needle ten", "needle eleven", "needle room", "needle private", "needle eve", "needle imported"
    ]

    @Test func `a search of all conversations prints the account's matches by conversation and day, each day oldest first`() async throws {
        let profile = try await Profile()
        defer { profile.remove() }

        let output = try await profile.run(["history", "--search", "needle", "--account", profile.account.uuidString, "--output", "plain"])

        #expect(output.split(separator: "\n").filter { $0.hasPrefix("---") } == [
            "--- bob@example.com, 2026-03-02 (3 matches) ---",
            "--- room@conference.example.com, 2026-03-01 (1 match) ---",
            "--- room@conference.example.com/carol, 2026-02-28 (1 match) ---",
            "--- bob@example.com, 2026-02-27 (1 match) ---"
        ])
        #expect(Self.bodies(in: output) == ["needle nine", "needle ten", "needle eleven", "needle room", "needle private", "needle old"])
    }

    /// The day's file holds ten, nine, eleven in that order, so its last two entries are not its newest two.
    @Test func `the limit keeps the newest matches of a day stored out of time order`() async throws {
        let profile = try await Profile()
        defer { profile.remove() }

        let output = try await profile.run(["history", "--search", "needle", "--limit", "2", "--account", profile.account.uuidString, "--output", "plain"])

        #expect(output.split(separator: "\n").filter { $0.hasPrefix("---") } == ["--- bob@example.com, 2026-03-02 (2 matches) ---"])
        #expect(Self.bodies(in: output) == ["needle ten", "needle eleven"])
    }

    @Test func `a search of one conversation prints its matches oldest first, without day lines`() async throws {
        let profile = try await Profile()
        defer { profile.remove() }

        let output = try await profile.run(["history", "bob@example.com", "--search", "needle", "--account", profile.account.uuidString, "--output", "plain"])

        #expect(!output.contains("---"))
        #expect(Self.bodies(in: output) == ["needle old", "needle nine", "needle ten", "needle eleven"])
    }

    @Test func `in JSON each day is a record that names a private chat by its occupant`() async throws {
        let profile = try await Profile()
        defer { profile.remove() }

        let output = try await profile.run(["history", "--search", "needle", "--account", profile.account.uuidString, "--output", "json"])

        let records = try output.split(separator: "\n").map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]) }
        #expect(records.filter { $0["type"] == "search_day" }.map { [$0["jid"], $0["day"], $0["count"]] } == [
            ["bob@example.com", "2026-03-02", "3"],
            ["room@conference.example.com", "2026-03-01", "1"],
            ["room@conference.example.com/carol", "2026-02-28", "1"],
            ["bob@example.com", "2026-02-27", "1"]
        ])
        #expect(records.filter { $0["type"] == "message" }.map { $0["body"] } == [
            "needle nine", "needle ten", "needle eleven", "needle room", "needle private", "needle old"
        ])
    }

    /// The known message texts in the order the output has them.
    private static func bodies(in output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in bodies.first { line.hasSuffix($0) } }
    }
}

@MainActor
private struct Profile {
    /// The start of 2026-02-28 in UTC.
    private static let firstDay = Date(timeIntervalSince1970: 1_772_236_800)

    let account = UUID()
    private let profile: ThrowawayProfile

    init() async throws {
        self.profile = try ThrowawayProfile(named: "history-local")
        do {
            try await seed()
        } catch {
            remove()
            throw error
        }
    }

    func remove() {
        profile.remove()
    }

    func run(_ arguments: [String]) async throws -> String {
        let run = try await profile.run(arguments)
        #expect(run.reason == .exit && run.exitCode == 0, Comment(rawValue: run.output + run.errors))
        return run.output
    }

    private func seed() async throws {
        let store = try profile.makeStore()
        let other = UUID()
        try await store.saveAccount(Self.account(account, "alice@example.com"))
        try await store.saveAccount(Self.account(other, "other@example.com"))

        let bob = try Self.conversation("bob@example.com", accountID: account)
        let room = try Self.conversation("room@conference.example.com", accountID: account, type: .groupchat)
        let carol = try Self.conversation("room@conference.example.com", accountID: account, occupantNickname: "carol")
        let eve = try Self.conversation("eve@example.com", accountID: other)
        let imported = try Self.conversation("dave@example.com", importSourceJID: "old@example.com")
        for conversation in [bob, room, carol, eve, imported] {
            try await store.upsertConversation(conversation)
        }

        let transcripts = FileTranscriptStore(baseDirectory: profile.directory.appending(path: "Transcripts"))
        try await transcripts.appendMessages([
            Self.message("needle old", in: bob, day: -1),
            Self.message("needle ten", in: bob, day: 2, hour: 10),
            Self.message("needle nine", in: bob, day: 2, hour: 9),
            Self.message("needle eleven", in: bob, day: 2, hour: 11),
            Self.message("hay", in: bob, day: 2, hour: 12),
            Self.message("needle room", in: room, day: 1),
            Self.message("needle private", in: carol, day: 0),
            Self.message("needle eve", in: eve, day: 3),
            Self.message("needle imported", in: imported, day: 3)
        ])
    }

    private static func account(_ id: UUID, _ jid: String) throws -> Account {
        try Account(id: id, jid: #require(BareJID.parse(jid)), isEnabled: true, connectOnLaunch: false, createdAt: Date())
    }

    private static func conversation(
        _ jid: String, accountID: UUID? = nil, importSourceJID: String? = nil,
        type: Conversation.ConversationType = .chat, occupantNickname: String? = nil
    ) throws -> Conversation {
        try Conversation(
            id: UUID(), accountID: accountID, importSourceJID: importSourceJID, jid: #require(BareJID.parse(jid)), type: type,
            isPinned: false, isMuted: false, unreadCount: 0, occupantNickname: occupantNickname, createdAt: Date()
        )
    }

    private static func message(_ body: String, in conversation: Conversation, day: Int, hour: Int = 0) -> ChatMessage {
        ChatMessage(
            id: UUID(), conversationID: conversation.id, fromJID: conversation.jid.description, body: body,
            timestamp: firstDay.addingTimeInterval(TimeInterval(day * 24 * 60 * 60 + hour * 60 * 60)),
            isOutgoing: false, isDelivered: false, isEdited: false, type: conversation.type.rawValue
        )
    }
}
